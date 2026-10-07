local Util = require("blink_deps.util")
local Registries = require("blink_deps.registries")

--------------------------------------------------------------------------------
-- VERSION COMPLETION
--
-- Offers the versions of one package, gathered from every registry of the
-- source that can list them. The same for every ecosystem: what differs is
-- how versions are ordered and which of them are worth offering, and both
-- are passed in.
--------------------------------------------------------------------------------

local M = {}

local lower = Util.lower
local trim = Util.trim
local response = Util.response
local make_range = Util.make_range

local VERSION_SCORE_STEP = 100

local function matches_typed(version, typed)
	local query = lower(trim(typed))

	if query == "" then
		return true
	end

	return lower(version):find(query, 1, true) ~= nil
end

-- Position decides the score, so the menu keeps the order it was given.
-- A version that does not contain what was typed gets none.
local function score_offset(typed, version, index, total)
	if not matches_typed(version, typed) then
		return 0
	end

	return (total - index + 1) * VERSION_SCORE_STEP
end

--------------------------------------------------------------------------------
-- ITEMS
--------------------------------------------------------------------------------

local function build_items(context, ctx, versions, opts)
	local range = make_range(context, ctx.value)
	local items = {}

	for index, version in ipairs(versions) do
		local description = opts.label or opts.key

		if opts.describe then
			description = opts.describe(version) or description
		end

		table.insert(items, {
			label = version.value,
			kind = Util.KIND.Constant,

			score_offset = score_offset(
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
				newText = opts.text and opts.text(version) or version.value,
			},
		})
	end

	return items
end

--------------------------------------------------------------------------------
-- COMPLETE
--
-- source    whose registries are asked
-- context   blink's completion context
-- ctx       { value }: what has been typed of the version
-- callback  receives blink responses, possibly several
-- opts:
--   package   what to look up, as the registries expect it:
--             { namespace, name }
--   key       identifies the lookup in the cache
--   label     shown next to each version unless describe says otherwise;
--             the key by default
--   catalog   table holding complete results for the session
--   sort      function(entries) ordering them in place, best first
--   accept    function(version) returning false for a version that must
--             not be offered, optional
--   describe  function(version) returning the text shown next to it,
--             optional
--   text      function(version) returning what accepting it writes, for
--             ecosystems where that is more than the version itself,
--             optional
--
-- Returns a function that cancels the request.
--------------------------------------------------------------------------------

function M.complete(source, context, ctx, callback, opts)
	local cache_key = opts.key

	--------------------------------------------------------------------------
	-- COMPLETE DERIVED CACHE
	--
	-- The catalog is written only after every registry has answered.
	-- Therefore an entry here is a complete aggregate and can safely be
	-- returned immediately.
	--------------------------------------------------------------------------

	local cached = opts.catalog[cache_key]

	if cached then
		callback(response(
			build_items(context, ctx, cached, opts),
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

	local pending = #Registries.with(source, "versions")

	-- Nothing is configured to answer. The request still has to be closed,
	-- or the menu would wait on it forever.
	if pending == 0 then
		callback(response({}, false))

		return nil
	end

	local registry_failed = false

	-- Whether anything arrived from a registry that sees the whole picture.
	local remote_versions = false

	local seen = {}
	local versions = {}

	local function add_version(version)
		local value = version.value

		if not value or value == "" then
			return
		end

		if opts.accept and opts.accept(version) == false then
			return
		end

		local timestamp = tonumber(version.timestamp) or 0
		local existing = seen[value]

		if existing then
			if timestamp > existing.timestamp then
				existing.timestamp = timestamp
			end

			return
		end

		-- Copied so that what a registry cached is never altered here,
		-- and kept whole so describe can see every field it reported.
		local entry = vim.deepcopy(version)

		entry.timestamp = timestamp

		seen[value] = entry

		table.insert(versions, entry)
	end

	-- added tells whether this registry contributed anything new.
	local function registry_finished(added)
		pending = pending - 1

		----------------------------------------------------------------------
		-- Cache only the COMPLETE aggregate.
		--
		-- If one registry finishes first while another is still running,
		-- storing the partial result here would cause a later completion
		-- request to incorrectly skip the slower one.
		--
		-- An empty aggregate is only cached when every registry actually
		-- answered. Caching the empty result of a timed out request left
		-- version completion dead for that package until Neovim
		-- restarted. A partial aggregate is still worth caching: one
		-- registry being down must not discard what the others returned.
		--
		-- That holds only if a remote registry contributed. A registry
		-- answering from disk always answers, with whatever happens to be
		-- there. Caching that alone after a failed lookup would pin the
		-- list to the versions already downloaded for the rest of the
		-- session.
		----------------------------------------------------------------------

		-- Sorted once per answer that needs it: for the cache when this
		-- was the last registry, for the menu when there is something new
		-- to show.
		if pending == 0 or (added and not cancelled) then
			opts.sort(versions)
		end

		if pending == 0 and (not registry_failed or remote_versions) then
			opts.catalog[cache_key] = vim.deepcopy(versions)
		end

		if cancelled then
			return
		end

		-- A registry that added nothing while others are still running
		-- has nothing to show. The last answer always closes the request.
		if not added and pending > 0 then
			return
		end

		callback(response(
			build_items(context, ctx, versions, opts),
			pending > 0
		))
	end

	-- Versions on disk are offered at once; the network waits for the
	-- debounce, so superseded prefixes stay off the wire.
	Registries.dispatch(
		source,
		"versions",
		{
			debounce_ms = Util.debounce_ms(source),
			cancelled = function()
				return cancelled
			end,
		},
		function(registry)
			registry:versions(
				source,
				opts.package,
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

					local before = #versions

					for _, version in ipairs(registry_versions or {}) do
						add_version(version)

						if not registry.offline then
							remote_versions = true
						end
					end

					registry_finished(#versions > before)
				end
			)
		end
	)

	return function()
		cancelled = true
	end
end

return M
