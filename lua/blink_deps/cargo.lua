local Source = {}

local Context = require("blink_deps.cargo_context")
local Registries = require("blink_deps.registries")
local Semver = require("blink_deps.semver")
local Util = require("blink_deps.util")
local VersionCompletion = require("blink_deps.version_completion")
local VERSION = require("blink_deps.version")

--------------------------------------------------------------------------------
-- CARGO
--
-- Completion for Cargo.toml: crate names, version requirements and features.
--
-- This file is the wiring. What the cursor means is worked out by
-- blink_deps.cargo_context, crates are looked up through the registries of
-- the cargo ecosystem, and versions are gathered by the shared version
-- completion. What is decided here is Cargo's own: which versions are worth
-- offering, in what order, and what accepting a suggestion writes.
--------------------------------------------------------------------------------

local lower = Util.lower
local trim = Util.trim
local response = Util.response
local make_range = Util.make_range

Source.VERSION = VERSION

-- A single letter matches a large part of the registry and says nothing
-- about what the user is after.
Source.NAME_MIN_CHARS = 2

-- Ranking: a crate named exactly what was typed is the one meant, and one
-- starting with it is likelier than one merely containing it. Within each
-- tier the registry's own relevance order is kept.
local EXACT_NAME_BONUS = 10000
local PREFIX_NAME_BONUS = 1000

local function is_cargo_toml()
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "Cargo.toml"
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
		ecosystem = "cargo",

		version_catalog = {},
	}, {
		__index = Source,
	})
end

function Source:enabled()
	return is_cargo_toml()
end

function Source:get_trigger_characters()
	return { '"', "'", ".", "-" }
end

--------------------------------------------------------------------------------
-- CRATE NAMES
--------------------------------------------------------------------------------

-- Cargo treats - and _ in a crate name as the same character when looking a
-- crate up, so they are the same for matching what was typed too. So is a
-- space: "serde json" is someone typing towards serde_json.
local function normalized_name(name)
	return (lower(name):gsub("[_%s]+", "-"))
end

local function name_score(name, typed, position, total)
	local crate = normalized_name(name)
	local wanted = normalized_name(typed)

	local score = total - position + 1

	if crate == wanted then
		return score + EXACT_NAME_BONUS
	end

	if Util.starts_with(crate, wanted) then
		return score + PREFIX_NAME_BONUS
	end

	return score
end

-- What accepting a crate writes.
--
-- On a line of its own the whole dependency is written, with the version a
-- new dependency should have, so one acceptance leaves a line that builds.
-- Anywhere else only the name is replaced: the rest of the line is already
-- someone's decision.
local function name_text(ctx, package, alone_on_line)
	if ctx.form == "key"
		and alone_on_line
		and package.latest_version
	then
		-- Build metadata identifies a build, not a release, and has no
		-- place in a requirement.
		local version = package.latest_version:gsub("%+.*$", "")

		return package.name .. ' = "' .. version .. '"'
	end

	return package.name
end

local function complete_name(self, context, ctx, callback)
	local typed = trim(ctx.value)

	if #typed < Source.NAME_MIN_CHARS then
		callback(response({}, true))

		return nil
	end

	local line = vim.api.nvim_get_current_line()
	local alone_on_line = line:sub(ctx.col + 1):match("^%s*$") ~= nil

	local range = make_range(context, ctx.value)

	local cancelled = false
	local sent = {}
	local called = false

	local function emit(packages)
		if cancelled then
			return
		end

		local items = {}

		for position, package in ipairs(packages or {}) do
			local name = package.name

			if type(name) == "string" and name ~= "" and not sent[name] then
				sent[name] = true

				table.insert(items, {
					label = name,
					kind = Util.KIND.Module,
					score_offset = name_score(name, typed, position, #packages),
					labelDetails = {
						description = package.latest_version,
					},
					textEdit = {
						range = range,
						newText = name_text(ctx, package, alone_on_line),
					},
					data = {
						cargo = {
							kind = "crate",
							name = name,
							latest_version = package.latest_version,
							description = package.description,
							downloads = package.downloads,
						},
					},
				})
			end
		end

		if #items > 0 or not called then
			called = true

			callback(response(items, true))
		end
	end

	Registries.dispatch(
		self,
		"search",
		{
			debounce_ms = Util.search_debounce_ms(self),
			cancelled = function()
				return cancelled
			end,
		},
		function(registry)
			registry:search(self, lower(typed), function(packages, err)
				if err then
					Util.debug_log(
						self,
						"Crate search failed in %s for %s: %s",
						registry.name,
						typed,
						tostring(err)
					)

					-- Still an answer: the menu must not wait on it.
					emit({})

					return
				end

				emit(packages)
			end)
		end
	)

	return function()
		cancelled = true
	end
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- Highest first, with every release above every prerelease.
--
-- By precedence 2.0.0-rc.1 is above 1.9.0, but cargo does not select a
-- prerelease unless the requirement names one, and the first suggestion
-- should be what a new dependency ought to use.
--------------------------------------------------------------------------------

local function sort_versions(entries)
	Semver.sort(entries)

	local releases = {}
	local prereleases = {}

	for _, entry in ipairs(entries) do
		if Semver.is_prerelease(entry.value) then
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

local function complete_version(self, context, ctx, callback)
	return VersionCompletion.complete(self, context, ctx, callback, {
		package = {
			name = ctx.crate,
		},

		key = ctx.crate,
		catalog = self.version_catalog,
		sort = sort_versions,

		-- A yanked release cannot be selected for a new dependency.
		accept = function(version)
			return not version.yanked
		end,

		describe = function(version)
			if Semver.is_prerelease(version.value) then
				return "prerelease"
			end

			return nil
		end,
	})
end

--------------------------------------------------------------------------------
-- FEATURES
--------------------------------------------------------------------------------

-- The features already written in the array under the cursor, so they are
-- not offered a second time. The array may span lines.
local function listed_features(lines, ctx)
	local first = ctx.row

	while first > 1 and not lines[first]:find("features%s*=") do
		first = first - 1
	end

	local last = ctx.row

	while last < #lines and not lines[last]:find("]", 1, true) do
		last = last + 1
	end

	local listed = {}

	for row = first, last do
		local line = lines[row]

		-- On the first line only what follows the key belongs to the array.
		local offset = 0

		if row == first then
			offset = select(2, line:find("features%s*=")) or 0
		end

		for start, feature, finish in line:sub(offset + 1):gmatch("()[\"']([^\"']*)[\"']()") do
			-- The string under the cursor is the one being typed.
			local under_cursor = row == ctx.row
				and offset + start - 1 <= ctx.col
				and ctx.col <= offset + finish - 1

			if not under_cursor and feature ~= "" then
				listed[feature] = true
			end
		end
	end

	return listed
end

local function complete_feature(self, context, ctx, callback)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local listed = listed_features(lines, ctx)

	local range = make_range(context, ctx.value)

	local cancelled = false
	local sent = {}
	local called = false

	local function emit(features)
		if cancelled then
			return
		end

		local items = {}

		for _, feature in ipairs(features or {}) do
			-- default is on unless switched off; nobody lists it.
			if type(feature) == "string"
				and feature ~= "default"
				and not listed[feature]
				and not sent[feature]
			then
				sent[feature] = true

				table.insert(items, {
					label = feature,
					kind = Util.KIND.Value,
					sortText = feature,
					labelDetails = {
						description = ctx.crate,
					},
					textEdit = {
						range = range,
						newText = feature,
					},
				})
			end
		end

		if #items > 0 or not called then
			called = true

			callback(response(items, true))
		end
	end

	Registries.dispatch(
		self,
		"features",
		{
			debounce_ms = Util.debounce_ms(self),
			cancelled = function()
				return cancelled
			end,
		},
		function(registry)
			registry:features(self, { name = ctx.crate }, function(features, err)
				if err then
					Util.debug_log(
						self,
						"Feature lookup failed in %s for %s: %s",
						registry.name,
						ctx.crate,
						tostring(err)
					)

					emit({})

					return
				end

				emit(features)
			end)
		end
	)

	return function()
		cancelled = true
	end
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
	local data = resolved.data and resolved.data.cargo

	if type(data) == "table" and data.kind == "crate" then
		local parts = { "**" .. data.name .. "**" }

		if data.latest_version then
			parts[1] = parts[1] .. " `" .. data.latest_version .. "`"
		end

		if data.description then
			table.insert(parts, trim(data.description))
		end

		if data.downloads then
			table.insert(parts, grouped(data.downloads) .. " downloads")
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

function Source.debug_listed_features(lines, ctx)
	return Util.sorted_keys(listed_features(lines, ctx))
end

--------------------------------------------------------------------------------
-- ENTRY
--------------------------------------------------------------------------------

function Source:get_completions(context, callback)
	if not is_cargo_toml() then
		callback(response({}, false))

		return nil
	end

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

	if ctx.kind == "feature" then
		return complete_feature(self, context, ctx, callback)
	end

	callback(response({}, false))

	return nil
end

return Source
