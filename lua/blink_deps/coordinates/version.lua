local Util = require("blink_deps.util")
local Registries = require("blink_deps.registries")
local VersionRank = require("blink_deps.version_rank")
local Common = require("blink_deps.coordinates.common")

local M = {}

local lower = Util.lower
local trim = Util.trim
local response = Util.response
local make_range = Util.make_range

local VERSION_SCORE_STEP = 100

local function version_matches_query(version, value)
	local query = lower(trim(value))

	if query == "" then
		return true
	end

	return lower(version):find(query, 1, true) ~= nil
end

local function version_score_offset(value, version, index, total)
	if not version_matches_query(version, value) then
		return 0
	end

	return (total - index + 1) * VERSION_SCORE_STEP
end

--------------------------------------------------------------------------------
-- ITEMS
--------------------------------------------------------------------------------

local function build_items(context, ctx, versions, description)
	local range = make_range(context, ctx.value)
	local items = {}

	for index, version in ipairs(versions) do
		table.insert(items, {
			label = version.value,
			kind = Common.KIND.Constant,

			score_offset = version_score_offset(
				ctx.value,
				version.value,
				index,
				#versions
			),

			sortText = string.format("%06d", index),

			labelDetails = {
				description = description,
			},

			textEdit = {
				range = range,
				newText = version.value,
			},
		})
	end

	return items
end

--------------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------------

function M.complete(source, context, ctx, group_id, artifact_id, callback)
	if not group_id
		or group_id == ""
		or not artifact_id
		or artifact_id == ""
	then
		callback(response({}, true))

		return nil
	end

	local cache_key = group_id .. ":" .. artifact_id

	--------------------------------------------------------------------------
	-- COMPLETE DERIVED CACHE
	--
	-- version_catalog is written only after every registry has answered.
	-- Therefore an entry here is a complete aggregate and can safely be
	-- returned immediately.
	--------------------------------------------------------------------------

	local cached = source.version_catalog[cache_key]

	if cached then
		callback(response(
			build_items(context, ctx, cached, cache_key),
			true
		))

		return nil
	end

	--------------------------------------------------------------------------
	-- INITIAL EMPTY RESULT
	--------------------------------------------------------------------------

	callback(response({}, true))

	local cancelled = false

	--------------------------------------------------------------------------
	-- AGGREGATION
	--
	-- Every registry that can list versions is asked. Which registries
	-- those are is decided by configuration, not here.
	--------------------------------------------------------------------------

	local registries = Registries.with(source, "versions")

	local pending = #registries
	local registry_failed = false

	-- Whether anything arrived from a registry that sees the whole picture.
	local remote_versions = false

	local seen = {}
	local versions = {}

	local function add_version(value, timestamp)
		if not value or value == "" then
			return
		end

		timestamp = tonumber(timestamp) or 0

		local existing = seen[value]

		if existing then
			if timestamp > existing.timestamp then
				existing.timestamp = timestamp
			end

			return
		end

		local entry = {
			value = value,
			timestamp = timestamp,
		}

		seen[value] = entry

		table.insert(versions, entry)
	end

	local function registry_finished()
		pending = pending - 1

		VersionRank.sort(versions)

		----------------------------------------------------------------------
		-- Cache only the COMPLETE aggregate.
		--
		-- If one registry finishes first while another is still running,
		-- storing the partial result here would cause a later completion
		-- request to incorrectly skip the slower one.
		--
		-- An empty aggregate is only cached when every registry actually
		-- answered. Caching the empty result of a timed out request left
		-- version completion dead for that coordinate until Neovim
		-- restarted. A partial aggregate is still worth caching: one
		-- registry being down must not discard what the others returned.
		--
		-- That holds only if a remote registry contributed. The local
		-- repository always answers, with whatever happens to be on disk.
		-- Caching that alone after a failed lookup would pin the list to
		-- the versions already downloaded for the rest of the session.
		----------------------------------------------------------------------

		if pending == 0
			and (
				not registry_failed
				or remote_versions
			)
		then
			source.version_catalog[cache_key] = vim.deepcopy(versions)
		end

		if cancelled then
			return
		end

		callback(response(
			build_items(context, ctx, versions, cache_key),
			pending > 0
		))
	end

	local function start_registries()
		-- Blink issues a completion request per keystroke. Deferring the
		-- network work keeps superseded prefixes off the wire.
		if cancelled then
			return
		end

		-- Nothing is configured to answer. The request still has to be
		-- closed, or the menu would wait on it forever.
		if pending == 0 then
			callback(response({}, false))
			return
		end

		local package = {
			namespace = group_id,
			name = artifact_id,
		}

		for _, registry in ipairs(registries) do
			registry:versions(
				source,
				package,
				function(registry_versions, err)
					if err then
						registry_failed = true

						Util.debug_log(
							source,
							"Version lookup failed in %s for %s: %s",
							registry.name,
							cache_key,
							tostring(err)
						)
					end

					for _, version in ipairs(registry_versions or {}) do
						add_version(
							version.value,
							version.timestamp
						)

						if not registry.offline then
							remote_versions = true
						end
					end

					registry_finished()
				end
			)
		end
	end

	-- Not aliased at the top of the file so tests can replace Util.defer
	-- after this module has already been loaded.
	Util.defer(
		Common.debounce_ms(source),
		start_registries
	)

	return function()
		cancelled = true
	end
end

return M
