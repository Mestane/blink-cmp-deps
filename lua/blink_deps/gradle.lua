local Source = {}

local Util = require("blink_deps.util")
local Central = require("blink_deps.central")

local lower = Util.lower
local trim = Util.trim
local starts_with = Util.starts_with
local list_to_set = Util.list_to_set
local sorted_keys = Util.sorted_keys
local extract_groups = Util.extract_groups
local extract_artifacts = Util.extract_artifacts
local response = Util.response
local make_range = Util.make_range

Source.VERSION = "0.2.0-dev"

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local GROUP_MIN_CHARS = 2
local GROUP_ROWS = 200
local ARTIFACT_ROWS = 200
local VERSION_ROWS = 200

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

-- Groovy DSL dependency configurations supported by the parser.
local DEPENDENCY_CONFIGS = {
	api = true,
	implementation = true,
	compileOnly = true,
	compileOnlyApi = true,
	runtimeOnly = true,
	annotationProcessor = true,

	testImplementation = true,
	testCompileOnly = true,
	testRuntimeOnly = true,
	testAnnotationProcessor = true,

	developmentOnly = true,
	testAndDevelopmentOnly = true,

	testFixturesApi = true,
	testFixturesImplementation = true,
	testFixturesCompileOnly = true,
	testFixturesRuntimeOnly = true,

	classpath = true,

	-- Kept for projects that expose these configurations in Groovy DSL.
	kapt = true,
	ksp = true,
}

--------------------------------------------------------------------------------
-- SMALL HELPERS
--------------------------------------------------------------------------------

local function is_build_gradle()
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "build.gradle"
end

local function debug_log(self, fmt, ...)
	if not self.opts.debug then
		return
	end
	local message = string.format(fmt, ...)
	vim.schedule(function()
		vim.notify("[Gradle] " .. message, vim.log.levels.DEBUG)
	end)
end

local function notify_once(self, key, message, level)
	if self.notified[key] then
		return
	end
	self.notified[key] = true
	vim.schedule(function()
		vim.notify(message, level or vim.log.levels.WARN)
	end)
end

--------------------------------------------------------------------------------
-- SOURCE
--------------------------------------------------------------------------------

function Source.new(opts, config)
	if type(opts) ~= "table" then
		opts = {}
	end

	if next(opts) == nil and type(config) == "table" and type(config.opts) == "table" then
		opts = config.opts
	end

	local group_memory = list_to_set(BUILTIN_GROUP_HINTS)

	return setmetatable({
		opts = opts,
		group_memory = group_memory,
		central_cache = {},
		central_inflight = {},
		artifact_catalog = {},
		version_catalog = {},
		notified = {},
	}, {
		__index = Source,
	})
end

function Source:enabled()
	return is_build_gradle()
end

function Source:get_trigger_characters()
	return { ".", ":", "-" }
end

--------------------------------------------------------------------------------
-- GRADLE GROOVY DSL CONTEXT
--------------------------------------------------------------------------------

-- Supported forms:
--
-- implementation 'g:a:v'
-- implementation "g:a:v"
--
-- implementation('g:a:v')
-- implementation("g:a:v")
--
-- implementation platform('g:a:v')
-- implementation enforcedPlatform('g:a:v')
--
-- implementation(platform('g:a:v'))
-- implementation(enforcedPlatform('g:a:v'))
--
-- Completion is intentionally restricted to known dependency configuration
-- names so arbitrary Groovy strings do not trigger Maven Central queries.

local function find_dependency_string(before_cursor)
	local config
	local coordinate

	-- implementation(platform('g:a
	-- implementation(enforcedPlatform("g:a
	config, coordinate = before_cursor:match("([%w_%.%-]+)%s*%(%s*[%w_%.%-]+%s*%(%s*[\"']([^\"']*)$")
	if config and DEPENDENCY_CONFIGS[config] then
		return config, coordinate
	end

	-- implementation platform('g:a
	-- implementation enforcedPlatform("g:a
	config, coordinate = before_cursor:match("([%w_%.%-]+)%s+[%w_%.%-]+%s*%(%s*[\"']([^\"']*)$")
	if config and DEPENDENCY_CONFIGS[config] then
		return config, coordinate
	end

	-- implementation('g:a
	config, coordinate = before_cursor:match("([%w_%.%-]+)%s*%(%s*[\"']([^\"']*)$")
	if config and DEPENDENCY_CONFIGS[config] then
		return config, coordinate
	end

	-- implementation 'g:a
	config, coordinate = before_cursor:match("([%w_%.%-]+)%s+[\"']([^\"']*)$")
	if config and DEPENDENCY_CONFIGS[config] then
		return config, coordinate
	end

	return nil, nil
end

local function parse_coordinate(coordinate)
	coordinate = coordinate or ""

	local first_colon = coordinate:find(":", 1, true)
	if not first_colon then
		return {
			kind = "group",
			value = coordinate,
			group_id = nil,
			artifact_id = nil,
			coordinate = coordinate,
		}
	end

	local group_id = coordinate:sub(1, first_colon - 1)
	local rest = coordinate:sub(first_colon + 1)

	local second_colon = rest:find(":", 1, true)
	if not second_colon then
		return {
			kind = "artifact",
			value = rest,
			group_id = group_id,
			artifact_id = nil,
			coordinate = coordinate,
		}
	end

	local artifact_id = rest:sub(1, second_colon - 1)
	local version = rest:sub(second_colon + 1)

	return {
		kind = "version",
		value = version,
		group_id = group_id,
		artifact_id = artifact_id,
		coordinate = coordinate,
	}
end

local function current_context()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local col = cursor[2]
	local line = vim.api.nvim_get_current_line()
	local before_cursor = line:sub(1, col)

	local configuration, coordinate = find_dependency_string(before_cursor)
	if not configuration then
		return nil
	end

	local parsed = parse_coordinate(coordinate)
	parsed.configuration = configuration
	parsed.row = row
	parsed.col = col

	return parsed
end

--------------------------------------------------------------------------------
-- CENTRAL SEARCH
--------------------------------------------------------------------------------

local central_search = Central.search

--------------------------------------------------------------------------------
-- GROUP COMPLETION
--------------------------------------------------------------------------------

local function is_reverse_domain_qualified(value)
	local v = lower(value)
	for _, prefix in ipairs(REVERSE_DOMAIN_PREFIXES) do
		if starts_with(v, prefix) then
			return true
		end
	end
	return false
end

local function split_tokens(value)
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

	if is_reverse_domain_qualified(v) then
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
	for _, token in ipairs(split_tokens(v)) do
		if #token >= 2 and g:find(token, 1, true) then
			score = score + 3
		end
	end

	return math.min(score, 9)
end

local function build_group_item(context, ctx, group, source)
	return {
		label = group,
		kind = KIND.Module,
		score_offset = group_score_offset(group, ctx.value),
		labelDetails = {
			description = source or "Gradle",
		},
		textEdit = {
			range = make_range(context, ctx.value),
			newText = group,
		},
		data = {
			gradle = {
				kind = "group",
				groupId = group,
			},
		},
	}
end

local function remember_groups(self, groups)
	for _, group in ipairs(groups or {}) do
		if group and group ~= "" then
			self.group_memory[group] = true
		end
	end
end

local function plan_group_central_queries(value)
	local v = lower(trim(value))
	if #v < GROUP_MIN_CHARS then
		return {}
	end

	local plans = {}

	if is_reverse_domain_qualified(v) then
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

	local tokens = split_tokens(v)

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

local function complete_group(self, context, ctx, callback)
	local cancelled = false
	local sent = {}
	local called = false

	local function emit(groups, source)
		if cancelled then
			return
		end

		local items = {}
		for _, group in ipairs(groups or {}) do
			if not sent[group] and semantic_group_allowed(group, ctx.value) then
				sent[group] = true
				table.insert(items, build_group_item(context, ctx, group, source))
			end
		end

		if #items > 0 or not called then
			called = true
			callback(response(items, true))
		end
	end

	-- Synchronous cold-start results first, then append Maven Central results.
	emit(sorted_keys(self.group_memory), "Gradle")

	if #trim(ctx.value) < GROUP_MIN_CHARS then
		return function()
			cancelled = true
		end
	end

	for _, plan in ipairs(plan_group_central_queries(ctx.value)) do
		central_search(self, plan.key, {
			q = plan.q,
			rows = tostring(GROUP_ROWS),
			wt = "json",
		}, function(docs, err)
			if err then
				debug_log(self, "group query failed (%s): %s", plan.q, err)
				return
			end

			local groups = extract_groups(docs)
			remember_groups(self, groups)
			emit(groups, "Maven Central")
		end)
	end

	return function()
		cancelled = true
	end
end

--------------------------------------------------------------------------------
-- ARTIFACT COMPLETION
--------------------------------------------------------------------------------

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

local function build_artifact_item(context, ctx, group_id, entry, source)
	return {
		label = entry.artifact,
		kind = KIND.Field,
		score_offset = artifact_score_offset(entry.artifact, ctx.value),
		labelDetails = {
			description = source or group_id,
		},
		textEdit = {
			range = make_range(context, ctx.value),
			newText = entry.artifact,
		},
		data = {
			gradle = {
				kind = "artifact",
				groupId = group_id,
				artifactId = entry.artifact,
				latestVersion = entry.latestVersion or "unknown",
			},
		},
	}
end

local function artifact_target_seed(value)
	local v = lower(trim(value))
	if #v < 2 then
		return nil
	end
	return v:sub(1, math.min(4, #v))
end

local function complete_artifact(self, context, ctx, callback)
	local group_id = ctx.group_id
	if not group_id or group_id == "" then
		callback(response({}, true))
		return nil
	end

	local cancelled = false
	local sent = {}
	local called = false

	local function emit(entries, source)
		if cancelled then
			return
		end

		local items = {}
		for _, entry in ipairs(entries or {}) do
			if entry.artifact and not sent[entry.artifact] then
				sent[entry.artifact] = true
				table.insert(items, build_artifact_item(context, ctx, group_id, entry, source))
			end
		end

		if #items > 0 or not called then
			called = true
			callback(response(items, true))
		end
	end

	local cached = self.artifact_catalog[group_id]
	if cached then
		emit(cached, group_id)
	else
		emit({}, group_id)
	end

	-- Keep group terms unquoted. This is the same Maven Central query form used
	-- by the proven Maven source.
	local exact_key = "artifact:group:" .. group_id
	central_search(self, exact_key, {
		q = "g:" .. group_id,
		rows = tostring(ARTIFACT_ROWS),
		wt = "json",
	}, function(docs, err)
		if err then
			notify_once(self, "artifact:" .. group_id, "Gradle completion: artifact catalog request failed: " .. err)
			return
		end

		local entries = extract_artifacts(docs, group_id)
		self.artifact_catalog[group_id] = entries
		emit(entries, group_id)
	end)

	local seed = artifact_target_seed(ctx.value)
	if seed then
		local q = "g:" .. group_id .. " AND a:*" .. seed .. "*"
		central_search(self, "artifact:target:" .. group_id .. ":" .. seed, {
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

--------------------------------------------------------------------------------
-- VERSION COMPLETION
--------------------------------------------------------------------------------

local function complete_version(self, context, ctx, callback)
	local group_id = ctx.group_id
	local artifact_id = ctx.artifact_id

	if not group_id or group_id == "" or not artifact_id or artifact_id == "" then
		callback(response({}, true))
		return nil
	end

	local cache_key = group_id .. ":" .. artifact_id
	local cached = self.version_catalog[cache_key]

	if cached then
		local range = make_range(context, ctx.value)
		local items = {}

		for _, version in ipairs(cached) do
			table.insert(items, {
				label = version.value,
				kind = KIND.Constant,
				labelDetails = { description = cache_key },
				textEdit = { range = range, newText = version.value },
			})
		end

		callback(response(items, true))
		return nil
	end

	callback(response({}, true))

	local cancelled = false
	local q = "g:" .. group_id .. " AND a:" .. artifact_id

	central_search(self, "version:" .. cache_key, {
		q = q,
		core = "gav",
		rows = tostring(VERSION_ROWS),
		wt = "json",
	}, function(docs, err)
		if cancelled or err then
			return
		end

		local seen = {}
		local versions = {}

		for _, doc in ipairs(docs or {}) do
			local value = doc.v or doc.latestVersion
			if value and value ~= "" and not seen[value] then
				seen[value] = true
				table.insert(versions, {
					value = value,
					timestamp = tonumber(doc.timestamp) or 0,
				})
			end
		end

		table.sort(versions, function(a, b)
			if a.timestamp ~= b.timestamp then
				return a.timestamp > b.timestamp
			end
			return a.value > b.value
		end)

		self.version_catalog[cache_key] = versions

		local range = make_range(context, ctx.value)
		local items = {}

		for _, version in ipairs(versions) do
			table.insert(items, {
				label = version.value,
				kind = KIND.Constant,
				labelDetails = { description = cache_key },
				textEdit = { range = range, newText = version.value },
			})
		end

		callback(response(items, true))
	end)

	return function()
		cancelled = true
	end
end

--------------------------------------------------------------------------------
-- LAZY DOCUMENTATION
--------------------------------------------------------------------------------

function Source:resolve(item, callback)
	local resolved = vim.deepcopy(item)
	local data = resolved.data and resolved.data.gradle

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

--------------------------------------------------------------------------------
-- DIAGNOSTICS
--------------------------------------------------------------------------------

function Source.self_test()
	local known = list_to_set(BUILTIN_GROUP_HINTS)
	return {
		version = Source.VERSION,
		spring_kafka = known["org.springframework.kafka"] == true,
		apache_kafka = known["org.apache.kafka"] == true,
		google_guava = known["com.google.guava"] == true,
		central_url = Central.URL,
	}
end

function Source.debug_group_plan(value)
	local plans = plan_group_central_queries(value)
	local queries = {}

	for _, plan in ipairs(plans) do
		table.insert(queries, plan.q)
	end

	return {
		version = Source.VERSION,
		value = value,
		central = queries,
	}
end

function Source.debug_artifact_queries(group_id, value, artifact_id)
	local result = {
		version = Source.VERSION,
		group_catalog = "g:" .. (group_id or ""),
	}

	local seed = artifact_target_seed(value or "")
	if seed then
		result.target = "g:" .. group_id .. " AND a:*" .. seed .. "*"
	end

	if artifact_id and artifact_id ~= "" then
		result.version_query = "g:" .. group_id .. " AND a:" .. artifact_id
	end

	return result
end

--------------------------------------------------------------------------------
-- ENTRY
--------------------------------------------------------------------------------

function Source:get_completions(context, callback)
	if not is_build_gradle() then
		callback(response({}, false))
		return nil
	end

	local ctx = current_context()
	if not ctx then
		callback(response({}, false))
		return nil
	end

	if ctx.kind == "group" then
		return complete_group(self, context, ctx, callback)
	end

	if ctx.kind == "artifact" then
		return complete_artifact(self, context, ctx, callback)
	end

	if ctx.kind == "version" then
		return complete_version(self, context, ctx, callback)
	end

	callback(response({}, false))
	return nil
end

return Source
