local Central = require("blink_deps.central")
local Repository = require("blink_deps.repository")

--------------------------------------------------------------------------------
-- REGISTRIES
--
-- A registry is anything that can answer questions about packages: Maven
-- Central, a company Nexus, a plain Maven repository. Completion code asks
-- the registries; it does not know which ones exist or how they are reached.
--
-- Contract. A registry is a table with:
--
--   id            stable identifier, unique among a source's registries
--   name          label shown to the user
--   kind          what sort of backend it is, for diagnostics
--   capabilities  set of the operations below that it implements
--
-- and one function per capability, called as registry:operation(...):
--
--   versions(source, package, callback)
--       package   { namespace, name }
--       callback  (versions, err); versions is a list of
--                 { value, timestamp }, empty on failure
--
-- An operation must call back exactly once and must never raise for a
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

local function build(source)
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

	if Central.is_enabled(source) then
		add(Central.REGISTRY)
	end

	for _, repository in ipairs(configured_repositories(source)) do
		add(Repository.registry(repository))
	end

	return registries
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
