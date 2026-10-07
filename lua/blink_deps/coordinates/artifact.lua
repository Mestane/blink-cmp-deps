local Util = require("blink_deps.util")
local Registries = require("blink_deps.registries")
local Common = require("blink_deps.coordinates.common")

local M = {}

local lower = Util.lower
local trim = Util.trim
local response = Util.response
local make_range = Util.make_range

local function artifact_score_offset(artifact, value)
	local a = lower(artifact)
	local v = lower(trim(value))

	if v == "" then
		return 0
	end

	if a == v then
		return 20
	end

	if a:find(v, 1, true) then
		return 8
	end

	return 0
end

local function build_artifact_item(
	context,
	ctx,
	group_id,
	entry,
	source_name,
	data_key
)
	return {
		label = entry.name,
		kind = Common.KIND.Field,
		score_offset = artifact_score_offset(entry.name, ctx.value),
		labelDetails = {
			description = source_name,
		},
		textEdit = {
			range = make_range(context, ctx.value),
			newText = entry.name,
		},
		data = {
			[data_key] = {
				kind = "artifact",
				groupId = group_id,
				artifactId = entry.name,
				latestVersion = entry.latest_version or "unknown",
			},
		},
	}
end

--------------------------------------------------------------------------------
-- LEARNED PACKAGES
--
-- Everything any registry has returned for a group this session, with the
-- name it was shown under. A later request for the same group is answered
-- from here at once instead of waiting behind the debounce for registries
-- that would only repeat themselves.
--------------------------------------------------------------------------------

local function learned(source, group_id)
	local catalog = source.artifact_catalog[group_id]

	if not catalog then
		catalog = {
			entries = {},
			known = {},
		}

		source.artifact_catalog[group_id] = catalog
	end

	return catalog
end

local function learn(source, group_id, packages, source_name)
	local catalog = learned(source, group_id)

	for _, package in ipairs(packages or {}) do
		if type(package.name) == "string"
			and package.name ~= ""
			and not catalog.known[package.name]
		then
			catalog.known[package.name] = true

			table.insert(catalog.entries, {
				name = package.name,
				latest_version = package.latest_version,
				source_name = source_name,
			})
		end
	end
end

-- A configured registry is named next to its results. Results from the
-- public default one show the group instead: naming the registry everyone
-- uses on every row would say nothing.
local function display_name(registry, group_id)
	if registry.public then
		return group_id
	end

	return registry.name
end

--------------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------------

function M.complete(source, context, ctx, group_id, callback, opts)
	opts = opts or {}

	if not group_id or group_id == "" then
		callback(response({}, true))

		return nil
	end

	local data_key = opts.data_key or "deps"

	local cancelled = false
	local sent = {}
	local called = false

	-- entries are { name, latest_version }. A per entry source_name wins
	-- over the one given for the batch.
	local function emit(entries, source_name)
		if cancelled then
			return
		end

		local items = {}

		for _, entry in ipairs(entries or {}) do
			if entry.name and not sent[entry.name] then
				sent[entry.name] = true

				table.insert(
					items,
					build_artifact_item(
						context,
						ctx,
						group_id,
						entry,
						entry.source_name or source_name or group_id,
						data_key
					)
				)
			end
		end

		if #items > 0 or not called then
			called = true

			callback(response(items, true))
		end
	end

	-- What is already known for this group, or the opening empty response.
	emit(learned(source, group_id).entries, group_id)

	--------------------------------------------------------------------------
	-- EXTRA SEARCH
	--
	-- A hook for a backend that is not a registry, such as the JDTLS Maven
	-- index. It still speaks the older { artifact, latestVersion } shape.
	--------------------------------------------------------------------------

	if opts.extra_search then
		opts.extra_search(function(entries, source_name)
			local packages = {}

			for _, entry in ipairs(entries or {}) do
				table.insert(packages, {
					name = entry.name or entry.artifact,
					latest_version =
						entry.latest_version or entry.latestVersion,
				})
			end

			emit(packages, source_name)
		end)
	end

	--------------------------------------------------------------------------
	-- REGISTRIES
	--
	-- Every registry that can list the packages of a namespace is asked.
	-- Which registries those are is decided by configuration, not here.
	--------------------------------------------------------------------------

	Registries.dispatch(
		source,
		"packages",
		{
			debounce_ms = Common.debounce_ms(source),
			cancelled = function()
				return cancelled
			end,
		},
		function(registry)
			registry:packages(source, group_id, function(packages, err)
				if err then
					Common.notify_once(
						source,
						table.concat({
							"packages",
							registry.id,
							group_id,
						}, ":"),
						(opts.error_prefix or "Dependency completion")
							.. ": "
							.. registry.name
							.. " artifact search failed: "
							.. tostring(err)
					)

					return
				end

				local name = display_name(registry, group_id)

				-- Learned before the cancelled check inside emit() so a
				-- superseded but successful response is still kept.
				learn(source, group_id, packages, name)

				emit(packages, name)
			end)
		end
	)

	return function()
		cancelled = true
	end
end

function M.debug_queries(group_id, value, artifact_id)
	local result = {
		group_catalog = "g:" .. (group_id or ""),
	}

	if artifact_id and artifact_id ~= "" then
		result.version_query =
			"g:" .. group_id .. " AND a:" .. artifact_id
	end

	return result
end

return M
