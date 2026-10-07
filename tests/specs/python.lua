local Python = require("blink_deps.python")
local Unified = require("blink_deps")
local Util = require("blink_deps.util")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- LOADING
	--
	-- Checked first, before anything else in this spec can load a module.
	--------------------------------------------------------------------------------

	local function others_loaded()
		local loaded = {}

		for _, name in ipairs({
			"blink_deps.maven",
			"blink_deps.coordinates",
			"blink_deps.central",
			"blink_deps.cargo",
			"blink_deps.crates_io",
			"blink_deps.npm",
			"blink_deps.npm_registry",
		}) do
			if package.loaded[name] ~= nil then
				table.insert(loaded, name)
			end
		end

		return loaded
	end

	eq(
		others_loaded(),
		{},
		"Loading the unified source and the Python delegate must not load other ecosystems"
	)

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A real buffer and a real cursor; the registries are hand written.
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

	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-python/requirements.txt")

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

	local function backend(id, capabilities)
		local entry = {
			id = id,
			name = id,
			kind = "test",
			capabilities = capabilities,
			calls = {},
		}

		for operation in pairs(capabilities) do
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

	-- Two registries, as a Python source really has: an index that knows
	-- versions and exact names, and a list that knows popular names.
	local function new_source()
		local source = Python.new({})

		local index = backend("index", { search = true, versions = true })
		local popular = backend("popular", { search = true })

		index.public = true

		source.registry_list = { index, popular }

		return source, index, popular
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

	local function ranked(result)
		local items = vim.deepcopy(result.items)

		table.sort(items, function(left, right)
			if left.score_offset ~= right.score_offset then
				return left.score_offset > right.score_offset
			end

			return left.label < right.label
		end)

		return labels({ items = items })
	end

	--------------------------------------------------------------------------------
	-- SOURCE
	--------------------------------------------------------------------------------

	local plain = Python.new({})

	ok(plain:enabled(), "The source must enable itself for a requirements file")
	eq(plain.ecosystem, "pypi", "The source must declare the pypi ecosystem")

	eq(
		plain:get_trigger_characters(),
		{ "=", ">", "<", "~", "!", ".", "-", "_" },
		"Completing an operator and typing a version or a separated name must trigger completion"
	)

	eq(
		Python.new({}, { opts = { debug = true } }).opts.debug,
		true,
		"Options given through the provider config must be used"
	)

	--------------------------------------------------------------------------------
	-- ROUTING
	--------------------------------------------------------------------------------

	local source, index, popular = new_source()

	local function closed_without_asking(fixture, message)
		local own_source, own_index, own_popular = new_source()
		local own_responses = complete(own_source, fixture)

		eq(
			{
				#own_responses,
				#own_responses[1].items,
				own_responses[1].is_incomplete_forward,
				#own_index.calls + #own_popular.calls,
				#deferred,
			},
			{ 1, 0, false, 0, 0 },
			message
		)
	end

	closed_without_asking("# reque" .. MARK, "A comment must be closed without asking anyone")
	closed_without_asking("-r other" .. MARK, "An option line must be closed without asking anyone")
	closed_without_asking("requests ; python_ver" .. MARK, "A marker must be closed without asking anyone")
	closed_without_asking("requests[sec" .. MARK, "An extra is recognised but not completed yet")

	--------------------------------------------------------------------------------
	-- PROJECT NAMES
	--------------------------------------------------------------------------------

	complete(source, "r" .. MARK)

	eq({ #deferred, #index.calls }, { 0, 0 }, "A single letter must not start a search")

	local responses = complete(source, "flask\nReque" .. MARK)

	eq(delays, { Util.SEARCH_DEBOUNCE_MS }, "A name search must use the longer search debounce")

	run_deferred()

	eq(
		{ index.calls[1].argument, popular.calls[1].argument },
		{ "reque", "reque" },
		"Every registry that can search must be asked for what was typed, lowercased"
	)

	-- The index knows no project called exactly this.
	index.calls[1].callback({}, nil)

	eq(#responses, 0, "The menu must wait for every registry")

	popular.calls[1].callback({
		{ name = "requests", downloads = 1208056002 },
		{ name = "requests-oauthlib", downloads = 20000000 },
		{ name = "types-requests", downloads = 8000000 },
	}, nil)

	local found = responses[1]

	eq(
		ranked(found),
		{ "requests", "requests-oauthlib", "types-requests" },
		"Names starting with what was typed come first, in the list's order"
	)

	eq(
		{ found.items[1].textEdit, found.items[1].kind, found.items[1].labelDetails.description },
		{
			{
				newText = "requests",
				range = {
					start = { line = 1, character = 0 },
					["end"] = { line = 1, character = 5 },
				},
			},
			Util.KIND.Module,
		},
		"Accepting a project must write its name and nothing else"
	)

	local resolved

	source:resolve(found.items[1], function(item)
		resolved = item
	end)

	eq(
		resolved.documentation.value,
		"**requests**\n\n1,208,056,002 downloads last month",
		"Resolving a project must show what is known of it"
	)

	-- An exact name: the index knows the release, the list the downloads.
	source, index, popular = new_source()

	responses = complete(source, "Typing_Extensions" .. MARK)

	run_deferred()

	popular.calls[1].callback({
		{ name = "typing-extensions", downloads = 800000000 },
	}, nil)

	index.calls[1].callback({
		{ name = "typing-extensions", latest_version = "4.16.0" },
	}, nil)

	eq(#responses[1].items, 1, "A project both registries report must be offered once")

	local exact = responses[1].items[1]

	eq(
		{ exact.label, exact.labelDetails.description, exact.data.pypi },
		{
			"typing-extensions",
			"4.16.0",
			{
				kind = "project",
				name = "typing-extensions",
				latest_version = "4.16.0",
				downloads = 800000000,
			},
		},
		"What one registry knows and another does not must be combined"
	)

	ok(
		exact.score_offset > 10000,
		"A name differing only in case and separators is an exact match"
	)

	source:resolve(exact, function(item)
		resolved = item
	end)

	eq(
		resolved.documentation.value,
		"**typing-extensions** `4.16.0`\n\n800,000,000 downloads last month",
		"The combined details must reach the documentation"
	)

	source:resolve({ label = "x" }, function(item)
		resolved = item
	end)

	eq(resolved, { label = "x" }, "An item that is not a project must pass through unchanged")

	-- One registry failing leaves the other's answer standing.
	source, index, popular = new_source()

	responses = complete(source, "reque" .. MARK)

	run_deferred()

	popular.calls[1].callback({}, "curl: (6) Could not resolve host")
	index.calls[1].callback({ { name = "reque", latest_version = "0.1" } }, nil)

	eq(labels(responses[1]), { "reque" }, "A failing registry must not discard what the other returned")

	--------------------------------------------------------------------------------
	-- VERSION ORDER
	--------------------------------------------------------------------------------

	eq(
		Python.debug_sort_versions({
			{ value = "1.9" },
			{ value = "2.0rc1" },
			{ value = "1.10" },
			{ value = "1.10.post1" },
			{ value = "2.0.dev3" },
			{ value = "0.9" },
		}),
		{
			{ value = "1.10.post1" },
			{ value = "1.10" },
			{ value = "1.9" },
			{ value = "0.9" },
			{ value = "2.0rc1" },
			{ value = "2.0.dev3" },
		},
		"Every release, post releases included, must come before every prerelease"
	)

	--------------------------------------------------------------------------------
	-- VERSIONS
	--------------------------------------------------------------------------------

	local published = {
		{ value = "2.31.0", timestamp = 0, published = "2023-05-22" },
		{ value = "2.32.0", timestamp = 0, yanked = true, published = "2024-05-20" },
		{ value = "2.32.3", timestamp = 0, published = "2024-05-29" },
		{ value = "3.0.0a1", timestamp = 0, published = "2026-01-01" },
		{ value = "2.9.2", timestamp = 0 },
	}

	source, index, popular = new_source()

	responses = complete(source, "Requests_Toolbelt==" .. MARK)

	eq(delays, { Util.DEBOUNCE_MS }, "A version lookup must use the ordinary debounce")

	run_deferred()

	eq(
		{ index.calls[1].operation, index.calls[1].argument, #popular.calls },
		{ "versions", { name = "requests-toolbelt" }, 0 },
		"The index must be asked under the normalised name, and the name list not at all"
	)

	index.calls[1].callback(published, nil)

	local versions = responses[#responses]

	eq(
		labels(versions),
		{ "2.32.3", "2.31.0", "2.9.2", "3.0.0a1" },
		"What pip installs comes first, the prerelease last, and the yanked release not at all"
	)

	local described = {}

	for _, item in ipairs(versions.items) do
		described[item.label] = item.labelDetails.description
	end

	eq(
		described,
		{
			["2.32.3"] = "2024-05-29",
			["2.31.0"] = "2023-05-22",
			["2.9.2"] = "Requests_Toolbelt",
			["3.0.0a1"] = "prerelease",
		},
		"A release shows when it was published, or failing that the project as written"
	)

	eq(
		versions.items[1].textEdit,
		{
			newText = "2.32.3",
			range = {
				start = { line = 0, character = #"Requests_Toolbelt==" },
				["end"] = { line = 0, character = #"Requests_Toolbelt==" },
			},
		},
		"A version must be written as it is, after the operator"
	)

	-- Different spellings of a project share one cached list.
	complete(source, "requests.toolbelt>=" .. MARK)

	eq(#deferred, 0, "Another spelling of the same project must be served from the session cache")

	-- Only the clause being typed is replaced.
	local function version_start(line)
		local own_source, own_index = new_source()
		local own_responses = complete(own_source, line .. MARK)

		run_deferred()

		own_index.calls[1].callback(published, nil)

		return own_responses[#own_responses].items[1].textEdit.range.start.character
	end

	eq(version_start("requests>=2.31,<"), #"requests>=2.31,<", "Only the last specifier is replaced")
	eq(version_start("requests >= 2."), #"requests >= ", "What was typed of the version is replaced")
	eq(version_start("requests[security]~=2."), #"requests[security]~=", "Extras do not get in the way")
	eq(version_start("  requests==2.3"), #"  requests==", "Indentation is left alone")

	--------------------------------------------------------------------------------
	-- THROUGH THE UNIFIED SOURCE
	--------------------------------------------------------------------------------

	local unified = Unified.new({
		pypi = { enabled = false },
		pypi_top = { enabled = false },
	})

	ok(unified:enabled(), "The unified source must enable itself for a requirements file")

	eq(
		unified:get_trigger_characters(),
		{ "=", ">", "<", "~", "!", ".", "-", "_" },
		"Trigger characters must come from the Python delegate"
	)

	local delegate = unified.delegates.python

	ok(delegate ~= nil, "The Python delegate must be created on demand")

	eq(
		{ unified.shared_state, delegate.central_cache },
		{},
		"A Python delegate must not be given Maven's shared state, nor cause it to be built"
	)

	local closed = {}

	unified:get_completions(place("requests==" .. MARK), function(result)
		table.insert(closed, result)
	end)

	eq(closed[#closed].is_incomplete_forward, false, "Without any registry a version request must be closed")

	closed = {}

	unified:get_completions(place("reque" .. MARK), function(result)
		table.insert(closed, result)
	end)

	eq(closed[#closed].is_incomplete_forward, false, "Without any registry a name request must be closed")

	local routed

	unified:resolve({
		label = "requests",
		data = {
			pypi = { kind = "project", name = "requests" },
		},
	}, function(item)
		routed = item
	end)

	eq(routed.documentation.value, "**requests**", "Resolve must be routed to the Python delegate")

	eq(others_loaded(), {}, "A whole Python session must never have loaded another ecosystem's modules")

	--------------------------------------------------------------------------------
	-- WHICH FILES
	--------------------------------------------------------------------------------

	for _, name in ipairs({
		"requirements-dev.txt",
		"dev-requirements.txt",
		"constraints.txt",
		"requirements.in",
		"requirements/base.txt",
	}) do
		vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-python/" .. name)

		ok(plain:enabled(), name .. " must be completed")
	end

	for _, name in ipairs({ "MANIFEST.in", "notes.txt", "README.md" }) do
		vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-python/" .. name)

		ok(not plain:enabled(), name .. " must be left alone")
	end

	local ignored = {}

	plain:get_completions(place("requests==" .. MARK), function(result)
		table.insert(ignored, result)
	end)

	eq(
		{ #ignored, #ignored[1].items, ignored[1].is_incomplete_forward },
		{ 1, 0, false },
		"In another file the request must be closed at once"
	)
end
