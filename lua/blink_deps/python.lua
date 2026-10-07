local Source = {}

local Manifests = require("blink_deps.manifests")
local NameCompletion = require("blink_deps.name_completion")
local Pep440 = require("blink_deps.pep440")
local Pep508 = require("blink_deps.pep508")
local PyprojectContext = require("blink_deps.pyproject_context")
local RequirementsContext = require("blink_deps.requirements_context")
local Util = require("blink_deps.util")
local VersionCompletion = require("blink_deps.version_completion")
local VERSION = require("blink_deps.version")

--------------------------------------------------------------------------------
-- PYTHON
--
-- Completion for Python requirements, in requirements files and in
-- pyproject.toml: project names and versions.
--
-- This file is the wiring. What the cursor means is worked out by
-- blink_deps.requirements_context and blink_deps.pyproject_context, projects are looked up through the
-- registries of the pypi ecosystem, and names and versions are gathered by
-- the shared completion modules. What is decided here is Python's own:
-- which versions are worth offering, in what order, and what accepting a
-- suggestion writes.
--------------------------------------------------------------------------------

local trim = Util.trim
local response = Util.response

Source.VERSION = VERSION

-- A single letter matches a large part of the index and says nothing about
-- what the user is after.
Source.NAME_MIN_CHARS = 2

local function current_file()
	local path = vim.api.nvim_buf_get_name(0)

	return vim.fn.fnamemodify(path, ":t"), path
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

		-- Decides which registries this source is given.
		ecosystem = "pypi",

		version_catalog = {},
	}, {
		__index = Source,
	})
end

-- Which files are requirements files is the manifest registry's knowledge.
local function file_kind()
	local name, path = current_file()

	if name == "pyproject.toml" then
		return "pyproject"
	end

	if Manifests.is_requirements_file(name, path) then
		return "requirements"
	end

	return nil
end

function Source:enabled()
	return file_kind() ~= nil
end

-- The characters of an operator, so that a version list opens as soon as
-- one is complete, the separators that occur inside names and versions,
-- and what opens a string or a constraint in pyproject.toml.
function Source:get_trigger_characters()
	return { "=", ">", "<", "~", "!", ".", "-", "_", '"', "'", "^" }
end

--------------------------------------------------------------------------------
-- PROJECT NAMES
--
-- In a requirement, accepting a project writes its name and nothing else.
-- A requirement without a version is valid and common; whoever wants one
-- types an operator and is offered versions next.
--
-- A Poetry table entry is different: a key cannot stand without a value.
-- On a line of its own it becomes the whole entry, with the caret
-- poetry add would have written:
--
--   requests = "^2.34.2"
--------------------------------------------------------------------------------

local function name_text(ctx, package, alone_on_line)
	if ctx.style == "poetry"
		and ctx.form == "key"
		and alone_on_line
		and package.latest_version
	then
		return package.name .. ' = "^' .. package.latest_version .. '"'
	end

	return package.name
end

local function complete_name(self, context, ctx, callback)
	local line = vim.api.nvim_get_current_line()
	local alone_on_line = line:sub(ctx.col + 1):match("^%s*$") ~= nil

	return NameCompletion.complete(self, context, ctx, callback, {
		typed = trim(ctx.value),
		min_chars = Source.NAME_MIN_CHARS,
		noun = "Project",

		-- - _ and . are one character to an index, and case does not
		-- count.
		normalize = Pep508.normalize,

		text = function(package)
			return name_text(ctx, package, alone_on_line)
		end,

		data = function(package)
			return {
				pypi = {
					kind = "project",
					name = package.name,
					latest_version = package.latest_version,
					downloads = package.downloads,
				},
			}
		end,
	})
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- Highest first, with every release above every prerelease: pip does not
-- install an alpha, a beta, a release candidate or a development release
-- unless the requirement asks for one, and the first suggestion should be
-- what it would install.
--
-- Yanked releases are left out; pip skips them too.
--------------------------------------------------------------------------------

local function sort_versions(entries)
	Pep440.sort(entries)

	local releases = {}
	local prereleases = {}

	for _, entry in ipairs(entries) do
		if Pep440.is_prerelease(entry.value) then
			table.insert(prereleases, entry)
		else
			table.insert(releases, entry)
		end
	end

	for index, entry in ipairs(releases) do
		entries[index] = entry
	end

	for index, entry in ipairs(prereleases) do
		entries[#releases + index] = entry
	end

	return entries
end

-- What is shown next to a version: that it is a prerelease, or when it was
-- published.
local function describe_version(version)
	if Pep440.is_prerelease(version.value) then
		return "prerelease"
	end

	return version.published
end

local function complete_version(self, context, ctx, callback)
	return VersionCompletion.complete(self, context, ctx, callback, {
		package = {
			name = ctx.normalized,
		},

		key = ctx.normalized,
		label = ctx.package,
		catalog = self.version_catalog,
		sort = sort_versions,
		describe = describe_version,

		accept = function(version)
			return not version.yanked
		end,

		-- An empty Poetry constraint gets the caret poetry add writes.
		-- A requirement string always has its operator already, and a
		-- constraint the user has started is theirs to shape.
		text = function(version)
			if ctx.style == "poetry" and ctx.constraint == "" then
				return "^" .. version.value
			end

			return version.value
		end,
	})
end

--------------------------------------------------------------------------------
-- RESOLVE
--------------------------------------------------------------------------------

local function grouped(number)
	local digits = tostring(math.floor(number))
	local replaced

	repeat
		digits, replaced = digits:gsub("^(%d+)(%d%d%d)", "%1,%2")
	until replaced == 0

	return digits
end

function Source:resolve(item, callback)
	local resolved = vim.deepcopy(item)
	local data = resolved.data and resolved.data.pypi

	if type(data) == "table" and data.kind == "project" then
		local parts = { "**" .. data.name .. "**" }

		if data.latest_version then
			parts[1] = parts[1] .. " `" .. data.latest_version .. "`"
		end

		if data.downloads and data.downloads > 0 then
			table.insert(parts, grouped(data.downloads) .. " downloads last month")
		end

		resolved.documentation = {
			kind = "markdown",
			value = table.concat(parts, "\n\n"),
		}
	end

	callback(resolved)
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS / TESTS
--------------------------------------------------------------------------------

function Source.debug_sort_versions(entries)
	return sort_versions(entries)
end

--------------------------------------------------------------------------------
-- ENTRY
--------------------------------------------------------------------------------

function Source:get_completions(context, callback)
	if not self:enabled() then
		callback(response({}, false))

		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(0)

	-- A requirements file and pyproject.toml hold the same requirements
	-- in different wrapping; each has its own reader.
	local reader = file_kind() == "pyproject" and PyprojectContext or RequirementsContext

	local ctx = reader.at(
		vim.api.nvim_buf_get_lines(0, 0, -1, false),
		cursor[1],
		cursor[2]
	)

	if not ctx then
		callback(response({}, false))

		return nil
	end

	if ctx.kind == "name" then
		return complete_name(self, context, ctx, callback)
	end

	if ctx.kind == "version" then
		return complete_version(self, context, ctx, callback)
	end

	-- Extras are recognised but not completed yet.
	callback(response({}, false))

	return nil
end

return Source
