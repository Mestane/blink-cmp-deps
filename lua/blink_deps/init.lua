local Source = {}

local Util = require("blink_deps.util")
local VERSION = require("blink_deps.version")

local response = Util.response

Source.VERSION = VERSION

local PUBLIC_SOURCES = {
	maven = true,
	gradle = true,
	gradle_kts = true,
	version_catalog = true,
}

local PUBLIC_SOURCE_NAMES = {
	"gradle",
	"gradle_kts",
	"maven",
	"version_catalog",
}

local DELEGATE_MODULES = {
	maven = "blink_deps.maven",
	gradle = "blink_deps.gradle",
	gradle_kts = "blink_deps.gradle_kts",
	catalog = "blink_deps.catalog",
	gradle_catalog_accessor = "blink_deps.gradle_catalog_accessor",
}

local RESOLVE_DATA_KEYS = {
	{ key = "maven", id = "maven" },
	{ key = "gradle", id = "gradle" },
	{ key = "gradle_kts", id = "gradle_kts" },
	{ key = "catalog", id = "catalog" },
}

local function normalize_opts(opts, config)
	if type(opts) ~= "table" then
		opts = {}
	end

	if next(opts) == nil
		and type(config) == "table"
		and type(config.opts) == "table"
	then
		opts = config.opts
	end

	return opts
end

local function normalize_enabled_sources(value)
	if value == nil then
		return nil
	end

	if type(value) ~= "table" or not vim.islist(value) then
		error("blink-cmp-deps: opts.enabled_sources must be a list")
	end

	local enabled = {}

	for _, name in ipairs(value) do
		if type(name) ~= "string" or not PUBLIC_SOURCES[name] then
			error(string.format(
				"blink-cmp-deps: unknown enabled source %q (expected one of: %s)",
				tostring(name),
				table.concat(PUBLIC_SOURCE_NAMES, ", ")
			))
		end

		enabled[name] = true
	end

	return enabled
end

local function source_enabled(enabled_sources, name)
	return enabled_sources == nil or enabled_sources[name] == true
end

local function basename(path)
	if type(path) ~= "string" or path == "" then
		return ""
	end

	return vim.fn.fnamemodify(path, ":t")
end

local function delegate_ids_for_path(path, enabled_sources)
	local name = basename(path)

	if name == "pom.xml" and source_enabled(enabled_sources, "maven") then
		return { "maven" }
	end

	if name == "build.gradle" and source_enabled(enabled_sources, "gradle") then
		return { "gradle" }
	end

	if name == "build.gradle.kts" and source_enabled(enabled_sources, "gradle_kts") then
		return {
			"gradle_kts",
			"gradle_catalog_accessor",
		}
	end

	if name:match("%.versions%.toml$")
		and source_enabled(enabled_sources, "version_catalog")
	then
		return { "catalog" }
	end

	return {}
end

local function current_delegate_ids(source)
	return delegate_ids_for_path(
		vim.api.nvim_buf_get_name(0),
		source.enabled_sources
	)
end

local function resolve_delegate_id(item)
	if type(item) ~= "table" or type(item.data) ~= "table" then
		return nil
	end

	for _, route in ipairs(RESOLVE_DATA_KEYS) do
		if item.data[route.key] ~= nil then
			return route.id
		end
	end

	return nil
end

local function delegate_opts(source)
	local opts = vim.deepcopy(source.opts)
	opts.enabled_sources = nil
	return opts
end

local function get_delegate(source, id)
	local existing = source.delegates[id]

	if existing then
		return existing
	end

	local module_name = DELEGATE_MODULES[id]

	if not module_name then
		return nil
	end

	local module = require(module_name)
	local delegate = module.new(delegate_opts(source))

	source.delegates[id] = delegate
	return delegate
end

function Source.new(opts, config)
	opts = normalize_opts(opts, config)

	return setmetatable({
		opts = opts,
		enabled_sources = normalize_enabled_sources(opts.enabled_sources),
		delegates = {},
	}, {
		__index = Source,
	})
end

function Source:enabled()
	return #current_delegate_ids(self) > 0
end

function Source:get_trigger_characters()
	local seen = {}
	local characters = {}

	for _, id in ipairs(current_delegate_ids(self)) do
		local delegate = get_delegate(self, id)

		if delegate and type(delegate.get_trigger_characters) == "function" then
			for _, character in ipairs(delegate:get_trigger_characters() or {}) do
				if not seen[character] then
					seen[character] = true
					table.insert(characters, character)
				end
			end
		end
	end

	return characters
end

function Source:get_completions(context, callback)
	local ids = current_delegate_ids(self)

	if #ids == 0 then
		callback(response({}, false))
		return nil
	end

	local cancellations = {}

	for _, id in ipairs(ids) do
		local delegate = get_delegate(self, id)

		if delegate and type(delegate.get_completions) == "function" then
			local cancel = delegate:get_completions(context, callback)

			if type(cancel) == "function" then
				table.insert(cancellations, cancel)
			end
		end
	end

	if #cancellations == 0 then
		return nil
	end

	return function()
		for _, cancel in ipairs(cancellations) do
			cancel()
		end
	end
end

function Source:resolve(item, callback)
	local id = resolve_delegate_id(item)

	if not id then
		callback(item)
		return
	end

	local delegate = get_delegate(self, id)

	if not delegate or type(delegate.resolve) ~= "function" then
		callback(item)
		return
	end

	return delegate:resolve(item, callback)
end

function Source.debug_delegate_ids(path, enabled_sources)
	return vim.deepcopy(delegate_ids_for_path(
		path,
		normalize_enabled_sources(enabled_sources)
	))
end

function Source.debug_resolve_delegate(item)
	return resolve_delegate_id(item)
end

return Source
