local Source = {}

local Util = require("blink_deps.util")
local Coordinates = require("blink_deps.coordinates")
local VERSION = require("blink_deps.version")

local response = Util.response

Source.VERSION = VERSION

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
	kapt = true,
	ksp = true,
}

local MAP_FIELDS = {
	group = true,
	name = true,
	version = true,
}

local function is_build_gradle()
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "build.gradle"
end

function Source.new(opts, config)
	if type(opts) ~= "table" then
		opts = {}
	end

	if next(opts) == nil and type(config) == "table" and type(config.opts) == "table" then
		opts = config.opts
	end

	local state = Coordinates.new_state()
	state.opts = opts

	return setmetatable(state, {
		__index = Source,
	})
end

function Source:enabled()
	return is_build_gradle()
end

function Source:get_trigger_characters()
	return { ".", ":", "-", "'", '"' }
end

--------------------------------------------------------------------------------
-- GRADLE GROOVY DSL CONTEXT
--------------------------------------------------------------------------------

local function find_dependency_string(before_cursor)
	local config
	local coordinate

	config, coordinate = before_cursor:match("([%w_%.%-]+)%s*%(%s*[%w_%.%-]+%s*%(%s*[\"']([^\"']*)$")
	if config and DEPENDENCY_CONFIGS[config] then
		return config, coordinate
	end

	config, coordinate = before_cursor:match("([%w_%.%-]+)%s+[%w_%.%-]+%s*%(%s*[\"']([^\"']*)$")
	if config and DEPENDENCY_CONFIGS[config] then
		return config, coordinate
	end

	config, coordinate = before_cursor:match("([%w_%.%-]+)%s*%(%s*[\"']([^\"']*)$")
	if config and DEPENDENCY_CONFIGS[config] then
		return config, coordinate
	end

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

--------------------------------------------------------------------------------
-- MAP NOTATION
--------------------------------------------------------------------------------

local function find_last_dependency_config(text)
	local best_start
	local best_config

	for config in pairs(DEPENDENCY_CONFIGS) do
		local patterns = {
			"%f[%w_]" .. config .. "%f[^%w_]%s*%(%s*",
			"%f[%w_]" .. config .. "%f[^%w_]%s+",
		}

		for _, pattern in ipairs(patterns) do
			local init = 1

			while true do
				local start_pos = text:find(pattern, init)
				if not start_pos then
					break
				end

				if not best_start or start_pos > best_start then
					best_start = start_pos
					best_config = config
				end

				init = start_pos + 1
			end
		end
	end

	return best_config, best_start
end

local function extract_completed_map_value(text, key)
	local value
	local pattern = "%f[%w_]" .. key .. "%f[^%w_]%s*:%s*[\"']([^\"']*)[\"']"

	for match in text:gmatch(pattern) do
		value = match
	end

	return value
end

local function parse_map_context(before_cursor)
	local field_start, _, field, value =
		before_cursor:find("([%w_]+)%s*:%s*[\"']([^\"']*)$")

	if not field_start or not MAP_FIELDS[field] then
		return nil
	end

	local prefix = before_cursor:sub(1, field_start - 1)
	local configuration, config_start = find_last_dependency_config(prefix)

	if not configuration or not config_start then
		return nil
	end

	local completed_prefix = before_cursor:sub(config_start, field_start - 1)
	local group_id = extract_completed_map_value(completed_prefix, "group")
	local artifact_id = extract_completed_map_value(completed_prefix, "name")

	if field == "group" then
		return {
			kind = "group",
			value = value,
			group_id = nil,
			artifact_id = nil,
			configuration = configuration,
			notation = "map",
			field = field,
		}
	end

	if field == "name" then
		return {
			kind = "artifact",
			value = value,
			group_id = group_id,
			artifact_id = nil,
			configuration = configuration,
			notation = "map",
			field = field,
		}
	end

	return {
		kind = "version",
		value = value,
		group_id = group_id,
		artifact_id = artifact_id,
		configuration = configuration,
		notation = "map",
		field = field,
	}
end

--------------------------------------------------------------------------------
-- CONTEXT
--------------------------------------------------------------------------------

local function parse_context_text(before_cursor)
	local map_context = parse_map_context(before_cursor)
	if map_context then
		return map_context
	end

	local configuration, coordinate = find_dependency_string(before_cursor)
	if not configuration then
		return nil
	end

	local parsed = parse_coordinate(coordinate)
	parsed.configuration = configuration
	parsed.notation = "string"

	return parsed
end

local function current_context()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local col = cursor[2]

	local start_row = math.max(0, row - 12)
	local lines = vim.api.nvim_buf_get_text(0, start_row, 0, row - 1, col, {})

	local before_cursor = table.concat(lines, "\n")
	local parsed = parse_context_text(before_cursor)

	if not parsed then
		return nil
	end

	parsed.row = row
	parsed.col = col

	return parsed
end

--------------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------------

local function complete_group(self, context, ctx, callback)
	return Coordinates.complete_group(self, context, ctx, callback, {
		data_key = "gradle",
		local_source_name = "Gradle",
	})
end

local function complete_artifact(self, context, ctx, callback)
	return Coordinates.complete_artifact(self, context, ctx, ctx.group_id, callback, {
		data_key = "gradle",
		error_prefix = "Gradle completion",
	})
end

local function complete_version(self, context, ctx, callback)
	return Coordinates.complete_version(self, context, ctx, ctx.group_id, ctx.artifact_id, callback)
end

function Source:resolve(item, callback)
	Coordinates.resolve(item, "gradle", callback)
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS
--------------------------------------------------------------------------------

function Source.debug_parse(text)
	return parse_context_text(text)
end

function Source.self_test()
	local base = Coordinates.self_test()

	return {
		version = Source.VERSION,
		spring_kafka = base.spring_kafka,
		apache_kafka = base.apache_kafka,
		google_guava = base.google_guava,
		central_url = base.central_url,
	}
end

function Source.debug_group_plan(value)
	local result = Coordinates.debug_group_plan(value)
	result.version = Source.VERSION
	return result
end

function Source.debug_artifact_queries(group_id, value, artifact_id)
	local result = Coordinates.debug_artifact_queries(group_id, value, artifact_id)
	result.version = Source.VERSION
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
