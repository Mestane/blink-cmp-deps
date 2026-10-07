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

	-- What belongs to no single ecosystem, such as what is known about
	-- vulnerabilities, is kept on the unified source; this is how a
	-- delegate reaches it.
	delegate.root = source

	source.delegates[id] = delegate
	return delegate
end

-- The sources blink has created, for diagnostics. Weak, so being listed
-- here never keeps a source alive.
local instances = setmetatable({}, { __mode = "v" })
local created = 0

-- The source made by setup(), if it was called.
local configured

function Source.new(opts, config)
	opts = normalize_opts(opts, config)

	-- Configured through setup() and given no options of its own by
	-- blink: one source serves both, so completion and diagnostics share
	-- what they learn.
	if configured and next(opts) == nil then
		return configured
	end

	local source = setmetatable({
		opts = opts,
		enabled_sources = normalize_enabled_sources(opts.enabled_sources),
		delegates = {},
	}, {
		__index = Source,
	})

	created = created + 1
	instances[created] = source

	-- What the plugin does outside completion starts here: checking the
	-- dependencies of buffers, if the user asked for that. Loaded only
	-- then, and never allowed to stop the source from being created.
	local security = opts.security

	if type(security) == "table" and security.enabled == true then
		local ok, err = pcall(function()
			require("blink_deps.audit_view").attach(source)
		end)

		if not ok then
			Util.debug_log(source, "Could not attach dependency checks: %s", tostring(err))
		end
	end

	return source
end

--------------------------------------------------------------------------------
-- SETUP
--
-- Optional. blink creates the source the first time it needs it, usually
-- when insert mode is first entered, so anything the plugin does outside
-- completion would not start until then. Calling setup creates the source
-- at once:
--
--   require("blink_deps").setup({ security = { enabled = true } })
--
-- The provider in blink's configuration then needs only its module, with
-- no opts of its own; it is given this same source.
--------------------------------------------------------------------------------

function Source.setup(opts)
	configured = nil
	configured = Source.new(opts or {})

	return configured
end

-- The most recently created source that is still alive, or nil. This is
-- how :checkhealth reaches the configuration and the caches of the source
-- blink is actually using.
function Source.latest()
	for index = created, 1, -1 do
		if instances[index] then
			return instances[index]
		end
	end

	return nil
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
	-- A version is documented the same way in every ecosystem.
	local Security = require("blink_deps.security")

	if Security.handles(item) then
		return Security.resolve(self, item, callback)
	end

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

-- Diagnostics: one entry per pipeline, shared by every Maven delegate.
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

-- Diagnostics: every pipeline this source has, each once, sorted by name.
-- Maven delegates hold the same shared pipelines; other delegates create
-- their own as they need them.
function Source:pipelines()
	local seen = {}
	local pipelines = {}

	local function collect(holder)
		for field, value in pairs(holder or {}) do
			if type(field) == "string"
				and field:match("_pipeline$")
				and type(value) == "table"
				and type(value.stats) == "function"
				and not seen[value]
			then
				seen[value] = true
				table.insert(pipelines, value)
			end
		end
	end

	collect(self)
	collect(self.shared_state)

	for _, delegate in pairs(self.delegates) do
		collect(delegate)
	end

	table.sort(pipelines, function(left, right)
		return left.name < right.name
	end)

	return pipelines
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
