local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Registries = require("blink_deps.registries")
local Common =
	require("blink_deps.coordinates.common")

local M = {}

local lower = Util.lower
local trim = Util.trim
local starts_with = Util.starts_with
local sorted_keys = Util.sorted_keys
local response = Util.response
local make_range = Util.make_range

M.is_reverse_domain_qualified =
	Common.is_reverse_domain_qualified
M.split_tokens = Common.split_tokens

local function qualified_parent_and_tail(
	value
)
	local parent, tail =
		value:match(
			"^(.*)%.([^%.]*)$"
		)

	if not parent then
		return nil, value
	end

	return parent, tail or ""
end

local function semantic_group_allowed(
	group,
	value
)
	local v = lower(trim(value))

	if v == "" then
		return true
	end

	if M.is_reverse_domain_qualified(v) then
		local parent, tail =
			qualified_parent_and_tail(v)

		if parent and parent ~= "" then
			local namespace =
				parent .. "."

			if not starts_with(
				lower(group),
				namespace
			)
				and not starts_with(
					lower(group),
					v
				)
			then
				return false
			end

			if tail == "" then
				return true
			end
		end
	end

	return true
end

local function group_score_offset(
	group,
	value
)
	local g = lower(group)
	local v = lower(trim(value))

	if v == "" then
		return 0
	end

	if g == v then
		return 20
	end

	if starts_with(g, v) then
		return 12
	end

	local score = 0

	for _, token in ipairs(
		M.split_tokens(v)
	) do
		if #token >= 2
			and g:find(
				token,
				1,
				true
			)
		then
			score = score + 3
		end
	end

	return math.min(score, 9)
end


local function qualified_group_depth(
	group,
	value
)
	local v = lower(trim(value))

	if not M.is_reverse_domain_qualified(
		v
	) then
		return nil
	end

	local parent =
		qualified_parent_and_tail(v)

	if not parent
		or parent == ""
	then
		return nil
	end

	local namespace =
		parent .. "."

	local g = lower(group)

	if not starts_with(
		g,
		namespace
	) then
		return nil
	end

	local remainder =
		g:sub(
			#namespace + 1
		)

	if remainder == "" then
		return 0
	end

	local depth = 1

	for _ in remainder:gmatch("%.") do
		depth = depth + 1
	end

	return depth
end

-- Blink re-sorts completion items by score_offset, so namespace depth
-- has to survive into the item itself and not only into the Lua array
-- order produced by rank_groups_from_docs().
--
-- Depth is the dominant term. Semantic and discovery scores share a
-- band that stays below QUALIFIED_DEPTH_STEP so a deep namespace with
-- many artifacts can never outrank a direct child.
local QUALIFIED_DEPTH_BASE = 1000
local QUALIFIED_DEPTH_STEP = 100
local QUALIFIED_MAX_DEPTH = 9
local QUALIFIED_DISCOVERY_BAND = 60
local QUALIFIED_DISCOVERY_HALF = 200

local function qualified_discovery_term(
	discovery_score
)
	local score = discovery_score or 0

	if score <= 0 then
		return 0
	end

	-- Squashed instead of clamped so discovery still orders groups
	-- that share the same depth, however many artifacts they have.
	return math.floor(
		QUALIFIED_DISCOVERY_BAND
		* score
		/ (
			score
			+ QUALIFIED_DISCOVERY_HALF
		)
	)
end

local function group_rank_offset(
	group,
	value,
	discovery_score
)
	local semantic =
		group_score_offset(
			group,
			value
		)

	local depth =
		qualified_group_depth(
			group,
			value
		)

	-- Plain discovery queries such as "spring" keep the raw
	-- discovery model.
	if not depth then
		return semantic
			+ (discovery_score or 0)
	end

	local capped =
		math.min(
			depth,
			QUALIFIED_MAX_DEPTH
		)

	return QUALIFIED_DEPTH_BASE
		- capped * QUALIFIED_DEPTH_STEP
		+ semantic
		+ qualified_discovery_term(
			discovery_score
		)
end

--------------------------------------------------------------------------------
-- ORDER
--
-- Registries report namespaces with a score. The order they are offered in
-- is decided here, the same way whichever registry they came from: nearer
-- namespaces first, then the stronger match, then the name.
--------------------------------------------------------------------------------

local function rank_namespaces(namespaces, value)
	local scores = {}
	local groups = {}

	for _, namespace in ipairs(namespaces or {}) do
		local group = type(namespace) == "table" and namespace.name or nil

		if type(group) == "string" and group ~= "" then
			if scores[group] == nil then
				table.insert(groups, group)
			end

			scores[group] =
				(scores[group] or 0)
				+ (tonumber(namespace.score) or 0)
		end
	end

	table.sort(groups, function(a, b)
		local a_depth = qualified_group_depth(a, value)
		local b_depth = qualified_group_depth(b, value)

		if a_depth and b_depth and a_depth ~= b_depth then
			return a_depth < b_depth
		end

		local a_score = scores[a] or 0
		local b_score = scores[b] or 0

		if a_score ~= b_score then
			return a_score > b_score
		end

		local a_semantic = group_score_offset(a, value)
		local b_semantic = group_score_offset(b, value)

		if a_semantic ~= b_semantic then
			return a_semantic > b_semantic
		end

		return lower(a) < lower(b)
	end)

	return groups, scores
end

local function build_group_item(
	context,
	ctx,
	group,
	source_name,
	data_key,
	discovery_score
)
	return {
		label = group,
		kind = Common.KIND.Module,
		score_offset =
			group_rank_offset(
				group,
				ctx.value,
				discovery_score
			),
		labelDetails = {
			description = source_name,
		},
		textEdit = {
			range =
				make_range(
					context,
					ctx.value
				),
			newText = group,
		},
		data = {
			[data_key] = {
				kind = "group",
				groupId = group,
			},
		},
	}
end

local function remember_groups(
	source,
	groups
)
	for _, group in ipairs(
		groups or {}
	) do
		if group and group ~= "" then
			source.group_memory[group] =
				true
		end
	end
end

-- The Maven Central queries for a value, as { key, q }. Kept for
-- diagnostics; the queries themselves belong to the Central registry.
function M.plan_central_queries(value)
	local plans = {}

	for _, plan in ipairs(Central.namespace_plans(value)) do
		table.insert(plans, {
			key = plan.key,
			q = plan.q,
		})
	end

	return plans
end

--------------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------------

function M.complete(source, context, ctx, callback, opts)
	opts = opts or {}

	local data_key = opts.data_key or "deps"

	local local_source_name = opts.local_source_name or "Dependencies"

	local cancelled = false
	local sent = {}
	local called = false

	local function emit(groups, source_name, group_scores)
		remember_groups(source, groups)

		if cancelled then
			return
		end

		local items = {}

		for _, group in ipairs(groups or {}) do
			if not sent[group]
				and semantic_group_allowed(group, ctx.value)
			then
				sent[group] = true

				table.insert(
					items,
					build_group_item(
						context,
						ctx,
						group,
						source_name or local_source_name,
						data_key,
						group_scores and group_scores[group] or 0
					)
				)
			end
		end

		if #items > 0 or not called then
			called = true

			callback(response(items, true))
		end
	end

	-- Previously discovered session groups arrive before anything
	-- asynchronous.
	emit(sorted_keys(source.group_memory), local_source_name)

	local text = trim(ctx.value)

	if #text < Common.GROUP_MIN_CHARS then
		return function()
			cancelled = true
		end
	end

	-- A hook for a backend that is not a registry, such as the JDTLS Maven
	-- index.
	if opts.extra_search then
		opts.extra_search(emit)
	end

	--------------------------------------------------------------------------
	-- REGISTRIES
	--
	-- Every registry that knows namespaces is asked. Blink cancels the
	-- previous request on every keystroke, so the network waits for the
	-- debounce and intermediate prefixes never leave the machine.
	--------------------------------------------------------------------------

	Registries.dispatch(
		source,
		"namespaces",
		{
			debounce_ms = Common.debounce_ms(source),
			cancelled = function()
				return cancelled
			end,
		},
		function(registry)
			registry:namespaces(source, text, function(namespaces, err)
				if err then
					-- The public registry is asked on every search and
					-- fails at random; a notification each time would be
					-- noise, so the caller decides what to do with it. A
					-- registry the user configured is their own
					-- infrastructure, and they are told once.
					if registry.public then
						if opts.on_group_error then
							opts.on_group_error(text, err)
						end
					else
						Common.notify_once(
							source,
							table.concat({
								"namespaces",
								registry.id,
								text,
							}, ":"),
							(opts.error_prefix or "Dependency completion")
								.. ": "
								.. registry.name
								.. " group search failed: "
								.. tostring(err)
						)
					end

					return false
				end

				-- A registry that pages reports each page as it arrives,
				-- and each one is shown at once instead of waiting for the
				-- rest.
				--
				-- emit() still remembers groups from a stale completion
				-- while keeping them out of its menu.
				local groups, scores = rank_namespaces(namespaces, ctx.value)

				emit(groups, registry.name, scores)

				-- Tells a paging registry whether to go on.
				return not cancelled
			end)
		end
	)

	return function()
		cancelled = true
	end
end

function M.debug_plan(value)
	local queries = {}

	for _, plan in ipairs(M.plan_central_queries(value)) do
		table.insert(queries, plan.q)
	end

	return {
		value = value,
		central = queries,
	}
end

return M
