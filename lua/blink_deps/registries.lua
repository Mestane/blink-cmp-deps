local Util = require("blink_deps.util")

--------------------------------------------------------------------------------
-- REGISTRIES
--
-- A registry is anything that can answer questions about packages: Maven
-- Central, a company Nexus, a plain Maven repository, the local ~/.m2,
-- crates.io. Completion code asks the registries; it does not know which
-- ones exist or how they are reached.
--
-- Contract. A registry is a table with:
--
--   id            stable identifier, unique among a source's registries
--   name          label shown to the user
--   kind          what sort of backend it is, for diagnostics
--   capabilities  set of the operations below that it implements
--   public        true for the ecosystem's public default registry, as
--                 opposed to one the user configured. Optional.
--   offline       true if it answers from this machine's disk. Such a
--                 registry is fast and always available, but only knows what
--                 has been downloaded here, so its answer alone is never
--                 treated as complete. Optional.
--
-- and one function per capability, called as registry:operation(...):
--
--   versions(source, package, callback)
--       package   { namespace, name }; namespace is absent in ecosystems
--                 that have none
--       callback  (versions, err); versions is a list of
--                 { value, timestamp }, empty on failure. An entry may also
--                 carry yanked = true for a version its registry withdrew.
--
--   packages(source, namespace, callback)
--       namespace the group, scope or owner whose packages are wanted
--       callback  (packages, err); packages is a list of
--                 { name, latest_version }, empty on failure
--
--   search(source, text, callback)
--       text      what the user typed, lowercased and trimmed
--       callback  (packages, err); packages is a list of
--                 { namespace, name, latest_version }, empty on failure.
--                 An entry may also carry description and downloads.
--
--   namespaces(source, text, callback)
--       text      what the user typed so far
--       callback  (namespaces, err, partial); namespaces is a list of
--                 { name, score }, where score says how strongly the
--                 namespace matched and is 0 when the backend cannot tell
--
--       Unlike the others, this operation may call back several times: a
--       backend that pages reports each page as it arrives. partial is true
--       on every call but the last. Returning false from the callback asks
--       the registry to stop.
--
--   features(source, package, callback)
--       package   as for versions
--       callback  (features, err); features is a list of the optional
--                 features the package can be built with, empty on failure
--
-- Every other operation must call back exactly once, and none may raise for a
-- remote failure. Callers check capabilities before calling, so a registry
-- implements only what its backend can actually do.
--
-- More operations join this list as the completion code is moved over.
--------------------------------------------------------------------------------

local M = {}

local function configured_repositories(source)
	local repositories =
		source.opts
		and source.opts.repositories

	if type(repositories) ~= "table" then
		return {}
	end

	return repositories
end

-- Each builder loads its own backends. A session that only ever opens one
-- kind of file never loads the modules of the other ecosystems.
local function build_maven(source)
	local Central = require("blink_deps.central")
	local LocalRepository = require("blink_deps.local_repository")
	local Repository = require("blink_deps.repository")

	local registries = {}
	local seen = {}

	local function add(registry)
		-- The same repository configured twice would be queried twice and
		-- would hold every aggregate open for two answers.
		if registry and not seen[registry.id] then
			seen[registry.id] = true
			table.insert(registries, registry)
		end
	end

	-- First, because it needs no network.
	if LocalRepository.is_enabled(source) then
		add(LocalRepository.REGISTRY)
	end

	if Central.is_enabled(source) then
		add(Central.REGISTRY)
	end

	for _, repository in ipairs(configured_repositories(source)) do
		add(Repository.registry(repository))
	end

	return registries
end

local function build_cargo(source)
	local CargoHome = require("blink_deps.cargo_home")
	local CratesIo = require("blink_deps.crates_io")

	local registries = {}

	-- First, because it needs no network.
	if CargoHome.is_enabled(source) then
		table.insert(registries, CargoHome.REGISTRY)
	end

	if CratesIo.is_enabled(source) then
		table.insert(registries, CratesIo.REGISTRY)
	end

	return registries
end

-- Registries belong to an ecosystem: a Maven repository has nothing to say
-- about a crate. A source declares its ecosystem; one that does not is a
-- Maven source, as every source was before there was a second ecosystem.
local function build_npm(source)
	local NpmRegistry = require("blink_deps.npm_registry")

	local registries = {}

	if NpmRegistry.is_enabled(source) then
		table.insert(registries, NpmRegistry.REGISTRY)
	end

	return registries
end

local BUILDERS = {
	maven = build_maven,
	cargo = build_cargo,
	npm = build_npm,
}

local function build(source)
	local builder = BUILDERS[source.ecosystem or "maven"]

	if not builder then
		return {}
	end

	return builder(source)
end

--------------------------------------------------------------------------------
-- LIST
--
-- Built once per source: the configuration does not change after setup, and
-- this runs on every completion request.
--------------------------------------------------------------------------------

function M.list(source)
	if not source.registry_list then
		source.registry_list = build(source)
	end

	return source.registry_list
end

--------------------------------------------------------------------------------
-- DISPATCH
--
-- Calls visit(registry) for every registry implementing the capability.
--
-- A registry that answers from disk is visited at once. The others are
-- visited after the debounce: blink issues a completion request per
-- keystroke, and a superseded prefix should never reach the network.
--
-- opts:
--   debounce_ms  delay before remote registries are visited
--   cancelled    function returning true once the request is obsolete
--
-- Returns how many registries will be visited, so the caller can tell when
-- the last answer has arrived.
--------------------------------------------------------------------------------

function M.dispatch(source, capability, opts, visit)
	local registries = M.with(source, capability)
	local remote = {}

	for _, registry in ipairs(registries) do
		if registry.offline then
			visit(registry)
		else
			table.insert(remote, registry)
		end
	end

	if #remote > 0 then
		-- Looked up at call time so tests can replace Util.defer after
		-- this module has already been loaded.
		Util.defer(opts.debounce_ms, function()
			if opts.cancelled and opts.cancelled() then
				return
			end

			for _, registry in ipairs(remote) do
				visit(registry)
			end
		end)
	end

	return #registries
end

-- The registries of a source that implement the given operation, in
-- configuration order. Cached for the same reason as the list.
function M.with(source, capability)
	source.registry_index = source.registry_index or {}

	local cached = source.registry_index[capability]

	if cached then
		return cached
	end

	local result = {}

	for _, registry in ipairs(M.list(source)) do
		if registry.capabilities[capability] then
			table.insert(result, registry)
		end
	end

	source.registry_index[capability] = result

	return result
end

return M
