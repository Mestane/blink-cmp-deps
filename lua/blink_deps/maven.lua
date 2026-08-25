local Source = {}

local Util = require("blink_deps.util")
local Coordinates = require("blink_deps.coordinates")
local Jdtls = require("blink_deps.jdtls")

local trim = Util.trim
local response = Util.response
local make_range = Util.make_range

Source.VERSION = "0.2.0-dev"

local KIND = {
	Value = 12,
}

local COORDINATE_FIELDS = {
	dependency = {
		groupId = true,
		artifactId = true,
		version = true,
		scope = true,
		type = true,
		classifier = true,
		optional = true,
	},
	exclusion = {
		groupId = true,
		artifactId = true,
	},
	plugin = {
		groupId = true,
		artifactId = true,
		version = true,
		extensions = true,
		inherited = true,
	},
	reportPlugin = {
		groupId = true,
		artifactId = true,
		version = true,
		inherited = true,
	},
	parent = {
		groupId = true,
		artifactId = true,
		version = true,
	},
	extension = {
		groupId = true,
		artifactId = true,
		version = true,
	},
}

local STATIC_VALUES = {
	scope = {
		{ value = "compile", description = "Default dependency scope" },
		{ value = "provided", description = "Provided by the runtime/container" },
		{ value = "runtime", description = "Required at runtime" },
		{ value = "test", description = "Available only for tests" },
		{ value = "system", description = "Explicit local system dependency" },
		{ value = "import", description = "Import dependencyManagement from a POM" },
	},
	type = {
		{ value = "jar", description = "Java archive" },
		{ value = "test-jar", description = "Test JAR" },
		{ value = "pom", description = "Maven POM" },
		{ value = "war", description = "Web application archive" },
		{ value = "ear", description = "Enterprise application archive" },
		{ value = "ejb", description = "EJB archive" },
		{ value = "ejb-client", description = "EJB client archive" },
		{ value = "rar", description = "Resource adapter archive" },
		{ value = "maven-plugin", description = "Maven plugin" },
		{ value = "java-source", description = "Java source artifact" },
		{ value = "javadoc", description = "Javadoc artifact" },
	},
	classifier = {
		{ value = "sources", description = "Source archive" },
		{ value = "javadoc", description = "Javadoc archive" },
		{ value = "tests", description = "Test classes archive" },
		{ value = "test-sources", description = "Test sources archive" },
	},
	optional = {
		{ value = "true", description = "Do not expose dependency transitively" },
		{ value = "false", description = "Normal transitive dependency" },
	},
	packaging = {
		{ value = "jar", description = "Java archive" },
		{ value = "war", description = "Web application" },
		{ value = "pom", description = "Aggregator / parent POM" },
		{ value = "ear", description = "Enterprise application" },
		{ value = "ejb", description = "EJB module" },
		{ value = "rar", description = "Resource adapter" },
		{ value = "maven-plugin", description = "Maven plugin project" },
	},
	extensions = {
		{ value = "true", description = "Load plugin extensions" },
		{ value = "false", description = "Do not load plugin extensions" },
	},
	inherited = {
		{ value = "true", description = "Inherit configuration in child projects" },
		{ value = "false", description = "Do not inherit configuration" },
	},
	phase = {
		{ value = "validate", description = "Validate project" },
		{ value = "initialize", description = "Initialize build state" },
		{ value = "generate-sources", description = "Generate source code" },
		{ value = "process-sources", description = "Process source code" },
		{ value = "generate-resources", description = "Generate resources" },
		{ value = "process-resources", description = "Process resources" },
		{ value = "compile", description = "Compile main sources" },
		{ value = "process-classes", description = "Post-process compiled classes" },
		{ value = "generate-test-sources", description = "Generate test sources" },
		{ value = "process-test-sources", description = "Process test sources" },
		{ value = "generate-test-resources", description = "Generate test resources" },
		{ value = "process-test-resources", description = "Process test resources" },
		{ value = "test-compile", description = "Compile test sources" },
		{ value = "process-test-classes", description = "Post-process test classes" },
		{ value = "test", description = "Run unit tests" },
		{ value = "prepare-package", description = "Prepare package" },
		{ value = "package", description = "Create project package" },
		{ value = "pre-integration-test", description = "Prepare integration tests" },
		{ value = "integration-test", description = "Run integration tests" },
		{ value = "post-integration-test", description = "Clean up integration tests" },
		{ value = "verify", description = "Verify project" },
		{ value = "install", description = "Install into local repository" },
		{ value = "deploy", description = "Deploy project" },
		{ value = "pre-clean", description = "Before clean phase" },
		{ value = "clean", description = "Clean build output" },
		{ value = "post-clean", description = "After clean phase" },
		{ value = "pre-site", description = "Before site generation" },
		{ value = "site", description = "Generate project site" },
		{ value = "post-site", description = "After site generation" },
		{ value = "site-deploy", description = "Deploy project site" },
	},
	updatePolicy = {
		{ value = "always", description = "Check for updates on every build" },
		{ value = "daily", description = "Check once per day" },
		{ value = "never", description = "Never check automatically" },
	},
	checksumPolicy = {
		{ value = "fail", description = "Fail on checksum mismatch" },
		{ value = "warn", description = "Warn on checksum mismatch" },
		{ value = "ignore", description = "Ignore checksum mismatch" },
	},
	layout = {
		{ value = "default", description = "Default Maven repository layout" },
		{ value = "legacy", description = "Legacy Maven repository layout" },
	},
}

local function is_pom()
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "pom.xml"
end

local function debug_log(self, fmt, ...)
	if not self.opts.debug then
		return
	end

	local message = string.format(fmt, ...)
	vim.schedule(function()
		vim.notify("[Maven] " .. message, vim.log.levels.DEBUG)
	end)
end

function Source.new(opts, config)
	if type(opts) ~= "table" then
		opts = {}
	end

	if next(opts) == nil and type(config) == "table" and type(config.opts) == "table" then
		opts = config.opts
	end

	opts = vim.tbl_deep_extend("force", {
		jdtls = {
			enabled = false,
		},
	}, opts)

	local state = Coordinates.new_state()
	state.opts = opts
	state.jdtls_cache = {}
	state.jdtls_inflight = {}
	state.index_state = "idle"
	state.index_waiters = {}

	return setmetatable(state, {
		__index = Source,
	})
end

function Source:enabled()
	return is_pom()
end

function Source:get_trigger_characters()
	return { ".", ">" }
end

--------------------------------------------------------------------------------
-- XML CONTEXT
--------------------------------------------------------------------------------

local function current_context()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local col = cursor[2]
	local line = vim.api.nvim_get_current_line()
	local before_cursor = line:sub(1, col)
	local tag, value = before_cursor:match("<([%w_:%-]+)>([^<]*)$")

	if not tag then
		return nil
	end

	return {
		tag = tag:match("([^:]+)$") or tag,
		value = value or "",
		row = row,
		col = col,
	}
end

local function local_tag_name(name)
	return name:match("([^:]+)$") or name
end

local function find_block_end(lines, start_row, block_type)
	local depth = 0

	for row = start_row, #lines do
		for slash, raw_name, tail in lines[row]:gmatch("<(%/?)([%w_:%-]+)(.-)>") do
			local name = local_tag_name(raw_name)

			if name == block_type then
				if slash == "/" then
					depth = depth - 1
					if depth <= 0 then
						return row
					end
				elseif not tail:match("/%s*$") then
					depth = depth + 1
				end
			end
		end
	end

	return math.min(#lines, start_row + 80)
end

local function find_coordinate_block(row, col)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local stack = {}

	for current_row = 1, row do
		local text = lines[current_row] or ""
		if current_row == row then
			text = text:sub(1, col)
		end

		for slash, raw_name, tail in text:gmatch("<(%/?)([%w_:%-]+)(.-)>") do
			local name = local_tag_name(raw_name)

			if COORDINATE_FIELDS[name] then
				if slash == "/" then
					for index = #stack, 1, -1 do
						if stack[index].type == name then
							table.remove(stack, index)
							break
						end
					end
				elseif not tail:match("/%s*$") then
					table.insert(stack, {
						type = name,
						start_row = current_row,
					})
				end
			end
		end
	end

	local current = stack[#stack]
	if not current then
		return nil
	end

	return {
		type = current.type,
		start_row = current.start_row,
		end_row = find_block_end(lines, current.start_row, current.type),
		lines = lines,
	}
end

local function get_tag_value(block, tag)
	if not block then
		return nil
	end

	for row = block.start_row, block.end_row do
		local line = block.lines[row]
		if line then
			local value = line:match("<" .. tag .. ">(.-)</" .. tag .. ">")
			if value and value ~= "" then
				return trim(value)
			end
		end
	end

	return nil
end

local function supports_field(block, field)
	return block
		and COORDINATE_FIELDS[block.type]
		and COORDINATE_FIELDS[block.type][field] == true
end

local function coordinate_group_id(block)
	local group_id = get_tag_value(block, "groupId")

	if group_id and group_id ~= "" then
		return group_id
	end

	if block and (block.type == "plugin" or block.type == "reportPlugin") then
		return "org.apache.maven.plugins"
	end

	return nil
end

--------------------------------------------------------------------------------
-- JDTLS OPTIONAL BACKEND
--------------------------------------------------------------------------------

local function plan_group_jdtls_query(value)
	local v = Util.lower(trim(value))

	if #v < Coordinates.GROUP_MIN_CHARS then
		return nil
	end

	if Coordinates.is_reverse_domain_qualified(v) then
		return v, ""
	end

	local tokens = Coordinates.split_tokens(v)
	if #tokens == 0 then
		return nil
	end

	return "", tokens[#tokens]
end

local function complete_group(self, context, ctx, callback)
	return Coordinates.complete_group(self, context, ctx, callback, {
		data_key = "maven",
		local_source_name = "Maven",

		extra_search = function(emit)
			local group_id, artifact_id = plan_group_jdtls_query(ctx.value)

			if group_id ~= nil then
				Jdtls.search(self, group_id, artifact_id, function(docs)
					emit(Util.extract_groups(docs), "Maven Index")
				end)
			end
		end,

		on_group_error = function(query, err)
			debug_log(self, "group query failed (%s): %s", query, err)
		end,
	})
end

local function complete_artifact(self, context, ctx, block, callback)
	local group_id = coordinate_group_id(block)

	return Coordinates.complete_artifact(self, context, ctx, group_id, callback, {
		data_key = "maven",
		error_prefix = "Maven completion",

		extra_search = function(emit)
			if not group_id or group_id == "" then
				return
			end

			Jdtls.search(self, group_id, "", function(docs)
				emit(Util.extract_artifacts(docs, group_id), "Maven Index")
			end)
		end,
	})
end

local function complete_version(self, context, ctx, block, callback)
	local group_id = coordinate_group_id(block)
	local artifact_id = get_tag_value(block, "artifactId")

	return Coordinates.complete_version(
		self,
		context,
		ctx,
		group_id,
		artifact_id,
		callback
	)
end

--------------------------------------------------------------------------------
-- STATIC COMPLETION
--------------------------------------------------------------------------------

local function complete_static(context, ctx, values, callback)
	local range = make_range(context, ctx.value)
	local items = {}

	for index, entry in ipairs(values) do
		table.insert(items, {
			label = entry.value,
			kind = KIND.Value,
			sortText = string.format("%03d", index),
			labelDetails = { description = entry.description },
			textEdit = { range = range, newText = entry.value },
		})
	end

	callback(response(items, true))
	return nil
end

function Source:resolve(item, callback)
	Coordinates.resolve(item, "maven", callback)
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS
--------------------------------------------------------------------------------

function Source.self_test()
	local base = Coordinates.self_test()

	return {
		version = Source.VERSION,
		kafka = base.spring_kafka,
		apache_kafka = base.apache_kafka,
		google_guava = base.google_guava,
		jdtls_default = false,
		central_url = base.central_url,
	}
end

function Source.debug_group_plan(value)
	local result = Coordinates.debug_group_plan(value)
	local group_id, artifact_id = plan_group_jdtls_query(value)

	result.version = Source.VERSION
	result.jdtls = group_id ~= nil and {
		groupId = group_id,
		artifactId = artifact_id,
	} or nil

	return result
end

function Source.debug_seed_groups(value)
	return Coordinates.debug_seed_groups(value)
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
	if not is_pom() then
		callback(response({}, false))
		return nil
	end

	local ctx = current_context()
	if not ctx then
		callback(response({}, false))
		return nil
	end

	if ctx.tag == "packaging" then
		return complete_static(context, ctx, STATIC_VALUES.packaging, callback)
	end
	if ctx.tag == "phase" then
		return complete_static(context, ctx, STATIC_VALUES.phase, callback)
	end
	if ctx.tag == "updatePolicy" then
		return complete_static(context, ctx, STATIC_VALUES.updatePolicy, callback)
	end
	if ctx.tag == "checksumPolicy" then
		return complete_static(context, ctx, STATIC_VALUES.checksumPolicy, callback)
	end
	if ctx.tag == "layout" then
		return complete_static(context, ctx, STATIC_VALUES.layout, callback)
	end

	local block = find_coordinate_block(ctx.row, ctx.col)
	if not block then
		callback(response({}, false))
		return nil
	end

	if ctx.tag == "groupId" and supports_field(block, "groupId") then
		return complete_group(self, context, ctx, callback)
	end
	if ctx.tag == "artifactId" and supports_field(block, "artifactId") then
		return complete_artifact(self, context, ctx, block, callback)
	end
	if ctx.tag == "version" and supports_field(block, "version") then
		return complete_version(self, context, ctx, block, callback)
	end
	if ctx.tag == "scope" and supports_field(block, "scope") then
		return complete_static(context, ctx, STATIC_VALUES.scope, callback)
	end
	if ctx.tag == "type" and supports_field(block, "type") then
		return complete_static(context, ctx, STATIC_VALUES.type, callback)
	end
	if ctx.tag == "classifier" and supports_field(block, "classifier") then
		return complete_static(context, ctx, STATIC_VALUES.classifier, callback)
	end
	if ctx.tag == "optional" and supports_field(block, "optional") then
		return complete_static(context, ctx, STATIC_VALUES.optional, callback)
	end
	if ctx.tag == "extensions" and supports_field(block, "extensions") then
		return complete_static(context, ctx, STATIC_VALUES.extensions, callback)
	end
	if ctx.tag == "inherited" and supports_field(block, "inherited") then
		return complete_static(context, ctx, STATIC_VALUES.inherited, callback)
	end

	callback(response({}, false))
	return nil
end

return Source
