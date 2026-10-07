local Diagnostics = require("blink_deps.diagnostics")
local Health = require("blink_deps.health")
local Source = require("blink_deps")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- HARNESS
	--------------------------------------------------------------------------------

	-- Empty directories, so the report never describes the machine running
	-- the suite.
	local home = vim.fn.tempname()

	vim.fn.mkdir(home .. "/m2", "p")
	vim.fn.mkdir(home .. "/cargo/registry/index/index.crates.io-0000000000000000", "p")
	vim.fn.mkdir(home .. "/cache", "p")

	local function options(extra)
		return vim.tbl_deep_extend("force", {
			local_repository = {
				path = home .. "/m2",
			},
			cargo_home = {
				path = home .. "/cargo",
			},
			cache = {
				dir = home .. "/cache",
			},
		}, extra or {})
	end

	local function section(report, title)
		for _, candidate in ipairs(report) do
			if candidate.title:find(title, 1, true) == 1 then
				return candidate
			end
		end

		error("no section " .. title)
	end

	-- The entries of a section as "level: text" lines.
	local function lines(report, title)
		local list = {}

		for _, entry in ipairs(section(report, title).entries) do
			table.insert(list, entry.level .. ": " .. entry.text)
		end

		return list
	end

	local function find(report, title, fragment)
		for _, entry in ipairs(section(report, title).entries) do
			if entry.text:find(fragment, 1, true) then
				return entry
			end
		end

		return nil
	end

	local function flat(report)
		local parts = {}

		for _, candidate in ipairs(report) do
			table.insert(parts, candidate.title)

			for _, entry in ipairs(candidate.entries) do
				table.insert(parts, entry.text)
				table.insert(parts, entry.advice or "")
			end
		end

		return table.concat(parts, "\n")
	end

	--------------------------------------------------------------------------------
	-- SHAPE
	--------------------------------------------------------------------------------

	-- Without a source the report falls back to the default locations, so
	-- what it holds depends on the machine. It is only asked for the parts
	-- that do not.
	local bare = Diagnostics.report()

	local titles = {}

	for _, candidate in ipairs(Diagnostics.report({ source = Source.new(options()) })) do
		table.insert(titles, (candidate.title:gsub(" %d.*$", "")))

		for _, entry in ipairs(candidate.entries) do
			ok(
				({ ok = true, info = true, warn = true, error = true })[entry.level],
				"Every entry must have a known level"
			)

			ok(
				type(entry.text) == "string" and entry.text ~= "",
				"Every entry must have text"
			)
		end
	end

	eq(
		titles,
		{ "blink-cmp-deps", "Source", "Current file", "Registries", "On this machine", "Cache" },
		"A report must have its sections in a fixed order"
	)

	--------------------------------------------------------------------------------
	-- REQUIREMENTS
	--------------------------------------------------------------------------------

	local version = vim.version()

	ok(
		find(bare, "blink-cmp-deps", string.format("Neovim %d.%d.%d", version.major, version.minor, version.patch)).level
			== "ok",
		"The running Neovim must be reported as supported"
	)

	local original_executable = vim.fn.executable

	vim.fn.executable = function()
		return 0
	end

	local without_curl = find(Diagnostics.report(), "blink-cmp-deps", "curl")

	vim.fn.executable = original_executable

	eq(
		{ without_curl.level, without_curl.advice ~= nil },
		{ "error", true },
		"A missing curl must be an error that says what still works"
	)

	eq(
		find(bare, "blink-cmp-deps", "blink.cmp").level,
		"error",
		"A missing blink.cmp must be an error"
	)

	package.loaded["blink.cmp"] = {}

	eq(
		find(Diagnostics.report(), "blink-cmp-deps", "blink.cmp").level,
		"ok",
		"A loadable blink.cmp must be reported as available"
	)

	package.loaded["blink.cmp"] = nil

	--------------------------------------------------------------------------------
	-- SOURCE
	--------------------------------------------------------------------------------

	eq(
		lines(bare, "Source"),
		{ "warn: blink.cmp has not created the source yet" },
		"Without a source the report must say so and how to fix it"
	)

	ok(
		section(bare, "Source").entries[1].advice:find('module = "blink_deps"', 1, true),
		"The advice must name the module to configure"
	)

	local source = Source.new(options())

	eq(
		lines(Diagnostics.report({ source = source }), "Source"),
		{
			"ok: The source is registered with blink.cmp",
			"info: Every supported file is enabled",
		},
		"A default source must be described"
	)

	local restricted = Source.new(options({
		enabled_sources = { "maven", "cargo" },
		debug = true,
	}))

	eq(
		lines(Diagnostics.report({ source = restricted }), "Source"),
		{
			"ok: The source is registered with blink.cmp",
			"info: enabled_sources: cargo, maven",
			"info: Debug logging is on; see :messages",
		},
		"A restricted source and debug logging must be described"
	)

	--------------------------------------------------------------------------------
	-- CURRENT FILE
	--------------------------------------------------------------------------------

	local HANDLED = "info: Handled files: *.versions.toml, Cargo.toml, build.gradle, build.gradle.kts, "
		.. "package.json, pom.xml, pyproject.toml, requirements*.txt"

	local function file(path, subject)
		return lines(Diagnostics.report({ source = subject or source, path = path }), "Current file")
	end

	eq(
		file("/project/pom.xml"),
		{ "ok: pom.xml is handled as maven (maven ecosystem), completed by maven" },
		"A Maven file must be recognised"
	)

	eq(
		file("/project/build.gradle.kts"),
		{
			"ok: build.gradle.kts is handled as gradle_kts (maven ecosystem), "
				.. "completed by gradle_kts and gradle_catalog_accessor",
		},
		"A file with several delegates must name them all"
	)

	eq(
		file("/project/Cargo.toml"),
		{ "ok: Cargo.toml is handled as cargo (cargo ecosystem), completed by cargo" },
		"A Cargo file must be recognised"
	)

	eq(
		file("/project/package.json"),
		{ "ok: package.json is handled as npm (npm ecosystem), completed by npm" },
		"An npm file must be recognised"
	)

	eq(
		file("/project/requirements-dev.txt"),
		{ "ok: requirements-dev.txt is handled as requirements (pypi ecosystem), completed by python" },
		"A requirements file must be recognised"
	)

	eq(
		file("/project/pyproject.toml"),
		{ "ok: pyproject.toml is handled as pyproject (pypi ecosystem), completed by python" },
		"A pyproject.toml must be recognised"
	)

	eq(
		file("/project/README.md"),
		{
			"info: README.md is not a dependency file the plugin handles",
			HANDLED,
		},
		"Another file must be reported as unhandled, with what is handled"
	)

	eq(
		file(""),
		{
			"info: The current buffer has no file name",
			HANDLED,
		},
		"A buffer without a name must be reported as that"
	)

	-- Switched off by configuration is not the same as unknown.
	local switched_off = Diagnostics.report({
		source = restricted,
		path = "/project/build.gradle",
	})

	eq(
		lines(switched_off, "Current file"),
		{ "warn: build.gradle is a build.gradle file, but it is switched off" },
		"A handled file that is switched off must be reported as that"
	)

	ok(
		section(switched_off, "Current file").entries[1].advice:find('"gradle"', 1, true),
		"The advice must name the source to enable"
	)

	--------------------------------------------------------------------------------
	-- REGISTRIES
	--------------------------------------------------------------------------------

	local configured = Source.new(options({
		repositories = {
			{
				name = "Company",
				type = "nexus",
				url = "https://deploy:hunter2@nexus.company.test",
				repository = "releases",
			},
			{
				url = "https://token-123:x-oauth@repo.company.test/maven",
			},
		},
	}))

	local with_repositories = Diagnostics.report({
		source = configured,
		path = "/project/pom.xml",
	})

	eq(
		lines(with_repositories, "Registries"),
		{
			"info: cargo: 2 registries",
			"info: 1. Cargo cache (on disk): features, search, versions",
			"info: 2. crates.io (public): features, search, versions",
			"info: maven, used for the current file: 4 registries",
			"info: 1. Local repository (on disk): packages, search, versions",
			"info: 2. Maven Central (public): namespaces, packages, search, versions",
			"info: 3. Company <https://***@nexus.company.test>: namespaces, packages, versions",
			"info: 4. https://***@repo.company.test/maven: versions",
			"info: npm: 2 registries",
			"info: 1. This project (on disk): search, versions",
			"info: 2. npm (public): search, versions",
			"info: pypi: 2 registries",
			"info: 1. PyPI (public): search, versions",
			"info: 2. Popular PyPI projects: search",
		},
		"Every ecosystem's registries must be listed in order with their capabilities"
	)

	local everything = flat(with_repositories)

	for _, secret in ipairs({ "hunter2", "deploy", "token-123", "x-oauth" }) do
		ok(
			not everything:find(secret, 1, true),
			"A report must never contain a credential (" .. secret .. ")"
		)
	end

	-- Nothing enabled for an ecosystem is worth a warning.
	local silent = Source.new(options({
		crates_io = { enabled = false },
		cargo_home = { enabled = false },
	}))

	local nothing = find(Diagnostics.report({ source = silent }), "Registries", "cargo")

	eq(
		{ nothing.level, nothing.text },
		{ "warn", "cargo: no registry is enabled" },
		"An ecosystem with nothing to ask must be a warning"
	)

	--------------------------------------------------------------------------------
	-- ON THIS MACHINE
	--------------------------------------------------------------------------------

	eq(
		lines(Diagnostics.report({ source = source }), "On this machine"),
		{
			"ok: Maven local repository: " .. home .. "/m2",
			"ok: Cargo home: " .. home .. "/cargo",
			"info: Cargo home holds 1 crates.io index cache, 0 crates.io archive directories",
		},
		"Local sources that exist must be reported with what they hold"
	)

	local absent = Source.new(options({
		local_repository = { path = home .. "/no-m2" },
		cargo_home = { path = home .. "/no-cargo" },
	}))

	eq(
		lines(Diagnostics.report({ source = absent }), "On this machine"),
		{
			"info: Maven local repository: " .. home .. "/no-m2 does not exist",
			"info: Cargo home: " .. home .. "/no-cargo does not exist",
		},
		"A missing local source is normal and must not be a warning"
	)

	eq(
		lines(Diagnostics.report({ source = silent }), "On this machine")[2],
		"info: Cargo home: switched off",
		"A local source that is switched off must be reported as that"
	)

	--------------------------------------------------------------------------------
	-- CACHE
	--------------------------------------------------------------------------------

	eq(
		lines(Diagnostics.report({ source = source }), "Cache"),
		{
			"ok: Persistent cache: " .. home .. "/cache, kept for 24 hours",
			"info: 0 entries on disk",
			"info: No lookup has been made in this session yet",
		},
		"An unused cache must be described"
	)

	local uncached = Diagnostics.report({
		source = Source.new(options({ cache = { enabled = false } })),
	})

	eq(
		{ section(uncached, "Cache").entries[1].level, section(uncached, "Cache").entries[1].text },
		{ "warn", "The persistent cache is switched off" },
		"A cache that is switched off must be a warning"
	)

	eq(
		find(
			Diagnostics.report({ source = Source.new(options({ cache = { ttl = 90 } })) }),
			"Cache",
			"Persistent cache"
		).text,
		"Persistent cache: " .. home .. "/cache, kept for 90 seconds",
		"A lifetime that is not whole hours must be shown in seconds"
	)

	eq(
		find(
			Diagnostics.report({ source = Source.new(options({ cache = { ttl = 0 } })) }),
			"Cache",
			"Persistent cache"
		).text,
		"Persistent cache: " .. home .. "/cache, never expires",
		"A lifetime of zero means entries never expire"
	)

	-- Lookups, counted by where they were answered. Driven through real
	-- delegates with stand in fetches, so nothing touches the network.
	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-diagnostics/pom.xml")
	source:get_trigger_characters()

	local central = source.shared_state.central_pipeline

	local function lookup(pipeline, key, value, err)
		pipeline:fetch({
			key = key,
			fetch = function(done)
				done(value, err)
			end,
		}, function() end)
	end

	lookup(central, "a", { "x" })
	lookup(central, "a", { "x" })
	lookup(central, "a", { "x" })
	lookup(central, "b", { "y" })
	lookup(source.shared_state.repository_pipeline, "c", nil, "timeout")

	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-diagnostics/Cargo.toml")
	source:get_trigger_characters()

	local cargo = source.delegates.cargo

	-- A Cargo delegate creates its pipelines as it needs them.
	cargo.crates_io_index_pipeline = require("blink_deps.pipeline").new({
		name = "crates-io-index",
	})

	lookup(cargo.crates_io_index_pipeline, "serde", { "1.0.0" })

	local used = Diagnostics.report({ source = source })

	eq(
		vim.list_slice(lines(used, "Cache"), 3),
		{
			"info: Lookups this session, by where they were answered:",
			"info: central: 4 lookups, 50% answered from cache (2 memory, 0 shared, 0 disk), 2 fetched",
			"info: crates-io-index: 1 lookup, 0% answered from cache (0 memory, 0 shared, 0 disk), 1 fetched",
			"warn: repository: 1 lookup, 0% answered from cache (0 memory, 0 shared, 0 disk), 1 fetched, 1 failure",
		},
		"Each pipeline that was used must be listed once, with failures raised to a warning"
	)

	ok(
		find(used, "Cache", "repository").advice:find("debug = true", 1, true),
		"A failing pipeline must say how to find out why"
	)

	-- Maven delegates share their pipelines: opening another Maven file
	-- must not list them a second time.
	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-diagnostics/build.gradle")
	source:get_trigger_characters()

	eq(
		#lines(Diagnostics.report({ source = source }), "Cache"),
		#lines(used, "Cache"),
		"Shared pipelines must be listed once however many delegates hold them"
	)

	--------------------------------------------------------------------------------
	-- LATEST SOURCE
	--------------------------------------------------------------------------------

	local newest = Source.new(options())

	ok(Source.latest() == newest, "The most recently created source must be the one reported on")

	--------------------------------------------------------------------------------
	-- :checkhealth
	--------------------------------------------------------------------------------

	local original_health = vim.health
	local rendered = {}

	rawset(vim, "health", {
		start = function(title)
			table.insert(rendered, "# " .. title)
		end,
		ok = function(text)
			table.insert(rendered, "ok " .. text)
		end,
		info = function(text)
			table.insert(rendered, "info " .. text)
		end,
		warn = function(text, advice)
			table.insert(rendered, "warn " .. text .. " -> " .. tostring(advice))
		end,
		error = function(text, advice)
			table.insert(rendered, "error " .. text .. " -> " .. tostring(advice))
		end,
	})

	local checked = pcall(Health.check)

	rawset(vim, "health", original_health)

	ok(checked, ":checkhealth must not raise")

	local expected = {}

	for _, candidate in ipairs(Diagnostics.report({ source = newest, path = "" })) do
		table.insert(expected, "# " .. candidate.title)
	end

	local started = vim.tbl_filter(function(line)
		return line:sub(1, 2) == "# "
	end, rendered)

	eq(started, expected, ":checkhealth must render every section of the report")

	ok(
		vim.tbl_contains(rendered, "ok The source is registered with blink.cmp"),
		":checkhealth must describe the source blink is using"
	)

	ok(
		vim.tbl_contains(rendered, "error blink.cmp could not be loaded -> nil"),
		"Entries must be rendered at their own level"
	)

	vim.fn.delete(home, "rf")
end
