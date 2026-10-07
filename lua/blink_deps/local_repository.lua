local Pipeline = require("blink_deps.pipeline")
local Util = require("blink_deps.util")
local VersionRank = require("blink_deps.version_rank")

local M = {}

M.DEFAULT_ROOT = "~/.m2/repository"

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local function enabled(source)
	local configured =
		source.opts
		and source.opts.local_repository

	if type(configured) ~= "table" then
		return true
	end

	return configured.enabled ~= false
end

function M.root(source)
	local configured =
		source.opts
		and source.opts.local_repository

	if type(configured) == "table"
		and type(configured.path)
			== "string"
		and configured.path ~= ""
	then
		return vim.fn.expand(
			configured.path
		)
	end

	return vim.fn.expand(
		M.DEFAULT_ROOT
	)
end

--------------------------------------------------------------------------------
-- PATH PARSING
--
-- A local repository stores every artifact at
--
--   <root>/<group as directories>/<artifactId>/<version>/<file>.pom
--
-- so the coordinate falls straight out of the path. Reading the POM itself
-- would mean parsing 2000 XML files for information the layout already
-- carries.
--------------------------------------------------------------------------------

function M.parse_relative_path(relative)
	local parts = {}

	for part in relative:gmatch("[^/]+") do
		table.insert(parts, part)
	end

	-- group parts, artifactId, version, file
	if #parts < 4 then
		return nil
	end

	local version = parts[#parts - 1]
	local artifact = parts[#parts - 2]

	local group_parts = {}

	for index = 1, #parts - 3 do
		table.insert(
			group_parts,
			parts[index]
		)
	end

	if #group_parts == 0
		or artifact == ""
	then
		return nil
	end

	return {
		g = table.concat(
			group_parts,
			"."
		),
		a = artifact,
		latestVersion = version,
	}
end

--------------------------------------------------------------------------------
-- SCAN
--------------------------------------------------------------------------------

local function collect(root, callback)
	vim.system(
		{
			"find",
			root,
			"-name",
			"*.pom",
		},
		{ text = true },
		function(result)
			vim.schedule(function()
				if result.code ~= 0 then
					callback(
						nil,
						Util.trim(
							result.stderr
								or "find failed"
						)
					)

					return
				end

				local prefix = root .. "/"
				local seen = {}
				local entries = {}

				for line in (result.stdout or ""):gmatch(
					"[^\n]+"
				) do
					if Util.starts_with(
						line,
						prefix
					) then
						local parsed =
							M.parse_relative_path(
								line:sub(
									#prefix + 1
								)
							)

						if parsed then
							local id =
								parsed.g
								.. ":"
								.. parsed.a

							local version = parsed.latestVersion
							local existing = seen[id]

							if existing then
								if not existing.known[version] then
									existing.known[version] = true

									table.insert(
										existing.entry.versions,
										version
									)

									-- Compared as versions, not as text:
									-- "10.0" is newer than "9.0".
									if VersionRank.compare_values(
										version,
										existing.entry.latestVersion
									) > 0 then
										existing.entry.latestVersion =
											version
									end
								end
							else
								parsed.versions = { version }

								seen[id] = {
									entry = parsed,
									known = { [version] = true },
								}

								table.insert(
									entries,
									parsed
								)
							end
						end
					end
				end

				callback(entries, nil)
			end)
		end
	)
end

--------------------------------------------------------------------------------
-- CATALOG
--
-- Scanned once per session. Measured on a 1.4 GB repository: 0.58 s cold,
-- 0.04 s warm, for 2110 files and 770 coordinates. Small enough to keep in
-- memory and not worth persisting.
--
-- The scan runs through the shared pipeline, so completion requests that
-- arrive while it is running wait for that one scan instead of starting
-- their own.
--------------------------------------------------------------------------------

local function pipeline(source)
	if not source.local_repository_pipeline then
		source.local_repository_pipeline = Pipeline.new({
			name = "local-repository",
		})
	end

	return source.local_repository_pipeline
end

function M.catalog(source, callback)
	if not enabled(source) then
		callback({})
		return
	end

	local root = M.root(source)

	pipeline(source):fetch({
		key = root,

		fetch = function(done)
			if vim.fn.isdirectory(root) ~= 1 then
				done({}, nil)
				return
			end

			collect(root, function(entries, err)
				if err then
					Util.debug_log(
						source,
						"Local repository scan failed: %s",
						err
					)
				else
					Util.debug_log(
						source,
						"Local repository scanned: %d coordinates",
						#entries
					)
				end

				-- A failed scan is remembered as an empty catalog. The
				-- alternative is walking the whole repository again on
				-- every keystroke for a failure that will not go away.
				done(entries or {}, nil)
			end)
		end,
	}, function(entries)
		callback(entries or {})
	end)
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- The versions of one coordinate that are present on disk. Looking a
-- coordinate up by scanning the catalog would be a linear walk per request,
-- so each catalog gets an index the first time it is asked.
--------------------------------------------------------------------------------

-- Keyed by the catalog table itself and weak, so an index lives exactly as
-- long as the catalog it describes and the catalog stays a plain list.
local INDEXES = setmetatable({}, { __mode = "k" })

local function index_of(entries)
	local index = INDEXES[entries]

	if index then
		return index
	end

	index = {
		by_id = {},
		by_group = {},
	}

	for _, entry in ipairs(entries) do
		index.by_id[entry.g .. ":" .. entry.a] = entry

		local group = index.by_group[entry.g]

		if not group then
			group = {}
			index.by_group[entry.g] = group
		end

		table.insert(group, entry)
	end

	INDEXES[entries] = index

	return index
end

-- package is { namespace, name }.
-- callback(versions, err) where versions is a list of { value, timestamp }.
function M.versions(source, package, callback)
	M.catalog(source, function(entries)
		local entry = index_of(entries).by_id[
			package.namespace .. ":" .. package.name
		]

		local versions = {}

		for _, value in ipairs((entry and entry.versions) or {}) do
			-- The directory layout carries no publication time.
			table.insert(versions, {
				value = value,
				timestamp = 0,
			})
		end

		callback(versions, nil)
	end)
end

--------------------------------------------------------------------------------
-- PACKAGES
--
-- The artifacts of one group that are present on disk.
--
-- callback(packages, err) where packages is a list of
-- { name, latest_version }.
--------------------------------------------------------------------------------

function M.packages(source, namespace, callback)
	M.catalog(source, function(entries)
		local packages = {}

		for _, entry in ipairs(index_of(entries).by_group[namespace] or {}) do
			table.insert(packages, {
				name = entry.a,
				latest_version = entry.latestVersion,
			})
		end

		table.sort(packages, function(left, right)
			return left.name < right.name
		end)

		callback(packages, nil)
	end)
end

--------------------------------------------------------------------------------
-- PACKAGE SEARCH
--
-- Free text against the coordinates on disk. A coordinate matches when it
-- contains the text as typed, or, for several words, every one of them.
--
-- callback(packages, err) where packages is a list of
-- { namespace, name, latest_version }.
--------------------------------------------------------------------------------

function M.search_packages(source, text, callback)
	local needle = Util.lower(Util.trim(text))

	if needle == "" then
		callback({}, nil)
		return
	end

	local tokens = Util.split_tokens(needle)

	M.catalog(source, function(entries)
		local packages = {}

		for _, entry in ipairs(entries or {}) do
			local id = Util.lower(entry.g .. ":" .. entry.a)

			local hit = id:find(needle, 1, true) ~= nil

			if not hit and #tokens > 1 then
				hit = true

				for _, token in ipairs(tokens) do
					if not id:find(token, 1, true) then
						hit = false
						break
					end
				end
			end

			if hit then
				table.insert(packages, {
					namespace = entry.g,
					name = entry.a,
					latest_version = entry.latestVersion,
				})
			end
		end

		callback(packages, nil)
	end)
end

--------------------------------------------------------------------------------
-- REGISTRY
--
-- The local repository as seen through the contract in
-- blink_deps.registries.
--------------------------------------------------------------------------------

function M.is_enabled(source)
	return enabled(source)
end

M.REGISTRY = {
	id = "local",
	name = "Local repository",
	kind = "local",

	-- Answers from disk. What it knows is only what this machine happens
	-- to have downloaded, never the full picture.
	offline = true,

	capabilities = {
		versions = true,
		packages = true,
		search = true,
	},

	search = function(_, source, text, callback)
		M.search_packages(source, text, callback)
	end,

	versions = function(_, source, package, callback)
		M.versions(source, package, callback)
	end,

	packages = function(_, source, namespace, callback)
		M.packages(source, namespace, callback)
	end,
}

return M
