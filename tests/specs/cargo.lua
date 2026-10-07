local Cargo = require("blink_deps.cargo")
local Unified = require("blink_deps")
local Util = require("blink_deps.util")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- LOADING
	--
	-- Checked first, before anything else in this spec can load a module: a
	-- session that only opens Cargo.toml must not pay for Maven.
	--------------------------------------------------------------------------------

	local function loaded(name)
		return package.loaded[name] ~= nil
	end

	eq(
		{
			loaded("blink_deps.maven"),
			loaded("blink_deps.coordinates"),
			loaded("blink_deps.central"),
			loaded("blink_deps.local_repository"),
		},
		{ false, false, false, false },
		"Loading the unified source and the Cargo delegate must not load Maven's modules"
	)

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A real buffer and a real cursor; the registry is hand written, so no
	-- network is involved. A fixture is a Cargo.toml with | at the cursor.
	--------------------------------------------------------------------------------

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

	-- Insert mode puts the cursor after the last character of a line.
	-- Normal mode, which a headless session is in, does not without this.
	vim.o.virtualedit = "onemore"

	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-cargo/Cargo.toml")

	local function place(fixture)
		local lines = vim.split(fixture, "\n", { plain = true })

		for row, line in ipairs(lines) do
			local column = line:find("|", 1, true)

			if column then
				lines[row] = line:sub(1, column - 1) .. line:sub(column + 1)

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

	local function registry()
		local entry = {
			id = "test",
			name = "Test",
			kind = "test",
			public = true,
			capabilities = { search = true, versions = true, features = true },
			calls = {},
		}

		for _, operation in ipairs({ "search", "versions", "features" }) do
			entry[operation] = function(self, _, argument, callback)
				table.insert(self.calls, {
					operation = operation,
					argument = vim.deepcopy(argument),
					callback = callback,
				})
			end
		end

		return entry
	end

	local function new_source()
		local source = Cargo.new({})
		local backend = registry()

		source.registry_list = { backend }

		return source, backend
	end

	-- Runs completion at the fixture's cursor and returns every response.
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

	-- Labels as the menu would order them: by score, then sort text.
	local function ranked(result)
		local items = vim.deepcopy(result.items)

		table.sort(items, function(left, right)
			local left_score = left.score_offset or 0
			local right_score = right.score_offset or 0

			if left_score ~= right_score then
				return left_score > right_score
			end

			return (left.sortText or left.label) < (right.sortText or right.label)
		end)

		return labels({ items = items })
	end

	--------------------------------------------------------------------------------
	-- SOURCE
	--------------------------------------------------------------------------------

	local plain = Cargo.new({})

	ok(plain:enabled(), "The source must enable itself for Cargo.toml")
	eq(plain.ecosystem, "cargo", "The source must declare the cargo ecosystem")

	eq(
		plain:get_trigger_characters(),
		{ '"', "'", ".", "-" },
		"Opening a string and typing a version or a hyphenated name must trigger completion"
	)

	local configured = Cargo.new({}, { opts = { debug = true } })

	eq(configured.opts.debug, true, "Options given through the provider config must be used")

	--------------------------------------------------------------------------------
	-- ROUTING
	--------------------------------------------------------------------------------

	local source, backend = new_source()

	local responses = complete(source, '[package]\nname = "de|"')

	eq(
		{ #responses, #responses[1].items, responses[1].is_incomplete_forward, #backend.calls },
		{ 1, 0, false, 0 },
		"Outside a dependency context the request must be closed without asking anyone"
	)

	--------------------------------------------------------------------------------
	-- CRATE NAMES
	--------------------------------------------------------------------------------

	source, backend = new_source()

	responses = complete(source, "[dependencies]\ns|")

	eq(
		{ #responses, #deferred, #backend.calls },
		{ 1, 0, 0 },
		"A single letter must not start a search"
	)

	responses = complete(source, "[dependencies]\nSerde_J|")

	eq(#backend.calls, 0, "A search must wait for the debounce")
	eq(delays, { Util.SEARCH_DEBOUNCE_MS }, "A name search must use the longer search debounce")

	run_deferred()

	eq(
		{ backend.calls[1].operation, backend.calls[1].argument },
		{ "search", "serde_j" },
		"The registry must be searched for what was typed, lowercased"
	)

	backend.calls[1].callback({
		{ name = "serde", latest_version = "1.0.229", downloads = 900 },
		{ name = "serde-json-core", latest_version = "0.6.0" },
		{ name = "serde_json", latest_version = "1.0.151", description = " A JSON format\n", downloads = 1395963763 },
		{ name = "unrelated", latest_version = "2.0.0" },
		{ name = "serde_json", latest_version = "9.9.9" },
		{ latest_version = "1.0.0" },
	}, nil)

	local found = responses[#responses]

	eq(#found.items, 4, "Entries without a name are dropped and a repeated crate is offered once")

	eq(
		ranked(found),
		{ "serde-json-core", "serde_json", "serde", "unrelated" },
		"Crates starting with what was typed come first, hyphen and underscore being equal"
	)

	local serde_json = found.items[3]

	eq(
		{
			serde_json.label,
			serde_json.labelDetails.description,
			serde_json.kind,
			serde_json.textEdit,
		},
		{
			"serde_json",
			"1.0.151",
			Util.KIND.Module,
			{
				newText = 'serde_json = "1.0.151"',
				range = {
					start = { line = 1, character = 0 },
					["end"] = { line = 1, character = 7 },
				},
			},
		},
		"On a line of its own, accepting a crate must write the whole dependency"
	)

	-- Resolve.
	local resolved

	source:resolve(serde_json, function(item)
		resolved = item
	end)

	eq(
		resolved.documentation,
		{
			kind = "markdown",
			value = "**serde_json** `1.0.151`\n\nA JSON format\n\n1,395,963,763 downloads",
		},
		"Resolving a crate must show its release, description and downloads"
	)

	source:resolve(found.items[2], function(item)
		resolved = item
	end)

	eq(
		resolved.documentation.value,
		"**serde-json-core** `0.6.0`",
		"Missing details must simply be left out"
	)

	source:resolve({ label = "x" }, function(item)
		resolved = item
	end)

	eq(resolved, { label = "x" }, "An item that is not a crate must pass through unchanged")

	-- Exact names.
	source, backend = new_source()

	responses = complete(source, "[dependencies]\nto|")

	run_deferred()

	backend.calls[1].callback({
		{ name = "tokio", latest_version = "1.53.2" },
		{ name = "toml", latest_version = "1.1.6+spec-1.1.0" },
		{ name = "to", latest_version = "0.0.0" },
		{ name = "serde" },
	}, nil)

	eq(
		ranked(responses[#responses]),
		{ "to", "tokio", "toml", "serde" },
		"The exact name comes first; within a tier the registry's order is kept"
	)

	local by_label = {}

	for _, item in ipairs(responses[#responses].items) do
		by_label[item.label] = item
	end

	eq(
		by_label.toml.textEdit.newText,
		'toml = "1.1.6"',
		"Build metadata must not be written into a requirement"
	)

	eq(
		by_label.serde.textEdit.newText,
		"serde",
		"A crate whose release is unknown must be written by name alone"
	)

	-- What is written depends on where the name is.
	local function written(fixture)
		local own_source, own_backend = new_source()
		local own_responses = complete(own_source, fixture)

		run_deferred()

		own_backend.calls[1].callback({
			{ name = "serde_json", latest_version = "1.0.151" },
		}, nil)

		return own_responses[#own_responses].items[1].textEdit.newText
	end

	eq(
		written('[dependencies]\nserde_j| = "1"'),
		"serde_json",
		"A name with something after it on the line must be replaced alone"
	)

	eq(
		written("[dependencies]\n  serde_j|   "),
		'serde_json = "1.0.151"',
		"Trailing whitespace does not count as something on the line"
	)

	eq(
		written("[dependencies.serde_j|"),
		"serde_json",
		"In a table header only the name is written"
	)

	eq(
		written('[dependencies]\njson = { package = "serde_j|" }'),
		"serde_json",
		"As a package rename only the name is written"
	)

	-- A failing search still answers, once.
	source, backend = new_source()

	responses = complete(source, "[dependencies]\nserde|")

	run_deferred()

	backend.calls[1].callback({}, "HTTP 429")

	eq(
		{ #responses, #responses[1].items },
		{ 1, 0 },
		"A failed search must produce a single empty response"
	)

	-- Cancelled during the debounce.
	source, backend = new_source()

	local cancel

	cancel = select(2, complete(source, "[dependencies]\nserde|"))

	cancel()
	run_deferred()

	eq(#backend.calls, 0, "A superseded search must not reach the registry")

	--------------------------------------------------------------------------------
	-- VERSIONS
	--------------------------------------------------------------------------------

	eq(
		Cargo.debug_sort_versions({
			{ value = "1.9.0" },
			{ value = "2.0.0-rc.1" },
			{ value = "1.10.0" },
			{ value = "2.0.0-alpha.1" },
			{ value = "0.9.0" },
		}),
		{
			{ value = "1.10.0" },
			{ value = "1.9.0" },
			{ value = "0.9.0" },
			{ value = "2.0.0-rc.1" },
			{ value = "2.0.0-alpha.1" },
		},
		"Every release must come before every prerelease, each highest first"
	)

	eq(Cargo.debug_sort_versions({}), {}, "Sorting nothing must yield nothing")

	source, backend = new_source()

	responses = complete(source, '[dependencies]\ntokio = { version = "1.|", features = ["rt"] }')

	eq(delays, { Util.DEBOUNCE_MS }, "A version lookup must use the ordinary debounce")

	run_deferred()

	eq(
		{ backend.calls[1].operation, backend.calls[1].argument },
		{ "versions", { name = "tokio" } },
		"The registry must be asked for the crate's versions"
	)

	backend.calls[1].callback({
		{ value = "1.0.0", timestamp = 0 },
		{ value = "1.2.0", timestamp = 0 },
		{ value = "1.3.0", timestamp = 0, yanked = true },
		{ value = "2.0.0-rc.1", timestamp = 0 },
		{ value = "1.10.0", timestamp = 0 },
	}, nil)

	local versions = responses[#responses]

	eq(
		labels(versions),
		{ "1.10.0", "1.2.0", "1.0.0", "2.0.0-rc.1" },
		"Releases come first, the prerelease last, and the yanked release not at all"
	)

	eq(
		{
			versions.items[1].labelDetails.description,
			versions.items[4].labelDetails.description,
		},
		{ "tokio", "prerelease" },
		"A prerelease must be labelled as one"
	)

	eq(
		versions.items[1].textEdit,
		{
			newText = "1.10.0",
			range = {
				start = { line = 1, character = #'tokio = { version = "' },
				["end"] = { line = 1, character = #'tokio = { version = "1.' },
			},
		},
		"Accepting a version must replace what was typed of it"
	)

	eq(versions.is_incomplete_forward, false, "The last registry answering must close the request")

	-- A second request is served from the session cache.
	complete(source, '[dependencies]\ntokio = "|"')

	eq(#deferred, 0, "A cached version list must not start another lookup")

	-- Operators stay; only the version is replaced.
	source, backend = new_source()

	responses = complete(source, '[dependencies]\ntokio = ">=1.2, <1.|"')

	run_deferred()

	backend.calls[1].callback({
		{ value = "1.10.0", timestamp = 0 },
	}, nil)

	eq(
		responses[#responses].items[1].textEdit.range.start.character,
		#'tokio = ">=1.2, <',
		"With a comparator in front, only the version after it is replaced"
	)

	-- A renamed package is looked up by its real name.
	source, backend = new_source()

	complete(source, '[dependencies]\njson = { version = "|", package = "serde_json" }')

	run_deferred()

	eq(
		backend.calls[1].argument,
		{ name = "serde_json" },
		"Versions must be those of the renamed package, not of the local name"
	)

	--------------------------------------------------------------------------------
	-- FEATURES
	--------------------------------------------------------------------------------

	source, backend = new_source()

	responses = complete(
		source,
		'[dependencies]\ntokio = { version = "1", features = ["rt", "ma|", "net"] }'
	)

	run_deferred()

	eq(
		{ backend.calls[1].operation, backend.calls[1].argument },
		{ "features", { name = "tokio" } },
		"The registry must be asked for the crate's features"
	)

	backend.calls[1].callback({ "default", "full", "macros", "net", "rt", "rt-multi-thread", "macros" }, nil)

	local features = responses[#responses]

	eq(
		labels(features),
		{ "full", "macros", "rt-multi-thread" },
		"default and features already listed must not be offered, and none twice"
	)

	eq(
		{
			features.items[2].kind,
			features.items[2].labelDetails.description,
			features.items[2].textEdit,
		},
		{
			Util.KIND.Value,
			"tokio",
			{
				newText = "macros",
				range = {
					start = { line = 1, character = #'tokio = { version = "1", features = ["rt", "' },
					["end"] = { line = 1, character = #'tokio = { version = "1", features = ["rt", "ma' },
				},
			},
		},
		"Accepting a feature must replace what was typed of it"
	)

	-- The string under the cursor is being edited, not already listed.
	source, backend = new_source()

	responses = complete(source, '[dependencies]\ntokio = { version = "1", features = ["macros|"] }')

	run_deferred()

	backend.calls[1].callback({ "macros", "net" }, nil)

	eq(
		labels(responses[#responses]),
		{ "macros", "net" },
		"The feature under the cursor must still be offered"
	)

	-- The version string on the same line is not a listed feature.
	eq(
		Cargo.debug_listed_features(
			{ '[dependencies]', 'x = { version = "full", features = ["rt", ""] }' },
			{ row = 2, col = #'x = { version = "full", features = ["rt", "' }
		),
		{ "rt" },
		"Only strings inside the features array count as listed"
	)

	-- An array spread over lines, in a dependency table of its own.
	local spread = {
		"[dependencies.tokio]",
		'version = "1"',
		"features = [",
		'    "rt",',
		'    "",',
		"    'net',",
		"]",
		"",
		"[dependencies.other]",
		'features = ["elsewhere"]',
	}

	eq(
		Cargo.debug_listed_features(spread, { row = 5, col = 5 }),
		{ "net", "rt" },
		"A multi line array must be read from its key to its closing bracket, and no further"
	)

	-- A failing lookup still answers, once.
	source, backend = new_source()

	responses = complete(source, '[dependencies]\ntokio = { features = ["|"] }')

	run_deferred()

	backend.calls[1].callback({}, "timeout")

	eq(
		{ #responses, #responses[1].items },
		{ 1, 0 },
		"A failed feature lookup must produce a single empty response"
	)

	--------------------------------------------------------------------------------
	-- THROUGH THE UNIFIED SOURCE
	--------------------------------------------------------------------------------

	-- Both registries are switched off, so this never reaches the network
	-- nor the cargo home of whoever runs the suite.
	local unified = Unified.new({
		crates_io = {
			enabled = false,
		},
		cargo_home = {
			enabled = false,
		},
	})

	ok(unified:enabled(), "The unified source must enable itself for Cargo.toml")

	eq(
		unified:get_trigger_characters(),
		{ '"', "'", ".", "-" },
		"Trigger characters must come from the Cargo delegate"
	)

	local delegate = unified.delegates.cargo

	ok(delegate ~= nil, "The Cargo delegate must be created on demand")

	eq(
		delegate.opts.crates_io,
		{ enabled = false },
		"The delegate must receive the user's options"
	)

	eq(
		{ unified.shared_state, delegate.central_cache },
		{},
		"A Cargo delegate must not be given Maven's shared state, nor cause it to be built"
	)

	-- With every registry switched off the request is closed, not left open.
	local closed = {}

	unified:get_completions(place('[dependencies]\ntokio = "|"'), function(result)
		table.insert(closed, result)
	end)

	eq(
		closed[#closed].is_incomplete_forward,
		false,
		"Without any registry a version request must be closed"
	)

	local routed

	unified:resolve({
		label = "serde",
		data = {
			cargo = { kind = "crate", name = "serde" },
		},
	}, function(item)
		routed = item
	end)

	eq(
		routed.documentation.value,
		"**serde**",
		"Resolve must be routed to the Cargo delegate by its data key"
	)

	eq(
		{
			loaded("blink_deps.maven"),
			loaded("blink_deps.coordinates"),
			loaded("blink_deps.central"),
			loaded("blink_deps.local_repository"),
		},
		{ false, false, false, false },
		"A whole Cargo session must never have loaded Maven's modules"
	)

	-- Outside Cargo.toml the delegate stays out of the way.
	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-cargo/notes.toml")

	ok(not plain:enabled(), "The source must not enable itself for another file")

	local ignored = {}

	plain:get_completions(place('[dependencies]\ntokio = "|"'), function(result)
		table.insert(ignored, result)
	end)

	eq(
		{ #ignored, #ignored[1].items, ignored[1].is_incomplete_forward },
		{ 1, 0, false },
		"In another file the request must be closed at once"
	)
end
