local Source = {}

local Manifests = require("blink_deps.manifests")
local Util = require("blink_deps.util")
local VERSION = require("blink_deps.version")

local response = Util.response

Source.VERSION = VERSION

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
		if type(name) ~= "string" or not Manifests.get(name) then
			error(string.format(
				"blink-cmp-deps: unknown enabled source %q (expected one of: %s)",
				tostring(name),
				table.concat(Manifests.ids(), ", ")
			))
		end

		enabled[name] = true
	end

	return enabled
end

-- Which delegates complete a file is decided by the manifest registry.
local function delegate_ids_for_path(path, enabled_sources)
	local ids = {}

	for _, delegate in ipairs(
		Manifests.delegates_for_path(path, enabled_sources)
	) do
		table.insert(ids, delegate.id)
	end

	return ids
end

local function current_delegate_ids(source)
	return delegate_ids_for_path(
		vim.api.nvim_buf_get_name(0),
		source.enabled_sources
	)
end

local function resolve_delegate_id(item)
	return Manifests.delegate_for_item(item)
end

local function delegate_opts(source)
	local opts = vim.deepcopy(source.opts)
	opts.enabled_sources = nil
	return opts
end

-- Maven and Gradle files declare the same packages, so their delegates
-- share one coordinate state: a group, an artifact list or a version list
-- fetched while editing one build file is already there when another is
-- opened.
--
-- That state is Maven's. A delegate of another ecosystem keeps its own, and
-- gets nothing here.
--
-- Created on first use: loading the coordinate modules is not free, and a
-- session that never opens a Maven or Gradle file never needs them.
local function shared_state(source, id)
	if Manifests.delegate_ecosystem(id) ~= "maven" then
		return nil
	end

	if not source.shared_state then
		source.shared_state =
			require("blink_deps.coordinates").new_state()
	end

	return source.shared_state
end

local function get_delegate(source, id)
	local existing = source.delegates[id]

	if existing then
		return existing
	end

	local descriptor = Manifests.delegate(id)

	if not descriptor then
		return nil
	end

	local module = require(descriptor.module)

	local delegate = module.new(
		delegate_opts(source),
		nil,
		shared_state(source, id)
	)

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

-- Diagnostics: one entry per pipeline, shared by every delegate.
function Source:pipeline_stats()
	local state = self.shared_state
	local stats = {}

	if not state then
		return stats
	end

	for _, field in ipairs({
		"central_pipeline",
		"repository_pipeline",
		"nexus_artifact_pipeline",
		"nexus_group_pipeline",
		"local_repository_pipeline",
	}) do
		table.insert(stats, state[field]:stats())
	end

	return stats
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
