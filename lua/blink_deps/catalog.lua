local Source = {}

local Util = require("blink_deps.util")
local Coordinates = require("blink_deps.coordinates")
local VERSION = require("blink_deps.version")

local response = Util.response
local make_range = Util.make_range
local lower = Util.lower
local trim = Util.trim

Source.VERSION = VERSION

local KIND = {
	Value = 12,
}

local function is_version_catalog()
	local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
	return name:match("%.versions%.toml$") ~= nil
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
	return is_version_catalog()
end

function Source:get_trigger_characters()
	return { ".", ":", "-", "_", '"', "'" }
end

--------------------------------------------------------------------------------
-- VERSION CATALOG CONTEXT
--------------------------------------------------------------------------------

local function current_section(text)
	local section

	for line in (text .. "\n"):gmatch("(.-)\n") do
		local value = line:match("^%s*%[([^%]]+)%]%s*$")
		if value then
			section = trim(value)
		end
	end

	return section
end

local function current_line(text)
	return text:match("([^\n]*)$") or text
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

local function parse_module_coordinate(coordinate)
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
	local artifact = coordinate:sub(first_colon + 1)

	-- Gradle's `module` field is `group:name`, not `group:name:version`.
	if artifact:find(":", 1, true) then
		return nil
	end

	return {
		kind = "artifact",
		value = artifact,
		group_id = group_id,
		artifact_id = nil,
		coordinate = coordinate,
	}
end

local function extract_quoted_value(text, key)
	local escaped = key:gsub("([^%w])", "%%%1")
	local value
	local pattern = "%f[%w_]" .. escaped .. "%f[^%w_]%s*=%s*[\"']([^\"']*)[\"']"

	for match in text:gmatch(pattern) do
		value = match
	end

	return value
end

local function split_module(module)
	if not module or module == "" then
		return nil, nil
	end

	local colon = module:find(":", 1, true)
	if not colon then
		return nil, nil
	end

	local group_id = module:sub(1, colon - 1)
	local artifact_id = module:sub(colon + 1)

	if group_id == "" or artifact_id == "" or artifact_id:find(":", 1, true) then
		return nil, nil
	end

	return group_id, artifact_id
end

local function parse_inline_table(line)
	if not line:find("{", 1, true) then
		return nil
	end

	local field_start, _, field, value =
		line:find("([%w_.%-]+)%s*=%s*[\"']([^\"']*)$")

	if not field_start then
		return nil
	end

	local prefix = line:sub(1, field_start - 1)

	if field == "module" then
		local parsed = parse_module_coordinate(value)
		if parsed then
			parsed.notation = "module"
			parsed.field = field
		end
		return parsed
	end

	if field == "group" then
		return {
			kind = "group",
			value = value,
			group_id = nil,
			artifact_id = nil,
			notation = "fields",
			field = field,
		}
	end

	if field == "name" then
		return {
			kind = "artifact",
			value = value,
			group_id = extract_quoted_value(prefix, "group"),
			artifact_id = nil,
			notation = "fields",
			field = field,
		}
	end

	if field == "version" then
		local group_id = extract_quoted_value(prefix, "group")
		local artifact_id = extract_quoted_value(prefix, "name")

		if not group_id or not artifact_id then
			group_id, artifact_id = split_module(extract_quoted_value(prefix, "module"))
		end

		return {
			kind = "version",
			value = value,
			group_id = group_id,
			artifact_id = artifact_id,
			notation = "fields",
			field = field,
		}
	end

	if field == "version.ref" then
		return {
			kind = "version_ref",
			value = value,
			notation = "fields",
			field = field,
		}
	end

	return nil
end

local function escape_pattern(value)
	return (value:gsub("([^%w])", "%%%1"))
end

local function extract_dotted_value(text, alias, field)
	local escaped_alias = escape_pattern(alias)
	local escaped_field = escape_pattern(field)
	local value
	local pattern =
		"^%s*"
		.. escaped_alias
		.. "%."
		.. escaped_field
		.. "%s*=%s*[\"']([^\"']*)[\"']%s*$"

	for line in (text .. "\n"):gmatch("(.-)\n") do
		local match = line:match(pattern)
		if match then
			value = match
		end
	end

	return value
end

local function parse_dotted_field(before_cursor, line)
	local alias, field, value

	alias, value =
		line:match("^%s*([%w_.%-]-)%.version%.ref%s*=%s*[\"']([^\"']*)$")
	if alias then
		return {
			kind = "version_ref",
			value = value,
			alias = alias,
			notation = "dotted",
			field = "version.ref",
		}
	end

	alias, field, value =
		line:match("^%s*([%w_.%-]-)%.([%w_]+)%s*=%s*[\"']([^\"']*)$")

	if not alias then
		return nil
	end

	if field == "module" then
		local parsed = parse_module_coordinate(value)
		if not parsed then
			return nil
		end

		parsed.alias = alias
		parsed.notation = "dotted"
		parsed.field = field
		return parsed
	end

	if field == "group" then
		return {
			kind = "group",
			value = value,
			group_id = nil,
			artifact_id = nil,
			alias = alias,
			notation = "dotted",
			field = field,
		}
	end

	if field == "name" then
		return {
			kind = "artifact",
			value = value,
			group_id = extract_dotted_value(before_cursor, alias, "group"),
			artifact_id = nil,
			alias = alias,
			notation = "dotted",
			field = field,
		}
	end

	if field == "version" then
		local group_id = extract_dotted_value(before_cursor, alias, "group")
		local artifact_id = extract_dotted_value(before_cursor, alias, "name")

		if not group_id or not artifact_id then
			group_id, artifact_id =
				split_module(extract_dotted_value(before_cursor, alias, "module"))
		end

		return {
			kind = "version",
			value = value,
			group_id = group_id,
			artifact_id = artifact_id,
			alias = alias,
			notation = "dotted",
			field = field,
		}
	end

	return nil
end

local function parse_shorthand(line)
	local alias, coordinate =
		line:match("^%s*([%w_.%-]+)%s*=%s*[\"']([^\"']*)$")

	if not alias then
		return nil
	end

	local parsed = parse_coordinate(coordinate)
	parsed.alias = alias
	parsed.notation = "shorthand"
	return parsed
end

local function has_dotted_key(line)
	local key = line:match("^%s*([%w_.%-]+)%s*=")
	return key ~= nil and key:find(".", 1, true) ~= nil
end

local function parse_context_text(before_cursor)
	if current_section(before_cursor) ~= "libraries" then
		return nil
	end

	local line = current_line(before_cursor)
	local parsed = parse_inline_table(line)

	if not parsed then
		if has_dotted_key(line) then
			-- A bare TOML dotted key is structural syntax, not a shorthand alias.
			-- Known fields (`module`, `group`, `name`, `version`, `version.ref`)
			-- are parsed here; unknown dotted fields intentionally produce no
			-- dependency completion instead of falling back to `group:artifact:version`.
			parsed = parse_dotted_field(before_cursor, line)
		else
			parsed = parse_shorthand(line)
		end
	end

	if parsed then
		parsed.section = "libraries"
	end

	return parsed
end

local function extract_version_aliases(text)
	local section
	local seen = {}
	local aliases = {}

	for line in (text .. "\n"):gmatch("(.-)\n") do
		local header = line:match("^%s*%[([^%]]+)%]%s*$")
		if header then
			section = trim(header)
		elseif section == "versions" then
			local alias = line:match("^%s*([%w_.%-]+)%s*=")
			if alias and not seen[alias] then
				seen[alias] = true
				table.insert(aliases, alias)
			end
		end
	end

	table.sort(aliases)
	return aliases
end

local function current_context()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local col = cursor[2]

	local before_lines = vim.api.nvim_buf_get_text(0, 0, 0, row - 1, col, {})
	local before_cursor = table.concat(before_lines, "\n")
	local parsed = parse_context_text(before_cursor)

	if not parsed then
		return nil
	end

	parsed.row = row
	parsed.col = col
	parsed.full_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")

	return parsed
end

--------------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------------

local function group_insert_text(ctx, value)
	if ctx.field == "module" and value and value ~= "" and value:sub(-1) ~= ":" then
		return value .. ":"
	end

	return value
end

local function complete_group(self, context, ctx, callback)
	local function on_response(result)
		if ctx.field == "module" and result and type(result.items) == "table" then
			for _, item in ipairs(result.items) do
				if item.textEdit and item.textEdit.newText then
					item.textEdit.newText = group_insert_text(ctx, item.textEdit.newText)
				end
			end
		end

		callback(result)
	end

	return Coordinates.complete_group(self, context, ctx, on_response, {
		data_key = "catalog",
		local_source_name = "Version Catalog",
	})
end

local function complete_artifact(self, context, ctx, callback)
	return Coordinates.complete_artifact(self, context, ctx, ctx.group_id, callback, {
		data_key = "catalog",
		error_prefix = "Version Catalog completion",
	})
end

local function complete_version(self, context, ctx, callback)
	return Coordinates.complete_version(
		self,
		context,
		ctx,
		ctx.group_id,
		ctx.artifact_id,
		callback
	)
end

local function complete_version_ref(context, ctx, callback)
	local aliases = extract_version_aliases(ctx.full_text or "")
	local needle = lower(trim(ctx.value))
	local range = make_range(context, ctx.value)
	local items = {}

	for _, alias in ipairs(aliases) do
		local candidate = lower(alias)
		if needle == "" or candidate:find(needle, 1, true) then
			table.insert(items, {
				label = alias,
				kind = KIND.Value,
				score_offset = candidate:sub(1, #needle) == needle and 10 or 0,
				labelDetails = {
					description = "[versions]",
				},
				textEdit = {
					range = range,
					newText = alias,
				},
			})
		end
	end

	callback(response(items, false))
	return nil
end

function Source:resolve(item, callback)
	Coordinates.resolve(item, "catalog", callback)
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS
--------------------------------------------------------------------------------

function Source.debug_parse(text)
	return parse_context_text(text)
end

function Source.debug_version_aliases(text)
	return extract_version_aliases(text)
end

function Source.debug_group_insert_text(field, value)
	return group_insert_text({ field = field }, value)
end

function Source.self_test()
	local base = Coordinates.self_test()

	return {
		version = Source.VERSION,
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
	if not is_version_catalog() then
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

	if ctx.kind == "version_ref" then
		return complete_version_ref(context, ctx, callback)
	end

	callback(response({}, false))
	return nil
end

return Source
