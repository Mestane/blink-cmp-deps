local Source = {}

local Context = require("blink_deps.npm_context")
local NameCompletion = require("blink_deps.name_completion")
local Semver = require("blink_deps.semver")
local Util = require("blink_deps.util")
local VersionCompletion = require("blink_deps.version_completion")
local VERSION = require("blink_deps.version")

--------------------------------------------------------------------------------
-- NPM
--
-- Completion for package.json: package names and version ranges.
--
-- This file is the wiring. What the cursor means is worked out by
-- blink_deps.npm_context, packages are looked up through the registries of
-- the npm ecosystem, and names and versions are gathered by the shared
-- completion modules. What is decided here is npm's own: which versions are
-- worth offering, in what order, and what accepting a suggestion writes.
--------------------------------------------------------------------------------

local lower = Util.lower
local trim = Util.trim
local response = Util.response

Source.VERSION = VERSION

-- A single letter matches a large part of the registry and says nothing
-- about what the user is after.
Source.NAME_MIN_CHARS = 2

local function is_package_json()
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "package.json"
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
		ecosystem = "npm",

		version_catalog = {},
	}, {
		__index = Source,
	})
end

function Source:enabled()
	return is_package_json()
end

-- A quote opens a name or a range. The rest are characters of a scoped
-- name or of a range that blink would not treat as part of a word.
function Source:get_trigger_characters()
	return { '"', "@", "/", ".", "-", "^", "~" }
end

--------------------------------------------------------------------------------
-- PACKAGE NAMES
--------------------------------------------------------------------------------

-- What accepting a package writes.
--
-- A key typed on its own, "rea|", becomes the whole entry:
--
--   "react": "^19.3.0"
--
-- with the caret npm install would have written. The closing quote already
-- in the buffer ends the range, so what is inserted stops just short of it.
--
-- Anywhere else only the name is replaced: the rest is already someone's
-- decision.
local function name_text(ctx, package, key_alone)
	if ctx.form == "key" and key_alone and package.latest_version then
		return package.name .. '": "^' .. package.latest_version
	end

	return package.name
end

-- True when the key under the cursor has nothing after it: its closing
-- quote, then at most a comma.
local function is_key_alone(line, col)
	return line:sub(col + 1):match('^"%s*,?%s*$') ~= nil
end

local function complete_name(self, context, ctx, callback)
	local key_alone = is_key_alone(vim.api.nvim_get_current_line(), ctx.col)

	return NameCompletion.complete(self, context, ctx, callback, {
		typed = trim(ctx.value),
		min_chars = Source.NAME_MIN_CHARS,
		noun = "Package",

		-- npm names are lowercase; the few old ones that are not differ
		-- from their lowercase form by nothing a user would mean.
		normalize = lower,

		text = function(package)
			return name_text(ctx, package, key_alone)
		end,

		data = function(package)
			return {
				npm = {
					kind = "package",
					name = package.name,
					latest_version = package.latest_version,
					description = package.description,
					downloads = package.downloads,
				},
			}
		end,
	})
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- A package can have thousands of versions: typescript and react publish a
-- build every night. What is offered:
--
--   every release
--   a prerelease only if a dist-tag points at it, such as next, beta or rc.
--   Those are the ones a project names; the nightly builds between them
--   are not chosen by hand.
--
-- unless the user is typing a prerelease, in which case all of them are
-- candidates.
--
-- The order: what npm install would pick first, then releases from the
-- newest, then tagged prereleases, and deprecated versions last. Deprecated
-- versions are kept, labelled, because for some packages every version is.
--------------------------------------------------------------------------------

local function has_tag(version, wanted)
	for _, tag in ipairs(version.tags or {}) do
		if tag == wanted then
			return true
		end
	end

	return false
end

local function sort_versions(entries)
	Semver.sort(entries)

	local latest = {}
	local releases = {}
	local prereleases = {}
	local deprecated = {}

	for _, entry in ipairs(entries) do
		if entry.deprecated then
			table.insert(deprecated, entry)
		elseif has_tag(entry, "latest") then
			table.insert(latest, entry)
		elseif Semver.is_prerelease(entry.value) then
			table.insert(prereleases, entry)
		else
			table.insert(releases, entry)
		end
	end

	local position = 0

	for _, group in ipairs({ latest, releases, prereleases, deprecated }) do
		for _, entry in ipairs(group) do
			position = position + 1
			entries[position] = entry
		end
	end

	return entries
end

local function describe_version(version)
	if version.deprecated then
		return "deprecated"
	end

	if version.tags then
		return table.concat(version.tags, ", ")
	end

	if Semver.is_prerelease(version.value) then
		return "prerelease"
	end

	return nil
end

local function complete_version(self, context, ctx, callback)
	-- A hyphen in what was typed means a prerelease is being spelled out.
	local wants_prereleases = ctx.value:find("-", 1, true) ~= nil

	-- An empty range gets the caret npm install writes. Once the user has
	-- typed an operator or a digit, the range is theirs to shape.
	local range_is_empty = ctx.range == ""

	return VersionCompletion.complete(self, context, ctx, callback, {
		package = {
			name = ctx.package,
		},

		-- The two lists differ, so they are cached apart.
		key = ctx.package .. (wants_prereleases and "\nprereleases" or ""),
		label = ctx.package,

		catalog = self.version_catalog,
		sort = sort_versions,
		describe = describe_version,

		accept = function(version)
			return wants_prereleases
				or version.tags ~= nil
				or not Semver.is_prerelease(version.value)
		end,

		text = function(version)
			if range_is_empty then
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
	local data = resolved.data and resolved.data.npm

	if type(data) == "table" and data.kind == "package" then
		local parts = { "**" .. data.name .. "**" }

		if data.latest_version then
			parts[1] = parts[1] .. " `" .. data.latest_version .. "`"
		end

		if data.description then
			table.insert(parts, trim(data.description))
		end

		if data.downloads then
			table.insert(parts, grouped(data.downloads) .. " weekly downloads")
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

function Source.debug_context(lines, row, col)
	return Context.at(lines, row, col)
end

function Source.debug_sort_versions(entries)
	return sort_versions(entries)
end

--------------------------------------------------------------------------------
-- ENTRY
--------------------------------------------------------------------------------

function Source:get_completions(context, callback)
	if not is_package_json() then
		callback(response({}, false))

		return nil
	end

	-- Which project is being edited. A registry that reads the project
	-- from disk finds it from here.
	self.manifest_path = vim.api.nvim_buf_get_name(0)

	local cursor = vim.api.nvim_win_get_cursor(0)

	local ctx = Context.at(
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

	callback(response({}, false))

	return nil
end

return Source
