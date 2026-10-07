local CargoIndex = require("blink_deps.cargo_index")
local Pipeline = require("blink_deps.pipeline")
local Semver = require("blink_deps.semver")

--------------------------------------------------------------------------------
-- CARGO HOME
--
-- What cargo already has on this machine, as a registry.
--
-- Whenever cargo resolves dependencies it keeps the index entry of every
-- crate it looked at, under
--
--   <cargo home>/registry/index/<registry>/.cache/se/rd/serde
--
-- Each file holds every version of that crate known at the time, with its
-- features and whether it was yanked: the same information crates.io serves,
-- as of the last time cargo asked. Reading it needs no network, so versions
-- and features of anything the user has built against are available at once
-- and offline.
--
-- It is not the full picture. It only knows the crates cargo has resolved
-- here, and only as they were then.
--------------------------------------------------------------------------------

local M = {}

M.DEFAULT_ROOT = "~/.cargo"

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local function config(source)
	local configured = source.opts and source.opts.cargo_home

	if type(configured) == "table" then
		return configured
	end

	return {}
end

function M.is_enabled(source)
	return config(source).enabled ~= false
end

-- The configured path, then CARGO_HOME as cargo itself honours it, then the
-- default.
function M.root(source)
	local configured = config(source).path

	if type(configured) == "string" and configured ~= "" then
		return vim.fn.expand(configured)
	end

	local from_environment = vim.env.CARGO_HOME

	if type(from_environment) == "string" and from_environment ~= "" then
		return vim.fn.expand(from_environment)
	end

	return vim.fn.expand(M.DEFAULT_ROOT)
end

--------------------------------------------------------------------------------
-- REGISTRY DIRECTORIES
--
-- cargo keeps one directory per registry, named after its host and a hash of
-- its URL. Only crates.io's are read: the sparse index, and the git index
-- older versions of cargo used. Another registry's directory holds other
-- crates under the same names and must not be mixed in.
--------------------------------------------------------------------------------

local function is_crates_io(directory)
	return directory:match("^index%.crates%.io%-") ~= nil
		or directory == "github.com-1ecc6299db9ec823"
end

local function crates_io_directories(parent)
	local handle = vim.uv.fs_scandir(parent)

	if not handle then
		return {}
	end

	local directories = {}

	while true do
		local name, kind = vim.uv.fs_scandir_next(handle)

		if not name then
			break
		end

		if kind == "directory" and is_crates_io(name) then
			table.insert(directories, parent .. "/" .. name)
		end
	end

	table.sort(directories)

	return directories
end

--------------------------------------------------------------------------------
-- CACHE FILES
--
-- A cache file is a short binary header followed by, for each version, the
-- version string and the index entry as JSON, every part ending in a zero
-- byte. The header's layout has changed between cargo releases and is not
-- needed: the JSON entries are the parts that start with a brace, whatever
-- surrounds them.
--------------------------------------------------------------------------------

function M.parse_cache(bytes)
	if type(bytes) ~= "string" then
		return {}
	end

	local entries = {}

	for part in bytes:gmatch("[^%z]+") do
		if part:sub(1, 1) == "{" then
			table.insert(entries, part)
		end
	end

	return CargoIndex.parse(table.concat(entries, "\n"))
end

local function read_file(path)
	local file = io.open(path, "rb")

	if not file then
		return nil
	end

	local bytes = file:read("*a")

	file:close()

	return bytes
end

--------------------------------------------------------------------------------
-- ENTRIES
--
-- callback(entries) with the index entries cargo has cached for a crate, as
-- { name, value, yanked, features }; empty for a crate it has never
-- resolved. Never an error: nothing here can fail in a way the user could
-- act on, and an absent cache is the normal state of a fresh machine.
--
-- Read once per crate per session. The files are small and local, so this
-- is done directly instead of through a subprocess.
--------------------------------------------------------------------------------

local function pipeline(source)
	if not source.cargo_home_pipeline then
		source.cargo_home_pipeline = Pipeline.new({
			name = "cargo-home",
		})
	end

	return source.cargo_home_pipeline
end

function M.entries(source, name, callback)
	local path = CargoIndex.path(name)

	if not path then
		callback({})
		return
	end

	local root = M.root(source)

	pipeline(source):fetch({
		key = root .. "\n" .. path,

		fetch = function(done)
			local best = {}

			-- A machine that moved from the git index to the sparse one
			-- has both. The copy that knows more versions is the fresher.
			for _, directory in ipairs(
				crates_io_directories(root .. "/registry/index")
			) do
				local entries = M.parse_cache(
					read_file(directory .. "/.cache/" .. path)
				)

				if #entries > #best then
					best = entries
				end
			end

			done(best, nil)
		end,
	}, function(entries)
		callback(entries or {})
	end)
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- package is { name }.
-- callback(versions, err) where versions is a list of
-- { value, timestamp, yanked }.
--------------------------------------------------------------------------------

function M.versions(source, package, callback)
	M.entries(source, package.name, function(entries)
		local versions = {}

		for _, entry in ipairs(entries) do
			table.insert(versions, {
				value = entry.value,
				timestamp = 0,
				yanked = entry.yanked or nil,
			})
		end

		callback(versions, nil)
	end)
end

--------------------------------------------------------------------------------
-- FEATURES
--
-- package is { name }.
-- callback(features, err) where features is a sorted list of names, those
-- of the newest release cargo knew of.
--------------------------------------------------------------------------------

function M.features(source, package, callback)
	M.entries(source, package.name, function(entries)
		local release = CargoIndex.current_release(entries)

		callback(vim.deepcopy(release and release.features or {}), nil)
	end)
end

--------------------------------------------------------------------------------
-- DOWNLOADED CRATES
--
-- cargo keeps the archive of every crate version it has downloaded, as
--
--   <cargo home>/registry/cache/<registry>/tokio-1.38.0.crate
--
-- The file names alone say which crates have actually been built against on
-- this machine. One directory listing gives all of them; nothing has to be
-- opened.
--------------------------------------------------------------------------------

-- "tokio-util-0.7.10.crate" -> "tokio-util", "0.7.10".
--
-- Both parts may contain hyphens: tokio-util is a name, 1.0.0-rc.1 and
-- 1.1.6+spec-1.1.0 are versions. The split is at the first hyphen that
-- leaves a crate name on the left and a whole version on the right.
function M.parse_crate_file(file)
	if type(file) ~= "string" then
		return nil, nil
	end

	local stem = file:match("^(.+)%.crate$")

	if not stem then
		return nil, nil
	end

	local position = 0

	while true do
		position = stem:find("-", position + 1, true)

		if not position then
			return nil, nil
		end

		local name = stem:sub(1, position - 1)
		local version = stem:sub(position + 1)

		if CargoIndex.path(name) and Semver.parse(version) then
			return name, version
		end
	end
end

local function crate_files(parent)
	local files = {}

	for _, directory in ipairs(crates_io_directories(parent)) do
		local handle = vim.uv.fs_scandir(directory)

		while handle do
			local name = vim.uv.fs_scandir_next(handle)

			if not name then
				break
			end

			table.insert(files, name)
		end
	end

	return files
end

-- One entry per crate, { name, latest_version }, sorted by name.
-- latest_version is the newest release downloaded, or the newest prerelease
-- for a crate only ever used as one.
local function downloaded_crates(files)
	local by_name = {}

	for _, file in ipairs(files) do
		local name, version = M.parse_crate_file(file)

		if name then
			local entries = by_name[name]

			if not entries then
				entries = {}
				by_name[name] = entries
			end

			table.insert(entries, { value = version })
		end
	end

	local crates = {}

	for name, entries in pairs(by_name) do
		table.insert(crates, {
			name = name,
			latest_version = CargoIndex.current_release(entries).value,
		})
	end

	table.sort(crates, function(left, right)
		return left.name < right.name
	end)

	return crates
end

-- callback(crates). Listed once per session.
function M.downloaded(source, callback)
	local root = M.root(source)

	if not source.cargo_home_crates_pipeline then
		source.cargo_home_crates_pipeline = Pipeline.new({
			name = "cargo-home-crates",
		})
	end

	source.cargo_home_crates_pipeline:fetch({
		key = root,

		fetch = function(done)
			done(downloaded_crates(crate_files(root .. "/registry/cache")), nil)
		end,
	}, function(crates)
		callback(crates or {})
	end)
end

--------------------------------------------------------------------------------
-- SEARCH
--
-- The crates used on this machine whose name contains the text.
--
-- callback(packages, err) where packages is a list of
-- { name, latest_version }, names starting with the text first.
--
-- cargo treats - and _ in a crate name as the same character, so they are
-- the same here.
--------------------------------------------------------------------------------

local function normalized(name)
	return (name:lower():gsub("_", "-"))
end

function M.search_packages(source, text, callback)
	local needle = normalized(vim.trim(text or ""))

	if needle == "" then
		callback({}, nil)
		return
	end

	M.downloaded(source, function(crates)
		local starting = {}
		local containing = {}

		for _, crate in ipairs(crates) do
			local position = normalized(crate.name):find(needle, 1, true)

			if position == 1 then
				table.insert(starting, vim.deepcopy(crate))
			elseif position then
				table.insert(containing, vim.deepcopy(crate))
			end
		end

		vim.list_extend(starting, containing)

		callback(starting, nil)
	end)
end

--------------------------------------------------------------------------------
-- REGISTRY
--
-- The cargo home as seen through the contract in blink_deps.registries.
--------------------------------------------------------------------------------

M.REGISTRY = {
	id = "cargo-home",
	name = "Cargo cache",
	kind = "cargo-home",

	-- Answers from disk. What it knows is only what cargo has resolved on
	-- this machine, never the full picture.
	offline = true,

	capabilities = {
		versions = true,
		features = true,
		search = true,
	},

	search = function(_, source, text, callback)
		M.search_packages(source, text, callback)
	end,

	versions = function(_, source, package, callback)
		M.versions(source, package, callback)
	end,

	features = function(_, source, package, callback)
		M.features(source, package, callback)
	end,
}

--------------------------------------------------------------------------------
-- DIAGNOSTICS / TESTS
--------------------------------------------------------------------------------

function M.debug_directories(source, kind)
	return crates_io_directories(
		M.root(source) .. "/registry/" .. (kind or "index")
	)
end

return M
