local DiskCache = require("blink_deps.disk_cache")
local Util = require("blink_deps.util")
local VERSION = require("blink_deps.version")

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

local function metadata_url(repository, group_id, artifact_id)
	return table.concat({
		trim_slash(repository.url),
		group_path(group_id),
		artifact_id,
		"maven-metadata.xml",
	}, "/")
end

local function repository_name(repository)
	if repository.name and repository.name ~= "" then
		return repository.name
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

--------------------------------------------------------------------------------
-- CACHE IDENTITY
--------------------------------------------------------------------------------

local function cache_key(repository, group_id, artifact_id)
	return vim.fn.sha256(table.concat({
		trim_slash(repository.url),
		group_id,
		artifact_id,
	}, "\n"))
end

--------------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------------

local function request(source, repository, group_id, artifact_id, callback)
	local url = metadata_url(repository, group_id, artifact_id)

	local cmd = {
		"curl",
		"-sS",
		"--fail-with-body",
		"--connect-timeout",
		tostring(source.opts.connect_timeout or M.HTTP_CONNECT_TIMEOUT),
		"--max-time",
		tostring(source.opts.max_time or M.HTTP_MAX_TIME),
		"-A",
		"blink-cmp-deps/" .. VERSION,
		url,
	}

	vim.system(cmd, { text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				callback(
					nil,
					Util.trim(result.stderr or "repository request failed")
				)
				return
			end

			callback(extract_versions(result.stdout or ""), nil)
		end)
	end)
end

--------------------------------------------------------------------------------
-- VERSIONS
--------------------------------------------------------------------------------

function M.versions(source, repository, group_id, artifact_id, callback)
	if type(repository) ~= "table"
		or type(repository.url) ~= "string"
		or repository.url == ""
	then
		callback({}, "invalid repository")
		return
	end

	local key = cache_key(
		repository,
		group_id,
		artifact_id
	)

	source.repository_cache = source.repository_cache or {}
	source.repository_inflight = source.repository_inflight or {}

	--------------------------------------------------------------------------
	-- 1. SESSION MEMORY CACHE
	--------------------------------------------------------------------------

	local memory_cached = source.repository_cache[key]

	if memory_cached then
		callback(memory_cached, nil)
		return
	end

	--------------------------------------------------------------------------
	-- 2. REQUEST ALREADY RUNNING
	--------------------------------------------------------------------------

	local running = source.repository_inflight[key]

	if running then
		table.insert(running, callback)
		return
	end

	--------------------------------------------------------------------------
	-- 3. PERSISTENT CACHE
	--------------------------------------------------------------------------

	local persisted = DiskCache.get(
		source.opts.cache,
		"repository",
		key
	)

	if persisted then
		source.repository_cache[key] = persisted
		callback(persisted, nil)
		return
	end

	--------------------------------------------------------------------------
	-- 4. REPOSITORY REQUEST
	--------------------------------------------------------------------------

	source.repository_inflight[key] = {
		callback,
	}

	request(
		source,
		repository,
		group_id,
		artifact_id,
		function(versions, err)
			local result = versions or {}

			if not err then
				source.repository_cache[key] = result

				-- Persistent caching is an optimization. A disk write
				-- failure must not break repository completion.
				DiskCache.set(
					source.opts.cache,
					"repository",
					key,
					result
				)
			end

			local waiters =
				source.repository_inflight[key] or {}

			source.repository_inflight[key] = nil

			for _, waiter in ipairs(waiters) do
				waiter(result, err)
			end
		end
	)
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

function M.debug_name(repository)
	return repository_name(repository)
end

return M
