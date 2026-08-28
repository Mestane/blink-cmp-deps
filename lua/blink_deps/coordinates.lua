local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Repository = require("blink_deps.repository")
local VersionRank = require("blink_deps.version_rank")

local M = {}

M.GROUP_MIN_CHARS = 2
M.GROUP_ROWS = 200
M.ARTIFACT_ROWS = 200
M.VERSION_ROWS = 200

local KIND = {
	Field = 5,
	Module = 9,
	Constant = 21,
}

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

local BUILTIN_GROUP_HINTS = {
	"org.springframework",
	"org.springframework.boot",
	"org.springframework.data",
	"org.springframework.security",
	"org.springframework.kafka",
	"org.springframework.cloud",
	"org.springframework.batch",
	"org.springframework.ws",
	"org.apache.kafka",
	"org.apache.maven.plugins",
	"org.apache.logging.log4j",
	"org.apache.commons",
	"org.junit.jupiter",
	"org.junit.platform",
	"org.junit.vintage",
	"org.mockito",
	"org.hibernate.orm",
	"org.hibernate.validator",
	"org.postgresql",
	"org.mapstruct",
	"org.projectlombok",
	"org.flywaydb",
	"org.liquibase",
	"org.slf4j",
	"com.google.guava",
	"com.google.code.gson",
	"com.google.protobuf",
	"com.google.inject",
	"com.fasterxml.jackson.core",
	"com.fasterxml.jackson.databind",
	"com.fasterxml.jackson.datatype",
	"com.fasterxml.jackson.dataformat",
	"com.mysql",
	"io.micrometer",
	"io.projectreactor",
	"io.projectreactor.netty",
	"io.grpc",
	"io.netty",
	"ch.qos.logback",
}

local lower = Util.lower
local trim = Util.trim
local starts_with = Util.starts_with
local sorted_keys = Util.sorted_keys
local extract_groups = Util.extract_groups
local extract_artifacts = Util.extract_artifacts
local response = Util.response
local make_range = Util.make_range

function M.new_state()
	return {
		group_memory = Util.list_to_set(BUILTIN_GROUP_HINTS),
		central_cache = {},
		central_inflight = {},
		repository_cache = {},
		repository_inflight = {},
		artifact_catalog = {},
		version_catalog = {},
		notified = {},
	}
end

local function notify_once(source, key, message, level)
	if source.notified[key] then
		return
	end

	source.notified[key] = true
	vim.schedule(function()
		vim.notify(message, level or vim.log.levels.WARN)
	end)
end

function M.is_reverse_domain_qualified(value)
	local v = lower(value)
	for _, prefix in ipairs(REVERSE_DOMAIN_PREFIXES) do
		if starts_with(v, prefix) then
			return true
		end
	end
	return false
end

function M.split_tokens(value)
	local tokens = {}
	for token in lower(value):gmatch("[%w]+") do
		if token ~= "" then
			table.insert(tokens, token)
		end
	end
	return tokens
end

local function qualified_parent_and_tail(value)
	local parent, tail = value:match("^(.*)%.([^%.]*)$")
	if not parent then
		return nil, value
	end
	return parent, tail or ""
end

local function semantic_group_allowed(group, value)
	local v = lower(trim(value))
	if v == "" then
		return true
	end

	if M.is_reverse_domain_qualified(v) then
		local parent, tail = qualified_parent_and_tail(v)
		if parent and parent ~= "" then
			local namespace = parent .. "."
			if not starts_with(lower(group), namespace) and not starts_with(lower(group), v) then
				return false
			end
			if tail == "" then
				return true
			end
		end
	end

	return true
end

local function group_score_offset(group, value)
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
	for _, token in ipairs(M.split_tokens(v)) do
		if #token >= 2 and g:find(token, 1, true) then
			score = score + 3
		end
	end
	return math.min(score, 9)
end

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

local function build_group_item(context, ctx, group, source_name, data_key)
	return {
		label = group,
		kind = KIND.Module,
		score_offset = group_score_offset(group, ctx.value),
		labelDetails = {
			description = source_name,
		},
		textEdit = {
			range = make_range(context, ctx.value),
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

local function build_artifact_item(context, ctx, group_id, entry, source_name, data_key)
	return {
		label = entry.artifact,
		kind = KIND.Field,
		score_offset = artifact_score_offset(entry.artifact, ctx.value),
		labelDetails = {
			description = source_name,
		},
		textEdit = {
			range = make_range(context, ctx.value),
			newText = entry.artifact,
		},
		data = {
			[data_key] = {
				kind = "artifact",
				groupId = group_id,
				artifactId = entry.artifact,
				latestVersion = entry.latestVersion or "unknown",
			},
		},
	}
end

local function remember_groups(source, groups)
	for _, group in ipairs(groups or {}) do
		if group and group ~= "" then
			source.group_memory[group] = true
		end
	end
end

function M.plan_group_central_queries(value)
	local v = lower(trim(value))
	if #v < M.GROUP_MIN_CHARS then
		return {}
	end

	local plans = {}

	if M.is_reverse_domain_qualified(v) then
		local parent, tail = qualified_parent_and_tail(v)

		if parent and parent ~= "" and #tail >= 2 then
			local seed = tail:sub(1, 2)
			local q = "g:" .. parent .. "." .. seed .. "*"
			table.insert(plans, {
				key = "group:q:" .. q,
				q = q,
			})
		elseif #v >= 6 and not v:match("%.$") then
			local q = "g:" .. v .. "*"
			table.insert(plans, {
				key = "group:q:" .. q,
				q = q,
			})
		end

		return plans
	end

	local tokens = M.split_tokens(v)
	if #tokens >= 2 then
		local first = tokens[1]
		local last = tokens[#tokens]

		if #first >= 3 and #last >= 2 then
			local q = "g:*" .. first .. "*" .. last:sub(1, 2) .. "*"
			table.insert(plans, {
				key = "group:q:" .. q,
				q = q,
			})
		end
	elseif #tokens == 1 and #tokens[1] >= 3 then
		local seed = tokens[1]:sub(1, math.min(4, #tokens[1]))
		local q_group = "g:*" .. seed .. "*"

		table.insert(plans, {
			key = "group:q:" .. q_group,
			q = q_group,
		})

		table.insert(plans, {
			key = "group:basic:" .. seed,
			q = seed,
		})
	end

	return plans
end

function M.artifact_target_seed(value)
	local v = lower(trim(value))
	if #v < 2 then
		return nil
	end
	return v:sub(1, math.min(4, #v))
end

function M.complete_group(source, context, ctx, callback, opts)
	opts = opts or {}

	local data_key = opts.data_key or "deps"
	local local_source_name = opts.local_source_name or "Dependencies"
	local cancelled = false
	local sent = {}
	local called = false

	local function emit(groups, source_name)
		if cancelled then
			return
		end

		remember_groups(source, groups)

		local items = {}
		for _, group in ipairs(groups or {}) do
			if not sent[group] and semantic_group_allowed(group, ctx.value) then
				sent[group] = true
				table.insert(
					items,
					build_group_item(
						context,
						ctx,
						group,
						source_name or local_source_name,
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

	-- Synchronous cold-start candidates arrive before async backends.
	emit(sorted_keys(source.group_memory), local_source_name)

	if #trim(ctx.value) < M.GROUP_MIN_CHARS then
		return function()
			cancelled = true
		end
	end

	if opts.extra_search then
		opts.extra_search(emit)
	end

	for _, plan in ipairs(M.plan_group_central_queries(ctx.value)) do
		Central.search(source, plan.key, {
			q = plan.q,
			rows = tostring(M.GROUP_ROWS),
			wt = "json",
		}, function(docs, err)
			if err then
				if opts.on_group_error then
					opts.on_group_error(plan.q, err)
				end
				return
			end

			emit(extract_groups(docs), "Maven Central")
		end)
	end

	return function()
		cancelled = true
	end
end

function M.complete_artifact(source, context, ctx, group_id, callback, opts)
	opts = opts or {}

	if not group_id or group_id == "" then
		callback(response({}, true))
		return nil
	end

	local data_key = opts.data_key or "deps"
	local cancelled = false
	local sent = {}
	local called = false

	local function emit(entries, source_name)
		if cancelled then
			return
		end

		local items = {}
		for _, entry in ipairs(entries or {}) do
			if entry.artifact and not sent[entry.artifact] then
				sent[entry.artifact] = true
				table.insert(
					items,
					build_artifact_item(
						context,
						ctx,
						group_id,
						entry,
						source_name or group_id,
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

	local cached = source.artifact_catalog[group_id]
	if cached then
		emit(cached, group_id)
	else
		emit({}, group_id)
	end

	if opts.extra_search then
		opts.extra_search(emit)
	end

	local exact_key = "artifact:group:" .. group_id
	Central.search(source, exact_key, {
		q = "g:" .. group_id,
		rows = tostring(M.ARTIFACT_ROWS),
		wt = "json",
	}, function(docs, err)
		if err then
			notify_once(
				source,
				"artifact:" .. group_id,
				(opts.error_prefix or "Dependency completion")
					.. ": artifact catalog request failed: "
					.. err
			)
			return
		end

		local entries = extract_artifacts(docs, group_id)
		source.artifact_catalog[group_id] = entries
		emit(entries, group_id)
	end)

	local seed = M.artifact_target_seed(ctx.value)
	if seed then
		local q = "g:" .. group_id .. " AND a:*" .. seed .. "*"
		Central.search(source, "artifact:target:" .. group_id .. ":" .. seed, {
			q = q,
			rows = "100",
			wt = "json",
		}, function(docs, err)
			if not err then
				emit(extract_artifacts(docs, group_id), group_id)
			end
		end)
	end

	return function()
		cancelled = true
	end
end

local function configured_repositories(source)
	local repositories =
		source.opts and source.opts.repositories

	if type(repositories) ~= "table" then
		return {}
	end

	local result = {}

	for _, repository in ipairs(repositories) do
		if type(repository) == "table"
			and type(repository.url) == "string"
			and repository.url ~= ""
		then
			table.insert(result, repository)
		end
	end

	return result
end

function M.complete_version(
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
		callback(response({}, true))
		return nil
	end

	local cache_key =
		group_id .. ":" .. artifact_id

	--------------------------------------------------------------------------
	-- COMPLETE DERIVED CACHE
	--
	-- version_catalog is written only after every configured backend has
	-- finished. Therefore an entry here is a complete Central + repository
	-- result and can safely be returned immediately.
	--------------------------------------------------------------------------

  local cached =
		source.version_catalog[cache_key]

	if cached then
		local range =
			make_range(context, ctx.value)

		local items = {}

		for index, version in ipairs(cached) do
			table.insert(items, {
				label = version.value,
				kind = KIND.Constant,

				sortText = string.format(
					"%06d",
					index
				),

				labelDetails = {
					description = cache_key,
				},

				textEdit = {
					range = range,
					newText = version.value,
				},
			})
		end

		callback(response(items, true))
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

	local seen = {}
	local versions = {}

	local function add_version(value, timestamp)
		if not value or value == "" then
			return
		end

		timestamp =
			tonumber(timestamp) or 0

		local existing =
			seen[value]

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

    local function sort_versions()
		VersionRank.sort(versions)
     end

	local function build_items()
		local range =
			make_range(context, ctx.value)

		local items = {}

		for index, version in ipairs(versions) do
			table.insert(items, {
				label = version.value,
				kind = KIND.Constant,

				sortText = string.format(
					"%06d",
					index
				),

				labelDetails = {
					description = cache_key,
				},

				textEdit = {
					range = range,
					newText = version.value,
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
		------------------------------------------------------------------

		if pending == 0 then
			source.version_catalog[cache_key] =
				vim.deepcopy(versions)
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

	--------------------------------------------------------------------------
	-- MAVEN CENTRAL
	--------------------------------------------------------------------------

	local q =
		"g:" .. group_id
		.. " AND a:" .. artifact_id

	Central.search(
		source,
		"version:" .. cache_key,
		{
			q = q,
			core = "gav",
			rows = tostring(M.VERSION_ROWS),
			wt = "json",
		},
		function(docs, err)
			if not err then
				for _, doc in ipairs(docs or {}) do
					add_version(
						doc.v or doc.latestVersion,
						doc.timestamp
					)
				end
			end

			backend_finished()
		end
	)

	--------------------------------------------------------------------------
	-- CUSTOM MAVEN REPOSITORIES
	--------------------------------------------------------------------------

	for _, repository in ipairs(repositories) do
		Repository.versions(
			source,
			repository,
			group_id,
			artifact_id,
			function(repository_versions, _)
				for _, value in ipairs(repository_versions or {}) do
					add_version(value, 0)
				end

				backend_finished()
			end
		)
	end

	return function()
		cancelled = true
	end
end

function M.resolve(item, data_key, callback)
	local resolved = vim.deepcopy(item)
	local data = resolved.data and resolved.data[data_key]

	if data and data.kind == "artifact" then
		resolved.documentation = {
			kind = "markdown",
			value = string.format(
				"**%s:%s**\n\nLatest: `%s`",
				data.groupId,
				data.artifactId,
				data.latestVersion or "unknown"
			),
		}
	elseif data and data.kind == "group" then
		resolved.documentation = {
			kind = "markdown",
			value = "**" .. data.groupId .. "**",
		}
	end

	callback(resolved)
end

function M.self_test()
	local known = Util.list_to_set(BUILTIN_GROUP_HINTS)
	return {
		spring_kafka = known["org.springframework.kafka"] == true,
		apache_kafka = known["org.apache.kafka"] == true,
		google_guava = known["com.google.guava"] == true,
		central_url = Central.URL,
	}
end

function M.debug_group_plan(value)
	local plans = M.plan_group_central_queries(value)
	local queries = {}

	for _, plan in ipairs(plans) do
		table.insert(queries, plan.q)
	end

	return {
		value = value,
		central = queries,
	}
end

function M.debug_seed_groups(value)
	local result = {}
	for _, group in ipairs(BUILTIN_GROUP_HINTS) do
		if semantic_group_allowed(group, value) then
			table.insert(result, group)
		end
	end
	return result
end

function M.debug_artifact_queries(group_id, value, artifact_id)
	local result = {
		group_catalog = "g:" .. (group_id or ""),
	}

	local seed = M.artifact_target_seed(value or "")
	if seed then
		result.target = "g:" .. group_id .. " AND a:*" .. seed .. "*"
	end

	if artifact_id and artifact_id ~= "" then
		result.version_query = "g:" .. group_id .. " AND a:" .. artifact_id
	end

	return result
end

return M
