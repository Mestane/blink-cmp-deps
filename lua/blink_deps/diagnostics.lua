local DiskCache = require("blink_deps.disk_cache")
local Http = require("blink_deps.http")
local Manifests = require("blink_deps.manifests")
local Registries = require("blink_deps.registries")
local Util = require("blink_deps.util")
local VERSION = require("blink_deps.version")

--------------------------------------------------------------------------------
-- DIAGNOSTICS
--
-- Describes what the plugin is doing: whether its requirements are met,
-- what it makes of the current file, which registries it would ask and how
-- its caches are performing.
--
-- It builds a report as plain data and renders nothing. :checkhealth turns
-- the report into health output; a command or a picker could show the same
-- report another way.
--
-- A report never contains credentials. Addresses are redacted, and the
-- user's options are described, never dumped.
--------------------------------------------------------------------------------

local M = {}

M.MIN_NEOVIM = "0.10"

--------------------------------------------------------------------------------
-- REPORT SHAPE
--
-- A report is a list of sections, each { title, entries }. An entry is
-- { level, text, advice }, where level is one of ok, info, warn, error and
-- advice, when present, is what the user can do about it.
--------------------------------------------------------------------------------

local function new_section(title)
	local section = {
		title = title,
		entries = {},
	}

	local function add(level, text, advice)
		table.insert(section.entries, {
			level = level,
			text = text,
			advice = advice,
		})
	end

	return section, add
end

local function plural(count, singular, plural_form)
	if count == 1 then
		return "1 " .. singular
	end

	return tostring(count) .. " " .. (plural_form or (singular .. "s"))
end

--------------------------------------------------------------------------------
-- REQUIREMENTS
--------------------------------------------------------------------------------

local function requirements()
	local section, add = new_section("blink-cmp-deps " .. VERSION)

	local version = vim.version()

	local running = string.format(
		"Neovim %d.%d.%d",
		version.major,
		version.minor,
		version.patch
	)

	if vim.fn.has("nvim-" .. M.MIN_NEOVIM) == 1 then
		add("ok", running)
	else
		add(
			"error",
			running .. " is too old",
			"Neovim " .. M.MIN_NEOVIM .. " or newer is required"
		)
	end

	if vim.fn.executable("curl") == 1 then
		add("ok", "curl is available")
	else
		add(
			"error",
			"curl was not found",
			"Every registry is reached through curl; only results already on disk will be offered"
		)
	end

	if pcall(require, "blink.cmp") then
		add("ok", "blink.cmp is available")
	else
		add("error", "blink.cmp could not be loaded")
	end

	return section
end

--------------------------------------------------------------------------------
-- SOURCE
--------------------------------------------------------------------------------

local function source_section(source)
	local section, add = new_section("Source")

	if not source then
		add(
			"warn",
			"blink.cmp has not created the source yet",
			"Add the provider to blink.cmp with module = \"blink_deps\", then open a dependency file"
		)

		return section
	end

	add("ok", "The source is registered with blink.cmp")

	if source.enabled_sources then
		add(
			"info",
			"enabled_sources: " .. table.concat(Util.sorted_keys(source.enabled_sources), ", ")
		)
	else
		add("info", "Every supported file is enabled")
	end

	if source.opts.debug then
		add("info", "Debug logging is on; see :messages")
	end

	return section
end

--------------------------------------------------------------------------------
-- CURRENT FILE
--------------------------------------------------------------------------------

local function file_section(source, path)
	local section, add = new_section("Current file")

	local name = path ~= "" and vim.fn.fnamemodify(path, ":t") or ""

	if name == "" then
		add("info", "The current buffer has no file name")
	end

	-- Matched against every manifest, enabled or not, so that a file
	-- switched off by configuration is reported as that and not as unknown.
	local matched = Manifests.for_path(path)
	local enabled = source and source.enabled_sources or nil

	for _, manifest in ipairs(matched) do
		local delegates = {}

		for _, delegate in ipairs(manifest.delegates) do
			table.insert(delegates, delegate.id)
		end

		if enabled and not enabled[manifest.id] then
			add(
				"warn",
				name .. " is a " .. manifest.description .. " file, but it is switched off",
				"Add \"" .. manifest.id .. "\" to enabled_sources to complete it"
			)
		else
			add(
				"ok",
				string.format(
					"%s is handled as %s (%s ecosystem), completed by %s",
					name,
					manifest.id,
					manifest.ecosystem,
					table.concat(delegates, " and ")
				)
			)
		end
	end

	if #matched == 0 then
		if name ~= "" then
			add("info", name .. " is not a dependency file the plugin handles")
		end

		local supported = {}

		for _, manifest in ipairs(Manifests.list()) do
			table.insert(supported, manifest.description)
		end

		table.sort(supported)

		add("info", "Handled files: " .. table.concat(supported, ", "))
	end

	return section, matched
end

--------------------------------------------------------------------------------
-- REGISTRIES
--------------------------------------------------------------------------------

local function ecosystems()
	local seen = {}
	local list = {}

	for _, manifest in ipairs(Manifests.list()) do
		if not seen[manifest.ecosystem] then
			seen[manifest.ecosystem] = true
			table.insert(list, manifest.ecosystem)
		end
	end

	table.sort(list)

	return list
end

local function describe_registry(registry)
	local traits = {}

	if registry.offline then
		table.insert(traits, "on disk")
	end

	if registry.public then
		table.insert(traits, "public")
	end

	local text = registry.name

	-- A configured repository is shown with its address, so two with
	-- similar names can be told apart. The address may carry credentials.
	if type(registry.repository) == "table" and registry.repository.url then
		local address = Http.redact(registry.repository.url)

		-- An unnamed repository is already named after its address.
		if address ~= registry.name then
			text = text .. " <" .. address .. ">"
		end
	end

	if #traits > 0 then
		text = text .. " (" .. table.concat(traits, ", ") .. ")"
	end

	return text .. ": " .. table.concat(Util.sorted_keys(registry.capabilities), ", ")
end

local function registries_section(source, current)
	local section, add = new_section("Registries")

	local opts = source and source.opts or {}

	for _, ecosystem in ipairs(ecosystems()) do
		-- Asked the way a delegate of that ecosystem would ask, without
		-- creating one.
		local registries = Registries.list({
			opts = opts,
			ecosystem = ecosystem,
		})

		local heading = ecosystem

		if current[ecosystem] then
			heading = heading .. ", used for the current file"
		end

		if #registries == 0 then
			add(
				"warn",
				heading .. ": no registry is enabled",
				"Completion for this ecosystem has nothing to ask"
			)
		else
			add("info", heading .. ": " .. plural(#registries, "registry", "registries"))

			for position, registry in ipairs(registries) do
				add("info", string.format("%d. %s", position, describe_registry(registry)))
			end
		end
	end

	return section
end

--------------------------------------------------------------------------------
-- LOCAL SOURCES
--------------------------------------------------------------------------------

local function directory_state(path)
	if vim.fn.isdirectory(path) == 1 then
		return "ok", path
	end

	return "info", path .. " does not exist"
end

local function local_section(source)
	local section, add = new_section("On this machine")

	local subject = {
		opts = source and source.opts or {},
	}

	local LocalRepository = require("blink_deps.local_repository")

	if LocalRepository.is_enabled(subject) then
		local level, text = directory_state(LocalRepository.root(subject))

		add(level, "Maven local repository: " .. text)
	else
		add("info", "Maven local repository: switched off")
	end

	local CargoHome = require("blink_deps.cargo_home")

	if CargoHome.is_enabled(subject) then
		local level, text = directory_state(CargoHome.root(subject))

		add(level, "Cargo home: " .. text)

		if level == "ok" then
			add(
				"info",
				"Cargo home holds "
					.. plural(#CargoHome.debug_directories(subject, "index"), "crates.io index cache")
					.. ", "
					.. plural(
						#CargoHome.debug_directories(subject, "cache"),
						"crates.io archive directory",
						"crates.io archive directories"
					)
			)
		end
	else
		add("info", "Cargo home: switched off")
	end

	return section
end

--------------------------------------------------------------------------------
-- CACHE
--------------------------------------------------------------------------------

local function duration(seconds)
	if seconds <= 0 then
		return "never expires"
	end

	if seconds % 3600 == 0 then
		return "kept for " .. plural(seconds / 3600, "hour")
	end

	return "kept for " .. plural(seconds, "second")
end

local function cache_section(source)
	local section, add = new_section("Cache")

	local described = DiskCache.describe(source and source.opts.cache or nil)

	if not described.enabled then
		add(
			"warn",
			"The persistent cache is switched off",
			"Every Neovim session starts by asking the registries again"
		)
	else
		add("ok", "Persistent cache: " .. described.dir .. ", " .. duration(described.ttl))

		local files = vim.fn.globpath(described.dir, "*/*.json", false, true)

		add("info", plural(#files, "entry", "entries") .. " on disk")
	end

	local pipelines = source and source:pipelines() or {}

	if #pipelines == 0 then
		add("info", "No lookup has been made in this session yet")

		return section
	end

	add("info", "Lookups this session, by where they were answered:")

	for _, pipeline in ipairs(pipelines) do
		local stats = pipeline:stats()

		local total = stats.memory + stats.shared + stats.disk + stats.network

		if total > 0 then
			-- Everything that did not need a new fetch.
			local saved = total - stats.network

			local text = string.format(
				"%s: %s, %d%% answered from cache (%d memory, %d shared, %d disk), %d fetched",
				stats.name,
				plural(total, "lookup"),
				math.floor(saved * 100 / total + 0.5),
				stats.memory,
				stats.shared,
				stats.disk,
				stats.network
			)

			if stats.running > 0 then
				text = text .. ", " .. stats.running .. " running"
			end

			if stats.errors > 0 then
				add(
					"warn",
					text .. ", " .. plural(stats.errors, "failure"),
					"Turn on debug = true and see :messages for the reason"
				)
			else
				add("info", text)
			end
		end
	end

	return section
end

--------------------------------------------------------------------------------
-- REPORT
--
-- opts:
--   source  the unified source to describe, or nil if blink has not created
--           one
--   path    the file to describe, usually the current buffer's
--------------------------------------------------------------------------------

function M.report(opts)
	opts = opts or {}

	local source = opts.source
	local path = opts.path or ""

	local file, matched = file_section(source, path)

	local current = {}

	for _, manifest in ipairs(matched) do
		current[manifest.ecosystem] = true
	end

	return {
		requirements(),
		source_section(source),
		file,
		registries_section(source, current),
		local_section(source),
		cache_section(source),
	}
end

return M
