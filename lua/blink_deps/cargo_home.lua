local CargoIndex = require("blink_deps.cargo_index")
local Pipeline = require("blink_deps.pipeline")

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
	},

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

function M.debug_directories(source)
	return crates_io_directories(M.root(source) .. "/registry/index")
end

return M
