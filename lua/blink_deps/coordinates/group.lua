local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Common =
	require("blink_deps.coordinates.common")

local M = {}

local REVERSE_DOMAIN_PREFIXES = {
	"org.",
	"com.",
	"io.",
	"net.",
	"dev.",
	"co.",
	"edu.",
	"me.",
}

local lower = Util.lower
local trim = Util.trim
local starts_with = Util.starts_with
local sorted_keys = Util.sorted_keys
local extract_groups = Util.extract_groups
local response = Util.response
local make_range = Util.make_range

function M.is_reverse_domain_qualified(
	value
)
	local v = lower(value)

	for _, prefix in ipairs(
		REVERSE_DOMAIN_PREFIXES
	) do
		if starts_with(v, prefix) then
			return true
		end
	end

	return false
end

function M.split_tokens(value)
	local tokens = {}

	for token in lower(value):gmatch(
		"[%w]+"
	) do
		if token ~= "" then
			table.insert(
				tokens,
				token
			)
		end
	end

	return tokens
end

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

local function build_group_item(
	context,
	ctx,
	group,
	source_name,
	data_key
)
	return {
		label = group,
		kind = Common.KIND.Module,
		score_offset =
			group_score_offset(
				group,
				ctx.value
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

function M.plan_central_queries(value)
	local v = lower(trim(value))

	if #v < Common.GROUP_MIN_CHARS then
		return {}
	end

	local plans = {}

	if M.is_reverse_domain_qualified(v) then
		local parent, tail =
			qualified_parent_and_tail(v)

		if parent
			and parent ~= ""
			and #tail >= 2
		then
			local seed =
				tail:sub(1, 2)

			local q =
				"g:"
				.. parent
				.. "."
				.. seed
				.. "*"

			table.insert(plans, {
				key =
					"group:q:"
					.. q,
				q = q,
			})
		elseif #v >= 6
			and not v:match("%.$")
		then
			local q =
				"g:" .. v .. "*"

			table.insert(plans, {
				key =
					"group:q:"
					.. q,
				q = q,
			})
		end

		return plans
	end

	local tokens = M.split_tokens(v)

	if #tokens >= 2 then
		local first = tokens[1]
		local last =
			tokens[#tokens]

		if #first >= 3
			and #last >= 2
		then
			local q =
				"g:*"
				.. first
				.. "*"
				.. last:sub(1, 2)
				.. "*"

			table.insert(plans, {
				key =
					"group:q:"
					.. q,
				q = q,
			})
		end
	elseif #tokens == 1
		and #tokens[1] >= 3
	then
		local seed =
			tokens[1]:sub(
				1,
				math.min(
					4,
					#tokens[1]
				)
			)

		local q_group =
			"g:*"
			.. seed
			.. "*"

		table.insert(plans, {
			key =
				"group:q:"
				.. q_group,
			q = q_group,
		})

		table.insert(plans, {
			key =
				"group:basic:"
				.. seed,
			q = seed,
		})
	end

	return plans
end

function M.complete(
	source,
	context,
	ctx,
	callback,
	opts
)
	opts = opts or {}

	local data_key =
		opts.data_key or "deps"

	local local_source_name =
		opts.local_source_name
		or "Dependencies"

	local cancelled = false
	local sent = {}
	local called = false

	local function emit(
		groups,
		source_name
	)
		if cancelled then
			return
		end

		remember_groups(
			source,
			groups
		)

		local items = {}

		for _, group in ipairs(
			groups or {}
		) do
			if not sent[group]
				and semantic_group_allowed(
					group,
					ctx.value
				)
			then
				sent[group] = true

				table.insert(
					items,
					build_group_item(
						context,
						ctx,
						group,
						source_name
							or local_source_name,
						data_key
					)
				)
			end
		end

		if #items > 0
			or not called
		then
			called = true

			callback(
				response(
					items,
					true
				)
			)
		end
	end

	-- Synchronous cold-start candidates
	-- arrive before async backends.
	emit(
		sorted_keys(
			source.group_memory
		),
		local_source_name
	)

	if #trim(ctx.value)
		< Common.GROUP_MIN_CHARS
	then
		return function()
			cancelled = true
		end
	end

	if opts.extra_search then
		opts.extra_search(emit)
	end

	for _, plan in ipairs(
		M.plan_central_queries(
			ctx.value
		)
	) do
		Central.search(
			source,
			plan.key,
			{
				q = plan.q,
				rows = tostring(
					Common.GROUP_ROWS
				),
				wt = "json",
			},
			function(docs, err)
				if err then
					if opts.on_group_error then
						opts.on_group_error(
							plan.q,
							err
						)
					end

					return
				end

				emit(
					extract_groups(docs),
					"Maven Central"
				)
			end
		)
	end

	return function()
		cancelled = true
	end
end

function M.debug_plan(value)
	local plans =
		M.plan_central_queries(value)

	local queries = {}

	for _, plan in ipairs(plans) do
		table.insert(
			queries,
			plan.q
		)
	end

	return {
		value = value,
		central = queries,
	}
end

function M.debug_seed_groups(value)
	local result = {}

	for _, group in ipairs(
		Common.BUILTIN_GROUP_HINTS
	) do
		if semantic_group_allowed(
			group,
			value
		) then
			table.insert(
				result,
				group
			)
		end
	end

	return result
end

return M
