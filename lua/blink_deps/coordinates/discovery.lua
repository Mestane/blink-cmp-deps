local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Registries = require("blink_deps.registries")
local Common = require("blink_deps.coordinates.common")

local M = {}

local lower = Util.lower
local trim = Util.trim
local response = Util.response
local make_range = Util.make_range

M.MIN_CHARS = 3
M.ROWS = Central.SEARCH_ROWS

-- A coordinate already on disk is one the user has actually pulled into a
-- project. That is a far better relevance signal than anything a search
-- API exposes, so results found on disk sort above everything remote.
M.LOCAL_SCORE_BONUS = 1000

--------------------------------------------------------------------------------
-- SEARCH TEXT
--
-- Decides whether what was typed is a search at all. How a search is then
-- phrased for a particular backend is that registry's business.
--------------------------------------------------------------------------------

local function search_text(value)
	local text = trim(lower(value or ""))

	-- Quotes carry no meaning for a search and would have to be escaped
	-- differently by every backend.
	text = text:gsub('"', "")

	if #text < M.MIN_CHARS then
		return nil
	end

	-- A coordinate being typed belongs to group completion.
	if Common.is_reverse_domain_qualified(text) then
		return nil
	end

	return text
end

-- The Maven Central query for a value, or nil when the value is not a
-- search. Sources use this to decide between discovery and group
-- completion.
function M.plan_query(value)
	local text = search_text(value)

	if not text then
		return nil
	end

	return Central.search_query(text)
end

--------------------------------------------------------------------------------
-- ITEMS
--------------------------------------------------------------------------------

-- Gradle replaces one string with the whole coordinate. Maven splits it
-- across two XML elements, so the caller decides what gets edited.
local function default_edit(context, ctx, group, artifact)
	return {
		range = make_range(context, ctx.value),
		newText = group .. ":" .. artifact .. ":",
	}
end

local function build_item(context, ctx, package, data_key, bonus, edit)
	local group = package.namespace
	local artifact = package.name

	return {
		-- The whole point of discovery is that the user does not know the
		-- group yet, and the same artifact id is published under many of
		-- them. A label of just the artifact id renders as a column of
		-- identical rows, so the group has to be in the label itself.
		label = group .. ":" .. artifact,
		kind = Common.KIND.Field,
		score_offset = Common.discovery_doc_score(
			{ g = group, a = artifact },
			ctx.value
		) + (bonus or 0),
		labelDetails = {
			description = package.latest_version,
		},
		textEdit = (edit or default_edit)(context, ctx, group, artifact),
		data = {
			[data_key] = {
				kind = "artifact",
				groupId = group,
				artifactId = artifact,
				latestVersion = package.latest_version or "unknown",
			},
		},
	}
end

--------------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------------

function M.complete(source, context, ctx, callback, opts)
	opts = opts or {}

	local data_key = opts.data_key or "deps"

	local cancelled = false
	local sent = {}
	local called = false

	local function emit(packages, bonus)
		if cancelled then
			return
		end

		local items = {}

		for _, package in ipairs(packages or {}) do
			local group = package.namespace
			local artifact = package.name

			if type(group) == "string"
				and group ~= ""
				and type(artifact) == "string"
				and artifact ~= ""
			then
				local id = group .. ":" .. artifact

				if not sent[id] then
					sent[id] = true

					table.insert(
						items,
						build_item(
							context,
							ctx,
							package,
							data_key,
							bonus,
							opts.edit
						)
					)
				end
			end
		end

		if #items > 0 or not called then
			called = true

			callback(response(items, true))
		end
	end

	local text = search_text(ctx.value)

	if not text then
		callback(response({}, true))

		return function()
			cancelled = true
		end
	end

	--------------------------------------------------------------------------
	-- REGISTRIES
	--
	-- Every registry that can search is asked. One answering from disk
	-- needs no network, so it is asked at once instead of waiting behind
	-- the debounce; the rest wait, because a partly typed search term is
	-- never a useful query.
	--------------------------------------------------------------------------

	Registries.dispatch(
		source,
		"search",
		{
			debounce_ms = Common.discovery_debounce_ms(source),
			cancelled = function()
				return cancelled
			end,
		},
		function(registry)
			registry:search(source, text, function(packages, err)
				if err then
					Util.debug_log(
						source,
						"Discovery search failed in %s for %s: %s",
						registry.name,
						text,
						tostring(err)
					)

					return
				end

				emit(
					packages,
					registry.offline and M.LOCAL_SCORE_BONUS or 0
				)
			end)
		end
	)

	return function()
		cancelled = true
	end
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS
--------------------------------------------------------------------------------

function M.debug_query(value)
	return {
		value = value,
		central = M.plan_query(value),
	}
end

return M
