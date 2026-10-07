local Pipeline = require("blink_deps.pipeline")
local Semver = require("blink_deps.semver")
local Worker = require("blink_deps.worker")

--------------------------------------------------------------------------------
-- NPM PROJECT
--
-- The packages the project around a package.json already has, as a
-- registry.
--
-- npm records every installed package in one file:
--
--   node_modules/.package-lock.json   what is installed right now
--   package-lock.json                 what the project resolves to
--   npm-shrinkwrap.json               the same, published with a package
--
-- so the whole dependency tree, direct and transitive, is one file read
-- away; no directory has to be walked. Measured on a project with four
-- dependencies: 73 installed packages, in 32 KB.
--
-- Reading it needs no network, and matching names against it is done here,
-- so a package the project uses is found from the beginning of its name,
-- which the npm registry's own search cannot do.
--
-- It is not the full picture. It knows the packages this project has, at
-- the versions it has them.
--
-- pnpm and yarn keep the same information in formats of their own; those
-- are not read yet.
--------------------------------------------------------------------------------

local M = {}

-- Tried in each directory, in this order. What is installed is preferred
-- over what is declared: it is what the editor's other tools see.
M.LOCKFILES = {
	"node_modules/.package-lock.json",
	"package-lock.json",
	"npm-shrinkwrap.json",
}

-- A monorepo keeps its lockfile at the root, above the package being
-- edited. How far up to look before giving up.
M.MAX_DEPTH = 8

-- A lockfile at least this large is read on a worker thread. A large
-- monorepo's runs to tens of megabytes; an ordinary project's is read
-- faster than it could be handed to another thread.
M.ASYNC_BYTES = 256 * 1024

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

function M.is_enabled(source)
	local configured = source.opts and source.opts.npm_project

	return type(configured) ~= "table" or configured.enabled ~= false
end

--------------------------------------------------------------------------------
-- LOCATING THE LOCKFILE
--
-- From the directory of the manifest upwards, the first directory that has
-- one. Returns its path, a stamp that changes whenever the file does, so an
-- install is noticed without watching anything, and its size.
--------------------------------------------------------------------------------

function M.locate(manifest_path)
	if type(manifest_path) ~= "string" or manifest_path == "" then
		return nil, nil, nil
	end

	local directory = vim.fs.dirname(manifest_path)

	for _ = 1, M.MAX_DEPTH do
		for _, lockfile in ipairs(M.LOCKFILES) do
			local path = directory .. "/" .. lockfile
			local stat = vim.uv.fs_stat(path)

			if stat and stat.type == "file" then
				return path,
					string.format(
						"%d.%d:%d",
						stat.mtime.sec,
						stat.mtime.nsec,
						stat.size
					),
					stat.size
			end
		end

		local parent = vim.fs.dirname(directory)

		if not parent or parent == directory then
			break
		end

		directory = parent
	end

	return nil, nil, nil
end

--------------------------------------------------------------------------------
-- READING A LOCKFILE
--
-- Reduces a lockfile to one line per installed copy of a package:
--
--   <1 if at the top of node_modules, else 0> TAB <name> TAB <version>
--
-- Runs on a worker thread, so it is self-contained: it takes the path,
-- reads the file itself, and returns text. A result starting with ! is a
-- failure.
--
-- Two layouts exist. Since npm 7 a "packages" object is keyed by location:
--
--   "node_modules/react":                        the copy everything shares
--   "node_modules/a/node_modules/react":         a copy private to a
--
-- Before that, a "dependencies" object nested each package's own copies
-- inside it.
--------------------------------------------------------------------------------

local function reduce_lockfile(path)
	local file = io.open(path, "rb")

	if not file then
		return "!unreadable"
	end

	local text = file:read("*a")

	file:close()

	local ok, document = pcall(vim.json.decode, text)

	if not ok or type(document) ~= "table" then
		return "!invalid JSON"
	end

	local lines = {}

	local function add(top, name, version)
		if type(name) == "string"
			and name ~= ""
			and type(version) == "string"
			and version ~= ""
			and not name:find("[\t\n]")
			and not version:find("[\t\n]")
		then
			lines[#lines + 1] = (top and "1" or "0") .. "\t" .. name .. "\t" .. version
		end
	end

	if type(document.packages) == "table" then
		for location, entry in pairs(document.packages) do
			if type(location) == "string" and type(entry) == "table" then
				-- The name is what follows the last node_modules/. A
				-- workspace package listed by its own path has none and
				-- is not something to depend on by lookup.
				local name = location:match(".*node_modules/(.+)$")

				if name then
					add(location == "node_modules/" .. name, name, entry.version)
				end
			end
		end
	elseif type(document.dependencies) == "table" then
		local function walk(dependencies, top)
			for name, entry in pairs(dependencies) do
				if type(entry) == "table" then
					add(top, name, entry.version)

					if type(entry.dependencies) == "table" then
						walk(entry.dependencies, false)
					end
				end
			end
		end

		walk(document.dependencies, true)
	else
		return "!not a lockfile"
	end

	table.sort(lines)

	return table.concat(lines, "\n")
end

-- The packages of a reduced lockfile: one entry per name, sorted by name,
--
--   { name, version, versions }
--
-- where version is the copy at the top of node_modules, the one the
-- project's own code gets, and versions lists every copy in the tree.
function M.parse(reduced)
	if type(reduced) ~= "string" then
		return nil, "unreadable"
	end

	if reduced:sub(1, 1) == "!" then
		return nil, reduced:sub(2)
	end

	local by_name = {}
	local packages = {}

	for line in reduced:gmatch("[^\n]+") do
		local top, name, version = line:match("^([01])\t([^\t]+)\t([^\t]+)$")

		if name then
			local package = by_name[name]

			if not package then
				package = {
					name = name,
					versions = {},
					known = {},
				}

				by_name[name] = package

				table.insert(packages, package)
			end

			if not package.known[version] then
				package.known[version] = true

				table.insert(package.versions, version)
			end

			if top == "1" then
				package.version = version
			end
		end
	end

	for _, package in ipairs(packages) do
		package.known = nil

		Semver.sort(package.versions)

		-- A package present only as someone's private copy has no shared
		-- one; the newest copy stands in for it.
		package.version = package.version or package.versions[1]
	end

	table.sort(packages, function(left, right)
		return left.name < right.name
	end)

	return packages, nil
end

-- For tests: reduce and parse in one go, on the calling thread.
function M.read(path)
	return M.parse(reduce_lockfile(path))
end

--------------------------------------------------------------------------------
-- PACKAGES
--
-- callback(packages) with the packages of the project around the manifest
-- the source is completing, or an empty list when there is no lockfile or
-- it cannot be read. Never an error: a project that has not been installed
-- is a normal state, and nothing here can fail in a way the user could act
-- on.
--
-- Read once per lockfile, and again when the file changes.
--------------------------------------------------------------------------------

local function pipeline(source)
	if not source.npm_project_pipeline then
		source.npm_project_pipeline = Pipeline.new({
			name = "npm-project",
		})
	end

	return source.npm_project_pipeline
end

function M.packages(source, callback)
	local path, stamp, size = M.locate(source.manifest_path)

	if not path then
		callback({})
		return
	end

	pipeline(source):fetch({
		key = path .. "\n" .. stamp,

		fetch = function(done)
			if size < M.ASYNC_BYTES then
				done(M.read(path) or {}, nil)
				return
			end

			Worker.run(reduce_lockfile, path, function(reduced)
				done(M.parse(reduced) or {}, nil)
			end)
		end,
	}, function(packages)
		callback(packages or {})
	end)
end

--------------------------------------------------------------------------------
-- SEARCH
--
-- The project's packages whose name contains the text.
--
-- callback(packages, err) where packages is a list of
-- { name, latest_version }, names starting with the text first, then names
-- whose part after the scope starts with it, then the rest. latest_version
-- is the version the project has, which is all that is known here.
--------------------------------------------------------------------------------

local function unscoped(name)
	return name:match("^@[^/]+/(.+)$") or name
end

function M.search_packages(source, text, callback)
	local needle = vim.trim(text or ""):lower()

	if needle == "" then
		callback({}, nil)
		return
	end

	M.packages(source, function(packages)
		local tiers = { {}, {}, {} }

		for _, package in ipairs(packages) do
			local name = package.name:lower()
			local position = name:find(needle, 1, true)

			if position then
				local tier = 3

				if position == 1 then
					tier = 1
				elseif unscoped(name):find(needle, 1, true) == 1 then
					tier = 2
				end

				table.insert(tiers[tier], {
					name = package.name,
					latest_version = package.version,
				})
			end
		end

		local found = {}

		for _, tier in ipairs(tiers) do
			vim.list_extend(found, tier)
		end

		callback(found, nil)
	end)
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- package is { name }.
-- callback(versions, err) with the versions of it the project has, as
-- { value, timestamp }.
--------------------------------------------------------------------------------

function M.versions(source, package, callback)
	M.packages(source, function(packages)
		local versions = {}

		for _, candidate in ipairs(packages) do
			if candidate.name == package.name then
				for _, value in ipairs(candidate.versions) do
					table.insert(versions, {
						value = value,
						timestamp = 0,
					})
				end

				break
			end
		end

		callback(versions, nil)
	end)
end

--------------------------------------------------------------------------------
-- REGISTRY
--
-- The project as seen through the contract in blink_deps.registries.
--------------------------------------------------------------------------------

M.REGISTRY = {
	id = "npm-project",
	name = "This project",
	kind = "npm-project",

	-- Answers from disk. What it knows is only what this project has
	-- installed, never the full picture.
	offline = true,

	capabilities = {
		search = true,
		versions = true,
	},

	search = function(_, source, text, callback)
		M.search_packages(source, text, callback)
	end,

	versions = function(_, source, package, callback)
		M.versions(source, package, callback)
	end,
}

return M
