local Source = {}

local Util = require("blink_deps.util")
local VERSION = require("blink_deps.version")

local response = Util.response
local make_range = Util.make_range

Source.VERSION = VERSION

local KIND = {
	Field = 5,
}

--------------------------------------------------------------------------------
-- SOURCE
--------------------------------------------------------------------------------

local function is_build_gradle_kts()
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "build.gradle.kts"
end

function Source.new(opts, config)
	if type(opts) ~= "table" then
		opts = {}
	end

	if next(opts) == nil and type(config) == "table" and type(config.opts) == "table" then
		opts = config.opts
	end

	return setmetatable({
		opts = opts,
		cache = {},
	}, {
		__index = Source,
	})
end

function Source:enabled()
	return is_build_gradle_kts()
end

function Source:get_trigger_characters()
	return { "." }
end

--------------------------------------------------------------------------------
-- CATALOG DISCOVERY
--------------------------------------------------------------------------------

local function find_catalog()
	local bufname = vim.api.nvim_buf_get_name(0)

	if bufname == "" then
		return nil
	end

	local dir = vim.fs.dirname(bufname)

	while dir and dir ~= "" do
		local candidate = dir .. "/gradle/libs.versions.toml"

		if vim.fn.filereadable(candidate) == 1 then
			return candidate
		end

		local parent = vim.fs.dirname(dir)

		if not parent or parent == dir then
			break
		end

		dir = parent
	end

	return nil
end

--------------------------------------------------------------------------------
-- ALIAS PARSING
--------------------------------------------------------------------------------

local function normalize_alias(alias)
	return alias:gsub("[-_]", "."):gsub("%.+", "."):gsub("^%.", ""):gsub("%.$", "")
end

local function catalog_alias_from_key(key)
	-- Dotted TOML forms:
	--
	-- spring-kafka.module
	-- spring-kafka.group
	-- spring-kafka.name
	-- spring-kafka.version
	-- spring-kafka.version.ref

	local alias = key:match("^(.-)%.version%.ref$")
		or key:match("^(.-)%.module$")
		or key:match("^(.-)%.group$")
		or key:match("^(.-)%.name$")
		or key:match("^(.-)%.version$")

	if alias then
		return alias
	end

	-- Unknown dotted keys are structural TOML keys,
	-- not normal library aliases.
	if key:find(".", 1, true) then
		return nil
	end

	return key
end

local function extract_library_aliases(text)
	local section
	local seen = {}
	local aliases = {}

	for line in (text .. "\n"):gmatch("(.-)\n") do
		local header = line:match("^%s*%[([^%]]+)%]%s*$")

		if header then
			section = vim.trim(header)
		elseif section == "libraries" then
			local key = line:match("^%s*([%w_.%-]+)%s*=")

			if key then
				local alias = catalog_alias_from_key(key)

				if alias then
					local accessor = normalize_alias(alias)

					if accessor ~= "" and not seen[accessor] then
						seen[accessor] = true
						table.insert(aliases, accessor)
					end
				end
			end
		end
	end

	table.sort(aliases)

	return aliases
end

local function extract_version_aliases(text)
	local section
	local seen = {}
	local aliases = {}

	for line in (text .. "\n"):gmatch("(.-)\n") do
		local header = line:match("^%s*%[([^%]]+)%]%s*$")

		if header then
			section = vim.trim(header)
		elseif section == "versions" then
			local alias = line:match("^%s*([%w_.%-]+)%s*=")

			if alias then
				local accessor = normalize_alias(alias)

				if accessor ~= "" and not seen[accessor] then
					seen[accessor] = true
					table.insert(aliases, accessor)
				end
			end
		end
	end

	table.sort(aliases)

	return aliases
end

local function extract_bundle_aliases(text)
	local section
	local seen = {}
	local aliases = {}

	for line in (text .. "\n"):gmatch("(.-)\n") do
		local header = line:match("^%s*%[([^%]]+)%]%s*$")

		if header then
			section = vim.trim(header)
		elseif section == "bundles" then
			local alias = line:match("^%s*([%w_.%-]+)%s*=")

			if alias then
				local accessor = normalize_alias(alias)

				if accessor ~= "" and not seen[accessor] then
					seen[accessor] = true
					table.insert(aliases, accessor)
				end
			end
		end
	end

	table.sort(aliases)

	return aliases
end

--------------------------------------------------------------------------------
-- CACHE
--------------------------------------------------------------------------------

local function file_stamp(path)
	local stat = vim.uv.fs_stat(path)

	if not stat then
		return nil
	end

	local mtime = stat.mtime or {}

	return table.concat({
		tostring(stat.size or 0),
		tostring(mtime.sec or 0),
		tostring(mtime.nsec or 0),
	}, ":")
end

function Source:load_aliases(path)
	path = path or find_catalog()

	if not path then
		return {}, {}, {}
	end

	local stamp = file_stamp(path)
	local cached = self.cache[path]

	if cached
		and cached.stamp == stamp
		and type(cached.libraries) == "table"
		and type(cached.versions) == "table"
		and type(cached.bundles) == "table"
	then
		return cached.libraries, cached.versions, cached.bundles
	end

	local ok, lines = pcall(vim.fn.readfile, path)

	if not ok then
		return {}, {}, {}
	end

	local text = table.concat(lines, "\n")

	local libraries = extract_library_aliases(text)
	local versions = extract_version_aliases(text)
	local bundles = extract_bundle_aliases(text)

	self.cache[path] = {
		stamp = stamp,
		libraries = libraries,
		versions = versions,
		bundles = bundles,
	}

	return libraries, versions, bundles
end

--------------------------------------------------------------------------------
-- BUILD.GRADLE.KTS CONTEXT
--------------------------------------------------------------------------------

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

local function trailing_accessor_token(before_cursor)
	return before_cursor:match("([%w_.]+)$")
end

local function parse_version_accessor_context(before_cursor)
	local token = trailing_accessor_token(before_cursor)

	if not token then
		return nil
	end

	local accessor = token:match("^libs%.versions%.([%w_.]*)$")

	if accessor == nil then
		return nil
	end

	local last_dot = accessor:match("^.*()%.")

	if not last_dot then
		return {
			kind = "version_accessor",
			prefix = "",
			value = accessor,
			accessor = accessor,
		}
	end

	return {
		kind = "version_accessor",
		prefix = accessor:sub(1, last_dot),
		value = accessor:sub(last_dot + 1),
		accessor = accessor,
	}
end

local function parse_bundle_accessor_context(before_cursor)
	local token = trailing_accessor_token(before_cursor)

	if not token then
		return nil
	end

	local accessor = token:match("^libs%.bundles%.([%w_.]*)$")

	if accessor == nil then
		return nil
	end

	local last_dot = accessor:match("^.*()%.")

	if not last_dot then
		return {
			kind = "bundle_accessor",
			prefix = "",
			value = accessor,
			accessor = accessor,
		}
	end

	return {
		kind = "bundle_accessor",
		prefix = accessor:sub(1, last_dot),
		value = accessor:sub(last_dot + 1),
		accessor = accessor,
	}
end


local function parse_catalog_namespace_context(before_cursor)
	local token = trailing_accessor_token(before_cursor)

	if not token then
		return nil
	end

	local value = token:match("^libs%.([%w_]*)$")

	if value == nil then
		return nil
	end

	local namespaces = {
		"bundles",
		"versions",
	}

	for _, namespace in ipairs(namespaces) do
		if namespace:sub(1, #value) == value then
			return {
				kind = "namespace",
				prefix = "",
				value = value,
			}
		end
	end

	return nil
end

local function parse_catalog_root_context(before_cursor)
	local line = before_cursor:match("([^\n]*)$") or before_cursor

	local value = line:match("^%s*val%s+[%w_]+.-=%s*([%w_]*)$")
		or line:match("^%s*var%s+[%w_]+.-=%s*([%w_]*)$")

	if value == nil then
		return nil
	end

	if ("libs"):sub(1, #value) ~= value then
		return nil
	end

	return {
		kind = "root",
		value = value,
	}
end

local function parse_accessor_context(before_cursor)
	--------------------------------------------------------------------------------
	-- DEPENDENCY CONFIGURATIONS
	--------------------------------------------------------------------------------

	local configuration, expression = before_cursor:match("([%w_%.%-]+)%s*%(%s*([%w_.]*)$")

	if configuration and DEPENDENCY_CONFIGS[configuration] then
		-- implementation(
		-- implementation(l
		-- implementation(li
		-- implementation(lib
		-- implementation(libs

		if not expression:find(".", 1, true) then
			if ("libs"):sub(1, #expression) == expression then
				return {
					kind = "root",
					value = expression,
				}
			end

			return nil
		end

		-- libs.versions.* is a version provider namespace,
		-- not dependency notation.
		--
		-- Do not offer it inside:
		--
		-- implementation(...)
		-- api(...)
		-- runtimeOnly(...)
		-- etc.
        --
        if expression:match("^libs%.bundles%.") then
	        return parse_bundle_accessor_context(expression)
        end

		if expression == "libs.versions"
			or expression:match("^libs%.versions%.")
		then
			return nil
		end

		local accessor = expression:match("^libs%.([%w_.]*)$")

		if accessor == nil then
			return nil
		end

		local last_dot = accessor:match("^.*()%.")

		if not last_dot then
			return {
				kind = "accessor",
				prefix = "",
				value = accessor,
				accessor = accessor,
			}
		end

		return {
			kind = "accessor",
			prefix = accessor:sub(1, last_dot),
			value = accessor:sub(last_dot + 1),
			accessor = accessor,
		}
	end

	--------------------------------------------------------------------------------
	-- VERSION ACCESSORS
	--------------------------------------------------------------------------------

	-- Outside dependency configurations:
	--
	-- libs.versions.spring.kafka
	--
	-- can be used as a version provider.
	local version_ctx = parse_version_accessor_context(before_cursor)

	if version_ctx then
		return version_ctx
	end

    local bundle_ctx = parse_bundle_accessor_context(before_cursor)

    if bundle_ctx then
    	return bundle_ctx
    end

	--------------------------------------------------------------------------------
	-- ARBITRARY FUNCTION ISOLATION
	--------------------------------------------------------------------------------

	-- Preserve our existing behaviour:
	--
	-- something(libs.
	--
	-- should not activate normal library accessor completion.
	if before_cursor:match("[%w_%.%-]+%s*%(%s*libs%.[%w_]*$") then
		return nil
	end

	--------------------------------------------------------------------------------
	-- ROOT ACCESSOR
	--------------------------------------------------------------------------------

	-- val testVersion =
	-- val testVersion = l
	-- val testVersion = li
	-- val testVersion = lib
	-- val testVersion = libs
	local root_ctx = parse_catalog_root_context(before_cursor)

	if root_ctx then
		return root_ctx
	end

	--------------------------------------------------------------------------------
	-- CATALOG NAMESPACE
	--------------------------------------------------------------------------------

	-- val testVersion = libs.
	-- val testVersion = libs.ver
	return parse_catalog_namespace_context(before_cursor)
end

local function current_context()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local col = cursor[2]

	local lines = vim.api.nvim_buf_get_text(
		0,
		math.max(0, row - 12),
		0,
		row - 1,
		col,
		{}
	)

	local before_cursor = table.concat(lines, "\n")
	local parsed = parse_accessor_context(before_cursor)

	if not parsed then
		return nil
	end

	parsed.row = row
	parsed.col = col

	return parsed
end

--------------------------------------------------------------------------------
-- CANDIDATES
--------------------------------------------------------------------------------

local function collect_candidates(aliases, ctx)
	local seen = {}
	local candidates = {}

	for _, alias in ipairs(aliases) do
		local matches_prefix = ctx.prefix == "" or alias:sub(1, #ctx.prefix) == ctx.prefix

		if matches_prefix then
			local remainder = alias:sub(#ctx.prefix + 1)
			local segment = remainder:match("^([^.]+)")

			if segment then
				local matches_value = ctx.value == "" or segment:sub(1, #ctx.value) == ctx.value

				if matches_value and not seen[segment] then
					seen[segment] = true
					table.insert(candidates, segment)
				end
			end
		end
	end

	table.sort(candidates)

	return candidates
end

local function collect_completion_candidates(libraries, versions, bundles, ctx)
	--------------------------------------------------------------------------------
	-- VERSION ACCESSORS
	--------------------------------------------------------------------------------

	if ctx.kind == "version_accessor" then
		return collect_candidates(versions, ctx)
	end

	--------------------------------------------------------------------------------
	-- BUNDLE ACCESSORS
	--------------------------------------------------------------------------------

	if ctx.kind == "bundle_accessor" then
		return collect_candidates(bundles, ctx)
	end

	--------------------------------------------------------------------------------
	-- GENERIC CATALOG NAMESPACE
	--------------------------------------------------------------------------------

	if ctx.kind == "namespace" then
		local candidates = {}

		if #bundles > 0
			and (
				ctx.value == ""
				or ("bundles"):sub(1, #ctx.value) == ctx.value
			)
		then
			table.insert(candidates, "bundles")
		end

		if #versions > 0
			and (
				ctx.value == ""
				or ("versions"):sub(1, #ctx.value) == ctx.value
			)
		then
			table.insert(candidates, "versions")
		end

		table.sort(candidates)

		return candidates
	end

	--------------------------------------------------------------------------------
	-- NORMAL DEPENDENCY ACCESSORS
	--------------------------------------------------------------------------------

	local candidates = collect_candidates(libraries, ctx)

	-- Bundles ARE valid dependency notation, so expose the namespace:
	--
	-- implementation(libs.)
	--                     ↓
	--                  bundles
	if ctx.kind == "accessor"
		and ctx.prefix == ""
		and #bundles > 0
		and (
			ctx.value == ""
				or ("bundles"):sub(1, #ctx.value) == ctx.value
			)
	then
		local exists = false

		for _, candidate in ipairs(candidates) do
			if candidate == "bundles" then
				exists = true
				break
			end
		end

		if not exists then
			table.insert(candidates, "bundles")
			table.sort(candidates)
		end
	end

	return candidates
end

--------------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------------

function Source:get_completions(context, callback)
	if not is_build_gradle_kts() then
		callback(response({}, false))
		return nil
	end

	local ctx = current_context()

	if not ctx then
		callback(response({}, false))
		return nil
	end

	-- Do not offer `libs` if this project does not actually
	-- contain the standard Gradle version catalog.
	local path = find_catalog()

	if not path then
		callback(response({}, false))
		return nil
	end

	if ctx.kind == "root" then
		callback(response({
			{
				label = "libs",
				kind = KIND.Field,

				labelDetails = {
					description = "Version Catalog",
				},

				textEdit = {
					range = make_range(context, ctx.value),
					newText = "libs",
				},
			},
		}, false))

		return nil
	end

	local libraries, versions, bundles = self:load_aliases(path)

	local candidates = collect_completion_candidates(
		libraries,
		versions,
        bundles,
		ctx
	)

	local range = make_range(context, ctx.value)
	local items = {}

	for _, candidate in ipairs(candidates) do
		table.insert(items, {
			label = candidate,
			kind = KIND.Field,

			labelDetails = {
				description = "Version Catalog",
			},

			textEdit = {
				range = range,
				newText = candidate,
			},
		})
	end

	callback(response(items, false))

	return nil
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS / TESTS
--------------------------------------------------------------------------------

function Source.debug_extract_aliases(text)
	return extract_library_aliases(text)
end

function Source.debug_extract_version_aliases(text)
	return extract_version_aliases(text)
end

function Source.debug_parse(text)
	return parse_accessor_context(text)
end

function Source.debug_candidates(aliases, ctx)
	return collect_candidates(aliases, ctx)
end

function Source.debug_extract_bundle_aliases(text)
	return extract_bundle_aliases(text)
end

function Source.debug_completion_candidates(libraries, versions, bundles, ctx)
	return collect_completion_candidates(libraries, versions, bundles, ctx)
end

return Source
