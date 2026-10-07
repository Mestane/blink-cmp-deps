local Registries = require("blink_deps.registries")
local Util = require("blink_deps.util")

--------------------------------------------------------------------------------
-- NAME COMPLETION
--
-- Offers packages by name, gathered from every registry of the source that
-- can search. The same for every ecosystem that names a package with one
-- string: what differs is how names compare and what accepting one writes,
-- and both are passed in.
--------------------------------------------------------------------------------

local M = {}

local lower = Util.lower
local response = Util.response
local make_range = Util.make_range

-- Ranking: a package named exactly what was typed is the one meant, and one
-- starting with it is likelier than one merely containing it. Within each
-- tier the registry's own order is kept.
M.EXACT_BONUS = 10000
M.PREFIX_BONUS = 1000

-- A package already in use on this machine is one the user works with.
-- Within a tier it goes above the ones they have never used, however
-- popular those are.
M.USED_BONUS = 500

local function score(name, typed, position, total, normalize)
	local candidate = normalize(name)
	local wanted = normalize(typed)

	local base = total - position + 1

	if candidate == wanted then
		return base + M.EXACT_BONUS
	end

	if Util.starts_with(candidate, wanted) then
		return base + M.PREFIX_BONUS
	end

	return base
end

--------------------------------------------------------------------------------
-- MERGING
--
-- Every registry's answer in one list, each package once.
--
-- A registry answering from disk knows which packages are in use here, but
-- only the releases it has seen; a remote one knows the current release.
-- So a package both of them report takes its details from the remote answer
-- and is marked as used.
--------------------------------------------------------------------------------

local function merge(answers)
	local packages = {}
	local by_name = {}
	local used = {}

	local function add(package)
		local name = package.name

		if type(name) == "string" and name ~= "" and not by_name[name] then
			by_name[name] = package
			table.insert(packages, package)
		end
	end

	for _, answer in ipairs(answers) do
		if answer.offline then
			for _, package in ipairs(answer.packages) do
				if type(package.name) == "string" then
					used[package.name] = true
				end
			end
		else
			for _, package in ipairs(answer.packages) do
				add(package)
			end
		end
	end

	-- Packages only the disk knows about: offline, or simply not among the
	-- remote results.
	for _, answer in ipairs(answers) do
		if answer.offline then
			for _, package in ipairs(answer.packages) do
				add(package)
			end
		end
	end

	return packages, used
end

--------------------------------------------------------------------------------
-- COMPLETE
--
-- source    whose registries are asked
-- context   blink's completion context
-- ctx       { value }: what has been typed of the name
-- callback  receives one blink response
-- opts:
--   typed      the text to search for
--   min_chars  the shortest text worth searching for
--   normalize  function(name) giving the form names are compared in, for
--              ecosystems where differently spelled names are the same
--   text       function(package) giving what accepting it writes
--   data       function(package) giving the item's data, for resolve
--   kind       completion item kind, optional
--   noun       what a package is called in log messages, optional
--
-- Returns a function that cancels the request.
--
-- The menu is filled once, when every registry has answered. Answering as
-- each arrives would show a package found on disk with the release that was
-- current when it was downloaded, and an item already in the menu cannot be
-- corrected by the answer that knows better.
--------------------------------------------------------------------------------

function M.complete(source, context, ctx, callback, opts)
	local typed = opts.typed

	if #typed < opts.min_chars then
		callback(response({}, true))

		return nil
	end

	local registries = Registries.with(source, "search")

	-- Nothing is configured to answer. The request still has to be closed,
	-- or the menu would wait on it forever.
	if #registries == 0 then
		callback(response({}, false))

		return nil
	end

	local range = make_range(context, ctx.value)

	local cancelled = false
	local pending = #registries
	local answers = {}

	local positions = {}

	for position, registry in ipairs(registries) do
		positions[registry] = position
	end

	local function build_items()
		local packages, used = merge(answers)
		local items = {}

		for position, package in ipairs(packages) do
			local name = package.name

			table.insert(items, {
				label = name,
				kind = opts.kind or Util.KIND.Module,
				score_offset = score(name, typed, position, #packages, opts.normalize)
					+ (used[name] and M.USED_BONUS or 0),
				labelDetails = {
					description = package.latest_version,
				},
				textEdit = {
					range = range,
					newText = opts.text(package),
				},
				data = opts.data(package),
			})
		end

		return items
	end

	local function answered(registry, packages)
		table.insert(answers, {
			offline = registry.offline,
			position = positions[registry],
			packages = packages or {},
		})

		pending = pending - 1

		if pending > 0 or cancelled then
			return
		end

		-- Registry order, so the result does not depend on who was faster.
		table.sort(answers, function(left, right)
			return left.position < right.position
		end)

		callback(response(build_items(), true))
	end

	Registries.dispatch(
		source,
		"search",
		{
			debounce_ms = Util.search_debounce_ms(source),
			cancelled = function()
				return cancelled
			end,
		},
		function(registry)
			registry:search(source, lower(typed), function(packages, err)
				if err then
					Util.debug_log(
						source,
						"%s search failed in %s for %s: %s",
						opts.noun or "Package",
						registry.name,
						typed,
						tostring(err)
					)
				end

				-- A failed registry still counts as answered: the others
				-- must not wait on it.
				answered(registry, packages)
			end)
		end
	)

	return function()
		cancelled = true
	end
end

return M
