--------------------------------------------------------------------------------
-- MANIFESTS
--
-- A manifest is a kind of dependency file: pom.xml, build.gradle, a version
-- catalog. This is the one place that knows which files the plugin handles,
-- which ecosystem each belongs to and which sources complete it.
--
-- The unified source asks here instead of comparing file names itself, so
-- supporting another file is a matter of adding an entry, not another branch
-- in a chain of conditionals.
--
-- An entry:
--
--   id           public name, as used in opts.enabled_sources
--   ecosystem    whose packages it declares: decides which registries and
--                which version rules apply. Several manifests can share one,
--                as every Maven and Gradle file does.
--   description  the file it handles, for diagnostics
--   match        function(name, path) returning true for a file it handles;
--                name is the file name without its directory
--   delegates    the sources that complete it, in order. Each is
--                  id        name of the delegate inside the unified source
--                  module    Lua module implementing it
--                  data_key  key under item.data that marks an item as this
--                            delegate's, so resolve can be routed back.
--                            Optional: a delegate without one never resolves.
--------------------------------------------------------------------------------

local M = {}

local entries = {}
local by_id = {}
local delegates_by_id = {}
local ecosystem_by_delegate = {}

--------------------------------------------------------------------------------
-- REGISTER
--------------------------------------------------------------------------------

local function check(condition, message)
	if not condition then
		error("blink-cmp-deps: invalid manifest: " .. message, 3)
	end
end

function M.register(entry)
	check(type(entry) == "table", "expected a table")
	check(type(entry.id) == "string" and entry.id ~= "", "id is required")
	check(not by_id[entry.id], "duplicate id " .. tostring(entry.id))

	check(
		type(entry.ecosystem) == "string" and entry.ecosystem ~= "",
		entry.id .. ": ecosystem is required"
	)

	check(
		type(entry.match) == "function",
		entry.id .. ": match must be a function"
	)

	check(
		type(entry.delegates) == "table" and #entry.delegates > 0,
		entry.id .. ": at least one delegate is required"
	)

	for _, delegate in ipairs(entry.delegates) do
		check(
			type(delegate.id) == "string" and delegate.id ~= "",
			entry.id .. ": delegate id is required"
		)

		check(
			type(delegate.module) == "string" and delegate.module ~= "",
			entry.id .. ": delegate module is required"
		)

		-- Two manifests may share a delegate, but only the same one: an id
		-- that meant two different modules would make routing ambiguous.
		local existing = delegates_by_id[delegate.id]

		check(
			not existing or existing.module == delegate.module,
			entry.id .. ": delegate " .. delegate.id .. " is already registered"
		)

		-- A delegate holds state for one ecosystem: its registries and
		-- its caches. It cannot serve two.
		check(
			not existing or ecosystem_by_delegate[delegate.id] == entry.ecosystem,
			entry.id
				.. ": delegate "
				.. delegate.id
				.. " already belongs to another ecosystem"
		)
	end

	for _, delegate in ipairs(entry.delegates) do
		delegates_by_id[delegate.id] = delegates_by_id[delegate.id] or delegate
		ecosystem_by_delegate[delegate.id] = entry.ecosystem
	end

	by_id[entry.id] = entry
	table.insert(entries, entry)

	return entry
end

--------------------------------------------------------------------------------
-- LOOKUP
--------------------------------------------------------------------------------

local function basename(path)
	if type(path) ~= "string" or path == "" then
		return ""
	end

	return path:match("([^/\\]+)$") or ""
end

-- The manifests handling a path, in registration order. enabled is a set of
-- manifest ids, or nil for all of them.
function M.for_path(path, enabled)
	local name = basename(path)

	if name == "" then
		return {}
	end

	local matched = {}

	for _, entry in ipairs(entries) do
		if (enabled == nil or enabled[entry.id] == true)
			and entry.match(name, path)
		then
			table.insert(matched, entry)
		end
	end

	return matched
end

-- The delegates that complete a path, without duplicates.
function M.delegates_for_path(path, enabled)
	local seen = {}
	local delegates = {}

	for _, entry in ipairs(M.for_path(path, enabled)) do
		for _, delegate in ipairs(entry.delegates) do
			if not seen[delegate.id] then
				seen[delegate.id] = true
				table.insert(delegates, delegate)
			end
		end
	end

	return delegates
end

function M.get(id)
	return by_id[id]
end

function M.delegate(id)
	return delegates_by_id[id]
end

-- The ecosystem a delegate works in, or nil for an unknown delegate.
function M.delegate_ecosystem(id)
	return ecosystem_by_delegate[id]
end

-- Every manifest id, sorted, for messages and diagnostics.
function M.ids()
	local ids = {}

	for _, entry in ipairs(entries) do
		table.insert(ids, entry.id)
	end

	table.sort(ids)

	return ids
end

function M.list()
	return vim.deepcopy(entries)
end

-- The id of the delegate an item belongs to, read from the item's data, or
-- nil for an item no delegate claims.
function M.delegate_for_item(item)
	if type(item) ~= "table" or type(item.data) ~= "table" then
		return nil
	end

	for _, entry in ipairs(entries) do
		for _, delegate in ipairs(entry.delegates) do
			if delegate.data_key and item.data[delegate.data_key] ~= nil then
				return delegate.id
			end
		end
	end

	return nil
end

--------------------------------------------------------------------------------
-- BUILT IN
--
-- Maven and Gradle are different build tools over the same packages, so
-- their four manifests declare the maven ecosystem. Cargo, npm and Python
-- each have their own.
--------------------------------------------------------------------------------

M.register({
	id = "maven",
	ecosystem = "maven",
	description = "pom.xml",

	match = function(name)
		return name == "pom.xml"
	end,

	delegates = {
		{
			id = "maven",
			module = "blink_deps.maven",
			data_key = "maven",
		},
	},
})

M.register({
	id = "gradle",
	ecosystem = "maven",
	description = "build.gradle",

	match = function(name)
		return name == "build.gradle"
	end,

	delegates = {
		{
			id = "gradle",
			module = "blink_deps.gradle",
			data_key = "gradle",
		},
	},
})

M.register({
	id = "gradle_kts",
	ecosystem = "maven",
	description = "build.gradle.kts",

	match = function(name)
		return name == "build.gradle.kts"
	end,

	delegates = {
		{
			id = "gradle_kts",
			module = "blink_deps.gradle_kts",
			data_key = "gradle_kts",
		},
		{
			-- libs.* accessors, read from the project's version catalog.
			id = "gradle_catalog_accessor",
			module = "blink_deps.gradle_catalog_accessor",
		},
	},
})

M.register({
	id = "version_catalog",
	ecosystem = "maven",
	description = "*.versions.toml",

	match = function(name)
		return name:match("%.versions%.toml$") ~= nil
	end,

	delegates = {
		{
			id = "catalog",
			module = "blink_deps.catalog",
			data_key = "catalog",
		},
	},
})

M.register({
	id = "cargo",
	ecosystem = "cargo",
	description = "Cargo.toml",

	-- Cargo only reads this exact name.
	match = function(name)
		return name == "Cargo.toml"
	end,

	delegates = {
		{
			id = "cargo",
			module = "blink_deps.cargo",
			data_key = "cargo",
		},
	},
})

M.register({
	id = "npm",
	ecosystem = "npm",
	description = "package.json",

	match = function(name)
		return name == "package.json"
	end,

	delegates = {
		{
			id = "npm",
			module = "blink_deps.npm",
			data_key = "npm",
		},
	},
})

-- pip has no fixed file name. These are the conventions in use:
--
--   requirements.txt   requirements-dev.txt   dev-requirements.txt
--   requirements/base.txt
--   constraints.txt
--   requirements.in    the input of pip-tools, in the same format
--
-- A .in file is only taken for requirements when its name says so:
-- MANIFEST.in is something else entirely.
function M.is_requirements_file(name, path)
	if type(name) ~= "string" then
		return false
	end

	local lowered = name:lower()

	if not lowered:match("%.txt$") and not lowered:match("%.in$") then
		return false
	end

	if lowered:find("requirements", 1, true) or lowered:match("^constraints") then
		return true
	end

	return type(path) == "string"
		and path:lower():match("[/\\]requirements[/\\][^/\\]+$") ~= nil
end

M.register({
	id = "requirements",
	ecosystem = "pypi",
	description = "requirements*.txt",
	match = M.is_requirements_file,

	delegates = {
		{
			id = "python",
			module = "blink_deps.python",
			data_key = "pypi",
		},
	},
})

return M
