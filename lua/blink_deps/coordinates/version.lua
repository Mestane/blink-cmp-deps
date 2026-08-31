local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Repository =
	require("blink_deps.repository")
local VersionRank =
	require("blink_deps.version_rank")
local Common =
	require("blink_deps.coordinates.common")

local M = {}

local lower = Util.lower
local trim = Util.trim
local response = Util.response
local make_range = Util.make_range

local VERSION_SCORE_STEP = 100

local function version_matches_query(
	version,
	value
)
	local query = lower(trim(value))

	if query == "" then
		return true
	end

	return lower(version):find(
		query,
		1,
		true
	) ~= nil
end

local function version_score_offset(
	value,
	version,
	index,
	total
)
	if not version_matches_query(
		version,
		value
	) then
		return 0
	end

	return (total - index + 1)
		* VERSION_SCORE_STEP
end

local function configured_repositories(
	source
)
	local repositories =
		source.opts
		and source.opts.repositories

	if type(repositories) ~= "table" then
		return {}
	end

	local result = {}

	for _, repository in ipairs(
		repositories
	) do
		if type(repository) == "table"
			and type(repository.url)
				== "string"
			and repository.url ~= ""
		then
			table.insert(
				result,
				repository
			)
		end
	end

	return result
end

function M.complete(
	source,
	context,
	ctx,
	group_id,
	artifact_id,
	callback
)
	if not group_id
		or group_id == ""
		or not artifact_id
		or artifact_id == ""
	then
		callback(
			response({}, true)
		)

		return nil
	end

	local cache_key =
		group_id
		.. ":"
		.. artifact_id

	--------------------------------------------------------------------------
	-- COMPLETE DERIVED CACHE
	--
	-- version_catalog is written only after every configured backend has
	-- finished successfully. Therefore an entry here is a complete
	-- Central + repository result and can safely be returned immediately.
	--------------------------------------------------------------------------

	local cached =
		source.version_catalog[
			cache_key
		]

	if cached then
		local range =
			make_range(
				context,
				ctx.value
			)

		local items = {}

		for index, version in ipairs(
			cached
		) do
			table.insert(items, {
				label = version.value,
				kind =
					Common.KIND.Constant,

				score_offset =
					version_score_offset(
						ctx.value,
						version.value,
						index,
						#cached
					),

				sortText =
					string.format(
						"%06d",
						index
					),

				labelDetails = {
					description =
						cache_key,
				},

				textEdit = {
					range = range,
					newText =
						version.value,
				},
			})
		end

		callback(
			response(
				items,
				true
			)
		)

		return nil
	end

	--------------------------------------------------------------------------
	-- INITIAL EMPTY RESULT
	--------------------------------------------------------------------------

	callback(response({}, true))

	local cancelled = false

	local repositories =
		configured_repositories(source)

	--------------------------------------------------------------------------
	-- AGGREGATION
	--
	-- One backend is always Maven Central, followed by zero or more custom
	-- Maven repositories.
	--------------------------------------------------------------------------

	local pending =
		1 + #repositories

	local backend_failed = false

	local seen = {}
	local versions = {}

	local function add_version(
		value,
		timestamp
	)
		if not value or value == "" then
			return
		end

		timestamp =
			tonumber(timestamp) or 0

		local existing =
			seen[value]

		if existing then
			if timestamp
				> existing.timestamp
			then
				existing.timestamp =
					timestamp
			end

			return
		end

		local entry = {
			value = value,
			timestamp = timestamp,
		}

		seen[value] = entry

		table.insert(
			versions,
			entry
		)
	end

	local function sort_versions()
		VersionRank.sort(versions)
	end

	local function build_items()
		local range =
			make_range(
				context,
				ctx.value
			)

		local items = {}

		for index, version in ipairs(
			versions
		) do
			table.insert(items, {
				label = version.value,
				kind =
					Common.KIND.Constant,

				score_offset =
					version_score_offset(
						ctx.value,
						version.value,
						index,
						#versions
					),

				sortText =
					string.format(
						"%06d",
						index
					),

				labelDetails = {
					description =
						cache_key,
				},

				textEdit = {
					range = range,
					newText =
						version.value,
				},
			})
		end

		return items
	end

	local function backend_finished()
		pending = pending - 1

		sort_versions()

		------------------------------------------------------------------
		-- Cache only the COMPLETE aggregate.
		--
		-- If Central finishes first while a private repository is still
		-- running, storing the partial result here would cause a later
		-- completion request to incorrectly skip the repository.
		--
		-- An empty aggregate is only cached when every backend actually
		-- answered. Caching the empty result of a timed out request left
		-- version completion dead for that coordinate until Neovim
		-- restarted. A partial aggregate is still worth caching: one
		-- backend being down must not discard what the others returned.
		------------------------------------------------------------------

		if pending == 0
			and (
				not backend_failed
				or #versions > 0
			)
		then
			source.version_catalog[
				cache_key
			] = vim.deepcopy(
				versions
			)
		end

		if cancelled then
			return
		end

		callback(
			response(
				build_items(),
				pending > 0
			)
		)
	end

	local function start_backends()
		-- Blink issues a completion request per keystroke. Deferring the
		-- network work keeps superseded prefixes off the wire.
		if cancelled then
			return
		end

		----------------------------------------------------------------------
		-- MAVEN CENTRAL
		----------------------------------------------------------------------

		local q =
			"g:"
			.. group_id
			.. " AND a:"
			.. artifact_id

		Central.search(
			source,
			"version:" .. cache_key,
			{
				q = q,
				core = "gav",
				rows = tostring(
					Common.VERSION_ROWS
				),
				wt = "json",
			},
			function(docs, err)
				if err then
					backend_failed = true
				else
					for _, doc in ipairs(
						docs or {}
					) do
						add_version(
							doc.v
								or doc.latestVersion,
							doc.timestamp
						)
					end
				end

				backend_finished()
			end
		)

		----------------------------------------------------------------------
		-- CUSTOM MAVEN REPOSITORIES
		----------------------------------------------------------------------

		for _, repository in ipairs(
			repositories
		) do
			Repository.versions(
				source,
				repository,
				group_id,
				artifact_id,
				function(
					repository_versions,
					err
				)
					if err then
						backend_failed = true
					end

					for _, value in ipairs(
						repository_versions
							or {}
					) do
						add_version(
							value,
							0
						)
					end

					backend_finished()
				end
			)
		end
	end

	-- Not aliased at the top of the file so tests can replace Util.defer
	-- after this module has already been loaded.
	Util.defer(
		Common.debounce_ms(source),
		start_backends
	)

	return function()
		cancelled = true
	end
end

return M
