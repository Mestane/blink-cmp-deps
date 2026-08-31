local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Nexus = require("blink_deps.nexus")
local Common =
	require("blink_deps.coordinates.common")

local M = {}

local MAX_QUALIFIED_GROUP_PAGES = 3

local lower = Util.lower
local trim = Util.trim
local starts_with = Util.starts_with
local sorted_keys = Util.sorted_keys
local dedupe_docs = Util.dedupe_docs
local response = Util.response
local make_range = Util.make_range
local debug_log = Util.debug_log

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

local discovery_doc_score =
	Common.discovery_doc_score

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

local function rank_groups_from_docs(
	docs,
	value
)
	local scores = {}

	for _, doc in ipairs(
		dedupe_docs(docs or {})
	) do
		local group =
			type(doc) == "table"
			and doc.g
			or nil

		if type(group) == "string"
			and group ~= ""
		then
			scores[group] =
				(scores[group] or 0)
				+ discovery_doc_score(
					doc,
					value
				)
		end
	end

	local groups = {}

	for group in pairs(scores) do
		table.insert(groups, group)
	end

        table.sort(groups, function(a, b)
		local a_depth =
			qualified_group_depth(
				a,
				value
			)

		local b_depth =
			qualified_group_depth(
				b,
				value
			)

		if a_depth
			and b_depth
			and a_depth ~= b_depth
		then
			return a_depth < b_depth
		end

		local a_score =
			scores[a] or 0

		local b_score =
			scores[b] or 0

		if a_score ~= b_score then
			return a_score > b_score
		end

		local a_semantic =
			group_score_offset(
				a,
				value
			)

		local b_semantic =
			group_score_offset(
				b,
				value
			)

		if a_semantic ~= b_semantic then
			return a_semantic
				> b_semantic
		end

		return lower(a)
			< lower(b)
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

function M.plan_central_queries(value)
	local v = lower(trim(value))

	if #v < Common.GROUP_MIN_CHARS then
		return {}
	end

	local plans = {}

	if M.is_reverse_domain_qualified(v) then
		local q =
			"g:" .. v .. "*"

		table.insert(plans, {
			key =
				"group:q:"
				.. q,
			q = q,
		})

		return plans
	end

	local tokens = M.split_tokens(v)

	if #tokens == 0 then
		return plans
	end

	-- Leading wildcards are rejected outright by Solr on the g field, so
	-- the old g:*token* plans never returned anything.
	--
	-- A bare space separated query is treated as OR, which scans a huge
	-- result set and times out. Joining the tokens explicitly keeps the
	-- result set small enough to answer.
	local q =
		table.concat(
			tokens,
			" AND "
		)

	table.insert(plans, {
		key =
			"group:basic:"
			.. q,
		q = q,
	})

	return plans
end

local function configured_nexus_repositories(
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
		if Nexus.is_repository(repository) then
			table.insert(
				result,
				repository
			)
		end
	end

	return result
end

local function nexus_repository_name(
	repository
)
	if type(repository.name) == "string"
		and repository.name ~= ""
	then
		return repository.name
	end

	if type(repository.repository)
		== "string"
		and repository.repository ~= ""
	then
		return repository.repository
	end

	return "Nexus"
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
		source_name,
		group_scores
	)
		remember_groups(
			source,
			groups
		)

		if cancelled then
			return
		end

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
						data_key,
						group_scores
							and group_scores[group]
							or 0
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

	-- Previously discovered session groups
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

	local nexus_prefix =
		trim(ctx.value)

	for _, repository in ipairs(
		configured_nexus_repositories(
			source
		)
	) do
		Nexus.groups(
			source,
			repository,
			nexus_prefix,
			function(groups, err)
				if err then
					Common.notify_once(
						source,
						table.concat({
							"nexus-group",
							repository.url,
							repository.repository,
							nexus_prefix,
						}, ":"),
						(
							opts.error_prefix
							or "Dependency completion"
						)
							.. ": Nexus group search failed: "
							.. err
					)

					return
				end

				emit(
					groups,
					nexus_repository_name(
						repository
					)
				)
			end
		)
	end

	local central_plans =
		M.plan_central_queries(
			ctx.value
		)

	local qualified_central =
		M.is_reverse_domain_qualified(
			lower(trim(ctx.value))
		)

	local function emit_central_docs(docs)
		local groups, scores =
			rank_groups_from_docs(
				docs,
				ctx.value
			)

		emit(
			groups,
			"Maven Central",
			scores
		)
	end

	local function start_central()
		-- Blink cancels the previous request on every keystroke. Deferring
		-- the network work means intermediate prefixes never reach Central
		-- at all, instead of firing a request per keystroke and paying for
		-- three pages of each one.
		if cancelled then
			return
		end

		if qualified_central then
			local function search_qualified_page(
				plan,
				page_index
			)
				local start =
					page_index
					* Common.GROUP_ROWS

				local args = {
					q = plan.q,
					rows = tostring(
						Common.GROUP_ROWS
					),
					wt = "json",
				}

				local key = plan.key

				if start > 0 then
					args.start =
						tostring(start)

					key =
						plan.key
						.. ":start:"
						.. tostring(start)
				end

				Central.search(
					source,
					key,
					args,
					function(docs, err)
						if err then
							-- A silent failure here hid a
							-- broken Central endpoint for a
							-- long time. Always leave a
							-- trace, even without a handler.
							debug_log(
								source,
								"Central group search failed %s (page %d): %s",
								plan.q,
								page_index + 1,
								err
							)

							if opts.on_group_error then
								opts.on_group_error(
									plan.q,
									err
								)
							end

							return
						end

						local page_docs =
							type(docs)
								== "table"
							and docs
							or {}

						-- Stream each successful page to
						-- Blink immediately instead of
						-- waiting for all pages.
						--
						-- emit() still remembers groups
						-- from stale completions while
						-- suppressing stale UI results.
						emit_central_docs(
							page_docs
						)

						if cancelled then
							return
						end

						local next_page =
							page_index + 1

						local should_continue =
							#page_docs
								>= Common.GROUP_ROWS
							and next_page
								< MAX_QUALIFIED_GROUP_PAGES

						if should_continue then
							search_qualified_page(
								plan,
								next_page
							)
						end
					end
				)
			end

			for _, plan in ipairs(
				central_plans
			) do
				search_qualified_page(
					plan,
					0
				)
			end
		else
			-- Plain discovery queries such as "spring"
			-- use multiple Central searches. Keep these
			-- together so ranking can use evidence from
			-- all discovery queries.
			local pending_central =
				#central_plans

			local central_docs = {}

			local function finish_central()
				pending_central =
					pending_central - 1

				if pending_central > 0 then
					return
				end

				emit_central_docs(
					central_docs
				)
			end

			for _, plan in ipairs(
				central_plans
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
							debug_log(
								source,
								"Central group search failed %s: %s",
								plan.q,
								err
							)

							if opts.on_group_error then
								opts.on_group_error(
									plan.q,
									err
								)
							end

							finish_central()
							return
						end

						for _, doc in ipairs(
							docs or {}
						) do
							table.insert(
								central_docs,
								doc
							)
						end

						finish_central()
					end
				)
			end
		end
	end

	-- Not aliased at the top of the file so tests can replace Util.defer
	-- after this module has already been loaded.
	Util.defer(
		Common.debounce_ms(source),
		start_central
	)

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

return M
