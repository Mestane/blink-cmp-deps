local Pipeline = require("blink_deps.pipeline")
local Util = require("blink_deps.util")

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

							local existing =
								seen[id]

							if existing then
								-- Keep the newest version seen for
								-- the coordinate.
								if parsed.latestVersion
									> existing.latestVersion
								then
									existing.latestVersion =
										parsed.latestVersion
								end
							else
								seen[id] = parsed

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

return M
