local Http = require("blink_deps.http")
local Nexus = require("blink_deps.nexus")
local Pipeline = require("blink_deps.pipeline")

local M = {}

M.HTTP_CONNECT_TIMEOUT = 3
M.HTTP_MAX_TIME = 7

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function trim_slash(value)
	return (value or ""):gsub("/+$", "")
end

local function group_path(group_id)
	return (group_id or ""):gsub("%.", "/")
end

local function repository_url(repository)
	if type(repository) ~= "table" then
		return nil
	end

	if repository.type == "nexus" then
		return Nexus.content_url(repository)
	end

	if type(repository.url) ~= "string"
		or repository.url == ""
	then
		return nil
	end

	return trim_slash(repository.url)
end

local function metadata_url(repository, group_id, artifact_id)
	local base_url =
		repository_url(repository)

	if not base_url then
		return nil
	end

	return table.concat({
		base_url,
		group_path(group_id),
		artifact_id,
		"maven-metadata.xml",
	}, "/")
end

local function repository_name(repository)
	if repository.name and repository.name ~= "" then
		return repository.name
	end

	-- A Nexus hosts many repositories under one URL, so the repository id
	-- says more than the address does.
	if repository.type == "nexus"
		and type(repository.repository) == "string"
		and repository.repository ~= ""
	then
		return repository.repository
	end

	return repository.url
end

--------------------------------------------------------------------------------
-- XML
--------------------------------------------------------------------------------

local function decode_xml_entities(value)
	return value
		:gsub("&lt;", "<")
		:gsub("&gt;", ">")
		:gsub("&quot;", '"')
		:gsub("&apos;", "'")
		:gsub("&amp;", "&")
end

local function extract_versions(xml)
	local seen = {}
	local versions = {}

	for value in (xml or ""):gmatch("<version>%s*(.-)%s*</version>") do
		value = vim.trim(decode_xml_entities(value))

		if value ~= "" and not seen[value] then
			seen[value] = true
			table.insert(versions, value)
		end
	end

	return versions
end

local function is_metadata(xml)
	return type(xml) == "string"
		and xml:find("<metadata", 1, true) ~= nil
end

--------------------------------------------------------------------------------
-- CACHE IDENTITY
--------------------------------------------------------------------------------

local function cache_key(repository, group_id, artifact_id)
	local base_url =
		repository_url(repository)

	if not base_url then
		return nil
	end

	return vim.fn.sha256(table.concat({
		base_url,
		group_id,
		artifact_id,
	}, "\n"))
end

-- The session key is the plain identity. The hash above is only needed as a
-- file name, so it is derived when the disk is actually consulted.
local function memory_key(repository, group_id, artifact_id)
	return table.concat({
		repository_url(repository),
		group_id,
		artifact_id,
	}, "\n")
end

--------------------------------------------------------------------------------
-- HTTP
--
-- Transport and error classification live in blink_deps.http.
--------------------------------------------------------------------------------

-- A repository request was never retried before the shared transport existed.
-- That stays true until retry policy becomes configurable per repository.
M.HTTP_RETRIES = 0

local function request_spec(source, repository, group_id, artifact_id)
	return {
		url = metadata_url(repository, group_id, artifact_id),
		connect_timeout =
			source.opts.connect_timeout or M.HTTP_CONNECT_TIMEOUT,
		max_time = source.opts.max_time or M.HTTP_MAX_TIME,
		retries = M.HTTP_RETRIES,
	}
end

-- Callers treat the error as a plain string, so the structured transport
-- error is flattened to its message at this boundary.
local function request(source, repository, group_id, artifact_id, callback)
	Http.request(
		request_spec(source, repository, group_id, artifact_id),
		function(body, err)
			if err then
				callback(nil, err.message)
				return
			end

			-- A login page or a proxy error served with status 200 is not
			-- an artifact without versions. Reading it as one would
			-- persist an empty answer for the whole cache lifetime.
			if not is_metadata(body) then
				callback(nil, "unexpected repository response")
				return
			end

			callback(extract_versions(body), nil)
		end
	)
end

--------------------------------------------------------------------------------
-- PIPELINE
--
-- Memory, request sharing and persistence live in blink_deps.pipeline. The
-- source keeps owning the two tables so its cache survives for the session.
--------------------------------------------------------------------------------

local function pipeline(source)
	local existing = source.repository_pipeline

	-- Rebuilt if the source's tables were replaced underneath it.
	if existing
		and existing.memory == source.repository_cache
		and existing.inflight == source.repository_inflight
	then
		return existing
	end

	source.repository_cache = source.repository_cache or {}
	source.repository_inflight = source.repository_inflight or {}

	source.repository_pipeline = Pipeline.new({
		name = "repository",
		memory = source.repository_cache,
		inflight = source.repository_inflight,
	})

	return source.repository_pipeline
end

--------------------------------------------------------------------------------
-- VERSIONS
--------------------------------------------------------------------------------

function M.versions(source, repository, group_id, artifact_id, callback)
	if not repository_url(repository) then
		callback({}, "invalid repository")
		return
	end

	pipeline(source):fetch({
		key = memory_key(repository, group_id, artifact_id),

		disk = function()
			return {
				opts = source.opts.cache,
				namespace = "repository",
				key = cache_key(repository, group_id, artifact_id),
			}
		end,

		fetch = function(done)
			request(source, repository, group_id, artifact_id, done)
		end,
	}, function(versions, err)
		-- Callers iterate the result without checking it, so a failure
		-- is an empty list alongside the error.
		callback(versions or {}, err)
	end)
end

--------------------------------------------------------------------------------
-- REGISTRY
--
-- One configured repository as seen through the contract in
-- blink_deps.registries. Returns nil for a configuration that cannot be
-- queried, so a typo in one entry never takes the others down with it.
--------------------------------------------------------------------------------

local function registry_versions(self, source, package, callback)
	M.versions(
		source,
		self.repository,
		package.namespace,
		package.name,
		function(values, err)
			local versions = {}

			-- maven-metadata.xml carries no publication time per version.
			for _, value in ipairs(values or {}) do
				table.insert(versions, {
					value = value,
					timestamp = 0,
				})
			end

			callback(versions, err)
		end
	)
end

-- Listing a namespace needs a search API. Nexus has one; a plain Maven
-- repository is only a directory layout and does not.
local function nexus_packages(self, source, namespace, callback)
	Nexus.artifacts(
		source,
		self.repository,
		namespace,
		function(entries, err)
			local packages = {}

			for _, entry in ipairs(entries or {}) do
				table.insert(packages, {
					name = entry.artifact,
					latest_version = entry.latestVersion,
				})
			end

			callback(packages, err)
		end
	)
end

local function nexus_namespaces(self, source, text, callback)
	Nexus.groups(
		source,
		self.repository,
		text,
		function(groups, err)
			local namespaces = {}

			-- The Nexus search API returns matches, not a measure of how
			-- well each one matched.
			for _, group in ipairs(groups or {}) do
				table.insert(namespaces, {
					name = group,
					score = 0,
				})
			end

			callback(namespaces, err)
		end
	)
end

function M.registry(repository)
	local base_url = repository_url(repository)

	if not base_url then
		return nil
	end

	local is_nexus = repository.type == "nexus"
	local kind = is_nexus and "nexus" or "maven"

	local registry = {
		id = kind .. ":" .. base_url,
		name = repository_name(repository),
		kind = kind,
		repository = repository,

		capabilities = {
			versions = true,
		},

		versions = registry_versions,
	}

	if is_nexus then
		registry.capabilities.packages = true
		registry.packages = nexus_packages

		registry.capabilities.namespaces = true
		registry.namespaces = nexus_namespaces
	end

	return registry
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS / TESTS
--------------------------------------------------------------------------------

function M.debug_metadata_url(repository, group_id, artifact_id)
	return metadata_url(repository, group_id, artifact_id)
end

function M.debug_extract_versions(xml)
	return extract_versions(xml)
end

function M.debug_cache_key(repository, group_id, artifact_id)
	return cache_key(repository, group_id, artifact_id)
end

function M.debug_request_spec(source, repository, group_id, artifact_id)
	return request_spec(source, repository, group_id, artifact_id)
end

function M.debug_name(repository)
	return repository_name(repository)
end

return M
