local Npm = require("blink_deps.npm")
local Unified = require("blink_deps")
local Util = require("blink_deps.util")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- LOADING
	--
	-- Checked first, before anything else in this spec can load a module: a
	-- session that only opens package.json must not pay for other ecosystems.
	--------------------------------------------------------------------------------

	local function loaded(name)
		return package.loaded[name] ~= nil
	end

	local function others_loaded()
		return {
			loaded("blink_deps.maven"),
			loaded("blink_deps.coordinates"),
			loaded("blink_deps.central"),
			loaded("blink_deps.cargo"),
			loaded("blink_deps.crates_io"),
			loaded("blink_deps.cargo_home"),
		}
	end

	eq(
		others_loaded(),
		{ false, false, false, false, false, false },
		"Loading the unified source and the npm delegate must not load other ecosystems"
	)

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A real buffer and a real cursor; the registry is hand written. A fixture
	-- is a package.json with a cursor mark, which is not | because | is part
	-- of the range syntax.
	--------------------------------------------------------------------------------

	local MARK = "‸"

	local deferred = {}
	local delays = {}

	rawset(Util, "defer", function(ms, fn)
		table.insert(delays, ms)
		table.insert(deferred, fn)
	end)

	local function run_deferred()
		local pending = deferred

		deferred = {}

		for _, fn in ipairs(pending) do
			fn()
		end
	end

	vim.o.virtualedit = "onemore"

	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-npm/package.json")

	local function place(fixture)
		local lines = vim.split(fixture, "\n", { plain = true })

		for row, line in ipairs(lines) do
			local column = line:find(MARK, 1, true)

			if column then
				lines[row] = line:sub(1, column - 1) .. line:sub(column + #MARK)

				vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
				vim.api.nvim_win_set_cursor(0, { row, column - 1 })

				return {
					get_pos = function()
						return {
							row = row - 1,
							col = column - 1,
						}
					end,
				}
			end
		end

		error("fixture has no cursor")
	end

	local function new_source()
		local source = Npm.new({})

		local backend = {
			id = "test",
			name = "Test",
			kind = "test",
			public = true,
			capabilities = { search = true, versions = true },
			calls = {},
		}

		for _, operation in ipairs({ "search", "versions" }) do
			backend[operation] = function(self, _, argument, callback)
				table.insert(self.calls, {
					operation = operation,
					argument = vim.deepcopy(argument),
					callback = callback,
				})
			end
		end

		source.registry_list = { backend }

		return source, backend
	end

	local function complete(source, fixture)
		local responses = {}

		deferred = {}
		delays = {}

		local cancel = source:get_completions(place(fixture), function(result)
			table.insert(responses, result)
		end)

		return responses, cancel
	end

	local function labels(result)
		local list = {}

		for _, item in ipairs(result.items) do
			table.insert(list, item.label)
		end

		return list
	end

	local function dependencies(line)
		return '{\n  "dependencies": {\n' .. line .. "\n  }\n}"
	end

	--------------------------------------------------------------------------------
	-- SOURCE
	--------------------------------------------------------------------------------

	local plain = Npm.new({})

	ok(plain:enabled(), "The source must enable itself for package.json")
	eq(plain.ecosystem, "npm", "The source must declare the npm ecosystem")

	eq(
		plain:get_trigger_characters(),
		{ '"', "@", "/", ".", "-", "^", "~" },
		"Opening a string, a scope and a range operator must trigger completion"
	)

	eq(
		Npm.new({}, { opts = { debug = true } }).opts.debug,
		true,
		"Options given through the provider config must be used"
	)

	--------------------------------------------------------------------------------
	-- ROUTING
	--------------------------------------------------------------------------------

	local source, backend = new_source()

	local responses = complete(source, '{ "name": "de' .. MARK .. '" }')

	eq(
		{ #responses, #responses[1].items, responses[1].is_incomplete_forward, #backend.calls },
		{ 1, 0, false, 0 },
		"Outside a dependency context the request must be closed without asking anyone"
	)

	--------------------------------------------------------------------------------
	-- PACKAGE NAMES
	--------------------------------------------------------------------------------

	source, backend = new_source()

	complete(source, dependencies('    "r' .. MARK .. '"'))

	eq({ #deferred, #backend.calls }, { 0, 0 }, "A single letter must not start a search")

	responses = complete(source, dependencies('    "React' .. MARK .. '"'))

	eq(delays, { Util.SEARCH_DEBOUNCE_MS }, "A name search must use the longer search debounce")

	run_deferred()

	eq(
		{ backend.calls[1].operation, backend.calls[1].argument },
		{ "search", "react" },
		"The registry must be searched for what was typed, lowercased"
	)

	backend.calls[1].callback({
		{ name = "react-is", latest_version = "19.3.0", downloads = 900 },
		{ name = "react", latest_version = "19.3.0", description = " A library\n", downloads = 224422510 },
		{ name = "@types/react", latest_version = "19.3.0" },
		{ name = "no-release" },
	}, nil)

	local found = {}

	for _, item in ipairs(responses[#responses].items) do
		found[item.label] = item
	end

	ok(
		found.react.score_offset > found["react-is"].score_offset
			and found["react-is"].score_offset > found["@types/react"].score_offset,
		"The exact name comes first, then names starting with what was typed"
	)

	eq(
		{
			found.react.labelDetails.description,
			found.react.kind,
			found.react.textEdit,
		},
		{
			"19.3.0",
			Util.KIND.Module,
			{
				newText = 'react": "^19.3.0',
				range = {
					start = { line = 2, character = 5 },
					["end"] = { line = 2, character = 10 },
				},
			},
		},
		"A key on its own must become the whole entry, with the caret npm install writes"
	)

	eq(
		found["no-release"].textEdit.newText,
		"no-release",
		"A package whose release is unknown must be written by name alone"
	)

	local resolved

	source:resolve(found.react, function(item)
		resolved = item
	end)

	eq(
		resolved.documentation,
		{
			kind = "markdown",
			value = "**react** `19.3.0`\n\nA library\n\n224,422,510 weekly downloads",
		},
		"Resolving a package must show its release, description and weekly downloads"
	)

	source:resolve({ label = "x" }, function(item)
		resolved = item
	end)

	eq(resolved, { label = "x" }, "An item that is not a package must pass through unchanged")

	-- What is written depends on what follows the key.
	local function written(line)
		local own_source, own_backend = new_source()
		local own_responses = complete(own_source, line)

		run_deferred()

		own_backend.calls[1].callback({
			{ name = "react", latest_version = "19.3.0" },
		}, nil)

		return own_responses[#own_responses].items[1].textEdit.newText
	end

	eq(
		written(dependencies('    "rea' .. MARK .. '",')),
		'react": "^19.3.0',
		"A trailing comma after the key does not count as a value"
	)

	eq(
		written(dependencies('    "rea' .. MARK .. '": "^18.0.0"')),
		"react",
		"A key that already has a value must be replaced alone"
	)

	eq(
		written(dependencies('    "rea' .. MARK .. '":')),
		"react",
		"A key followed by a colon must be replaced alone"
	)

	eq(
		written(dependencies('    "rea' .. MARK)),
		"react",
		"Without a closing quote to end the range, only the name is written"
	)

	eq(
		written('{ "bundledDependencies": ["rea' .. MARK .. '"] }'),
		"react",
		"In a list of names only the name is written"
	)

	eq(
		written(dependencies('    "old": "npm:rea' .. MARK .. '"')),
		"react",
		"In an alias only the name is written"
	)

	-- Scoped names are searched whole.
	source, backend = new_source()

	complete(source, dependencies('    "@types/no' .. MARK .. '"'))

	run_deferred()

	eq(backend.calls[1].argument, "@types/no", "A scoped name must be searched with its scope")

	-- The delegate says which manifest it is completing, for registries
	-- that read the project from disk.
	eq(
		source.manifest_path,
		"/tmp/blink-cmp-deps-npm/package.json",
		"The source must record the manifest being completed"
	)

	--------------------------------------------------------------------------------
	-- VERSION ORDER
	--------------------------------------------------------------------------------

	eq(
		Npm.debug_sort_versions({
			{ value = "1.0.0" },
			{ value = "2.0.0", tags = { "latest" } },
			{ value = "3.0.0-rc.1", tags = { "next" } },
			{ value = "2.1.0" },
			{ value = "0.9.0", deprecated = true },
			{ value = "3.0.0-beta.1", tags = { "beta" } },
			{ value = "2.2.0", deprecated = true },
		}),
		{
			{ value = "2.0.0", tags = { "latest" } },
			{ value = "2.1.0" },
			{ value = "1.0.0" },
			{ value = "3.0.0-rc.1", tags = { "next" } },
			{ value = "3.0.0-beta.1", tags = { "beta" } },
			{ value = "2.2.0", deprecated = true },
			{ value = "0.9.0", deprecated = true },
		},
		"What npm install picks comes first, then releases, tagged prereleases, deprecated last"
	)

	eq(Npm.debug_sort_versions({}), {}, "Sorting nothing must yield nothing")

	--------------------------------------------------------------------------------
	-- VERSIONS
	--------------------------------------------------------------------------------

	local published = {
		{ value = "18.2.0", timestamp = 0 },
		{ value = "19.0.0", timestamp = 0, tags = { "latest" } },
		{ value = "19.1.0-canary-aaa-20260101", timestamp = 0 },
		{ value = "19.1.0-canary-bbb-20260102", timestamp = 0, tags = { "canary", "next" } },
		{ value = "17.0.0", timestamp = 0, deprecated = true },
		{ value = "18.3.0", timestamp = 0 },
	}

	source, backend = new_source()

	responses = complete(source, dependencies('    "react": "' .. MARK .. '"'))

	eq(delays, { Util.DEBOUNCE_MS }, "A version lookup must use the ordinary debounce")

	run_deferred()

	eq(
		{ backend.calls[1].operation, backend.calls[1].argument },
		{ "versions", { name = "react" } },
		"The registry must be asked for the package's versions"
	)

	backend.calls[1].callback(published, nil)

	local versions = responses[#responses]

	eq(
		labels(versions),
		{ "19.0.0", "18.3.0", "18.2.0", "19.1.0-canary-bbb-20260102", "17.0.0" },
		"A nightly build without a tag must not be offered; a tagged one must"
	)

	local described = {}

	for _, item in ipairs(versions.items) do
		described[item.label] = item.labelDetails.description
	end

	eq(
		described,
		{
			["19.0.0"] = "latest",
			["18.3.0"] = "react",
			["18.2.0"] = "react",
			["19.1.0-canary-bbb-20260102"] = "canary, next",
			["17.0.0"] = "deprecated",
		},
		"Tags and deprecation must be shown; a plain release shows the package"
	)

	eq(
		versions.items[1].textEdit,
		{
			newText = "^19.0.0",
			range = {
				start = { line = 2, character = #'    "react": "' },
				["end"] = { line = 2, character = #'    "react": "' },
			},
		},
		"Into an empty range a version must be written with a caret"
	)

	-- A range the user has started is theirs to shape.
	local function version_text(range)
		local own_source, own_backend = new_source()
		local own_responses = complete(
			own_source,
			dependencies('    "react": "' .. range .. MARK .. '"')
		)

		run_deferred()

		own_backend.calls[1].callback(published, nil)

		local first = own_responses[#own_responses].items[1]

		return { first.textEdit.newText, first.textEdit.range.start.character - #'    "react": "' }
	end

	eq(version_text("^"), { "19.0.0", 1 }, "After a caret only the version is written")
	eq(version_text("~18."), { "19.0.0", 1 }, "After a tilde only the version being typed is replaced")
	eq(version_text("18"), { "19.0.0", 0 }, "Digits already typed mean no operator is added")
	eq(version_text(">=17.0.0 <"), { "19.0.0", 10 }, "Only the last comparator is replaced")
	eq(version_text("17 || "), { "19.0.0", 6 }, "Only the last alternative is replaced")

	-- Typing a prerelease asks for all of them.
	source, backend = new_source()

	responses = complete(source, dependencies('    "react": "19.1.0-' .. MARK .. '"'))

	run_deferred()

	backend.calls[1].callback(published, nil)

	eq(
		#responses[#responses].items,
		6,
		"While a prerelease is being typed, untagged prereleases must be offered too"
	)

	-- The two lists are kept apart in the session cache.
	local narrow = complete(source, dependencies('    "react": "' .. MARK .. '"'))

	eq(#deferred, 1, "The filtered list must not be served from the unfiltered one")

	run_deferred()

	backend.calls[2].callback(published, nil)

	eq(#narrow[#narrow].items, 5, "Each list must hold its own selection")

	local again = complete(source, dependencies('    "react": "' .. MARK .. '"'))

	eq({ #deferred, #again[1].items }, { 0, 5 }, "A cached list must be served without another lookup")

	eq(
		again[1].items[2].labelDetails.description,
		"react",
		"The cache key must never be what is shown next to a version"
	)

	-- An alias completes the package it points to.
	source, backend = new_source()

	responses = complete(source, dependencies('    "react-17": "npm:react@^17.' .. MARK .. '"'))

	run_deferred()

	eq(backend.calls[1].argument, { name = "react" }, "An alias must look up the package it points to")

	backend.calls[1].callback(published, nil)

	eq(
		responses[#responses].items[1].textEdit.newText,
		"19.0.0",
		"In an alias the range is never empty, so no caret is added"
	)

	-- A package whose every version is deprecated still completes.
	source, backend = new_source()

	responses = complete(source, dependencies('    "request": "' .. MARK .. '"'))

	run_deferred()

	backend.calls[1].callback({
		{ value = "2.88.2", timestamp = 0, deprecated = true, tags = { "latest" } },
		{ value = "2.88.0", timestamp = 0, deprecated = true },
	}, nil)

	eq(
		labels(responses[#responses]),
		{ "2.88.2", "2.88.0" },
		"Deprecated versions must be offered when they are all there is"
	)

	-- References to something else are not completed.
	source, backend = new_source()

	responses = complete(source, dependencies('    "local": "workspace:' .. MARK .. '"'))

	eq(
		{ #backend.calls, #deferred, responses[1].is_incomplete_forward },
		{ 0, 0, false },
		"A workspace reference must be left alone"
	)

	--------------------------------------------------------------------------------
	-- THROUGH THE UNIFIED SOURCE
	--------------------------------------------------------------------------------

	-- Both registries are switched off, so this reaches neither the network
	-- nor a lockfile.
	local unified = Unified.new({
		npm = {
			enabled = false,
		},
		npm_project = {
			enabled = false,
		},
	})

	ok(unified:enabled(), "The unified source must enable itself for package.json")

	eq(
		unified:get_trigger_characters(),
		{ '"', "@", "/", ".", "-", "^", "~" },
		"Trigger characters must come from the npm delegate"
	)

	local delegate = unified.delegates.npm

	ok(delegate ~= nil, "The npm delegate must be created on demand")

	eq(
		{ unified.shared_state, delegate.central_cache },
		{},
		"An npm delegate must not be given Maven's shared state, nor cause it to be built"
	)

	local closed = {}

	unified:get_completions(place(dependencies('    "react": "' .. MARK .. '"')), function(result)
		table.insert(closed, result)
	end)

	eq(
		closed[#closed].is_incomplete_forward,
		false,
		"Without any registry a version request must be closed"
	)

	local routed

	unified:resolve({
		label = "react",
		data = {
			npm = { kind = "package", name = "react" },
		},
	}, function(item)
		routed = item
	end)

	eq(
		routed.documentation.value,
		"**react**",
		"Resolve must be routed to the npm delegate by its data key"
	)

	eq(
		others_loaded(),
		{ false, false, false, false, false, false },
		"A whole npm session must never have loaded another ecosystem's modules"
	)

	-- Outside package.json the delegate stays out of the way.
	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-npm/tsconfig.json")

	ok(not plain:enabled(), "The source must not enable itself for another JSON file")

	local ignored = {}

	plain:get_completions(place(dependencies('    "react": "' .. MARK .. '"')), function(result)
		table.insert(ignored, result)
	end)

	eq(
		{ #ignored, #ignored[1].items, ignored[1].is_incomplete_forward },
		{ 1, 0, false },
		"In another file the request must be closed at once"
	)
end
