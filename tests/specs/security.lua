local Osv = require("blink_deps.osv")
local Security = require("blink_deps.security")
local Unified = require("blink_deps")
local Util = require("blink_deps.util")
local VersionCompletion = require("blink_deps.version_completion")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- HARNESS
	--------------------------------------------------------------------------------

	local requests
	local answers

	local function install()
		requests = {}
		answers = {}

		rawset(vim, "system", function(cmd, _, on_exit)
			table.insert(requests, vim.deepcopy(cmd))
			table.insert(answers, on_exit)
			return {}
		end)
	end

	local function wait(condition)
		vim.wait(5000, condition, 5)
	end

	local function options(enabled)
		return {
			cache = { enabled = false },
			retries = 0,
			security = { enabled = enabled },
		}
	end

	local function new_source(enabled, ecosystem)
		return {
			ecosystem = ecosystem or "pypi",
			opts = options(enabled),
		}
	end

	-- What OSV really answers for one vulnerability: a GitHub record and an
	-- ecosystem record of the same thing, each naming the other.
	local function answer(name)
		local function affected(fixed)
			return {
				{
					package = { ecosystem = "PyPI", name = name },
					ranges = {
						{ type = "ECOSYSTEM", events = { { introduced = "0" }, { fixed = fixed } } },
					},
				},
			}
		end

		return {
			code = 0,
			stdout = vim.json.encode({
				vulns = {
					{
						id = "GHSA-9wx4-h78v-vm56",
						summary = "Session does not verify\n  after verify=False",
						aliases = { "CVE-2024-35195", "PYSEC-2026-1873" },
						database_specific = { severity = "MODERATE" },
						affected = affected("2.32.0"),
					},
					{
						id = "PYSEC-2026-1873",
						aliases = { "CVE-2024-35195", "GHSA-9wx4-h78v-vm56" },
						affected = affected("2.32.0"),
					},
					{
						id = "GHSA-crit-crit-crit",
						summary = "Remote code execution",
						aliases = {},
						database_specific = { severity = "CRITICAL" },
						affected = affected("2.20.0"),
					},
				},
			}) .. "\n200",
		}
	end

	--------------------------------------------------------------------------------
	-- ONE VULNERABILITY, RECORDED TWICE
	--------------------------------------------------------------------------------

	local twice = Osv.judge({
		{
			id = "GHSA-1",
			summary = "From GitHub",
			severity = "high",
			aliases = { "CVE-2024-1", "PYSEC-1" },
			versions = { "1.0" },
			ranges = {},
		},
		{
			id = "PYSEC-1",
			aliases = { "CVE-2024-1", "GHSA-1" },
			versions = {},
			ranges = { { { kind = "introduced", version = "0" }, { kind = "fixed", version = "1.1" } } },
		},
		{
			-- Connected only through the CVE both name.
			id = "OSV-9",
			aliases = { "CVE-2024-1" },
			versions = { "1.0" },
			ranges = {},
		},
		{
			id = "GHSA-2",
			summary = "Something else",
			aliases = { "CVE-2024-2" },
			versions = { "1.0" },
			ranges = {},
		},
	}, "pypi")

	eq(
		twice("1.0"),
		{
			{
				id = "GHSA-1",
				summary = "From GitHub",
				severity = "high",
				fixed = "1.1",
				aliases = { "CVE-2024-1", "PYSEC-1", "OSV-9" },
			},
			{
				id = "GHSA-2",
				summary = "Something else",
				aliases = { "CVE-2024-2" },
			},
		},
		"Records naming each other or the same CVE are one finding, combining what each knows"
	)

	ok(twice("1.0") == twice("1.0"), "A version already judged must not be judged again")

	--------------------------------------------------------------------------------
	-- WORDING
	--------------------------------------------------------------------------------

	eq(Security.note({}), nil, "No findings means no note")
	eq(Security.note(nil), nil, "Unknown findings mean no note")
	eq(Security.note({ {} }), "1 vulnerability", "One finding is singular")
	eq(Security.note({ {}, {}, {} }), "3 vulnerabilities", "Several findings are counted")

	eq(
		Security.document("requests", "2.31.0", {}),
		"**requests** `2.31.0`\n\nNo known vulnerabilities.",
		"A clean version must say so"
	)

	eq(
		Security.document("requests", "2.31.0", {
			{ id = "PYSEC-5", aliases = {} },
			{
				id = "GHSA-low",
				severity = "low",
				summary = "Minor",
				fixed = "2.31.1",
				aliases = { "PYSEC-7" },
			},
			{
				id = "GHSA-crit",
				severity = "critical",
				summary = "Remote  code\nexecution",
				fixed = "2.32.0",
				aliases = { "CVE-2024-9", "PYSEC-8", "CVE-2024-10" },
			},
		}),
		table.concat({
			"**requests** `2.31.0`",
			"",
			"3 known vulnerabilities",
			"",
			"- **GHSA-crit** (critical) Remote code execution",
			"  Fixed in `2.32.0` · CVE-2024-9 · CVE-2024-10",
			"- **GHSA-low** (low) Minor",
			"  Fixed in `2.31.1`",
			"- **PYSEC-5**",
			"  No fixed version recorded",
		}, "\n"),
		"Findings must be listed most severe first, one line each, with the fix and the CVE"
	)

	eq(
		Security.document("x", "1.0", { { id = "A", aliases = {} } }):match("\n\n([^\n]+)\n"),
		"1 known vulnerability",
		"A single finding is singular in the documentation too"
	)

	--------------------------------------------------------------------------------
	-- OFF BY DEFAULT
	--------------------------------------------------------------------------------

	install()

	local off = new_source(false)

	Security.watch(off, { name = "requests" })

	eq(#requests, 0, "Nothing must be looked up unless security lookups are on")
	eq(Security.judge(off, { name = "requests" }), nil, "Nothing is judged while lookups are off")
	eq(Security.item_data(off, { name = "requests" }, "1.0", "requests"), nil, "Items carry nothing while lookups are off")

	--------------------------------------------------------------------------------
	-- WATCH AND JUDGE
	--------------------------------------------------------------------------------

	install()

	local on = new_source(true)

	eq(Security.judge(on, { name = "requests" }), nil, "Nothing is known before a lookup")

	Security.watch(on, { name = "requests" })
	Security.watch(on, { name = "requests" })

	eq(#requests, 1, "Watching a package twice must look it up once")
	eq(Security.judge(on, { name = "requests" }), nil, "Nothing is known until the answer arrives")

	answers[1](answer("requests"))

	wait(function()
		return Security.judge(on, { name = "requests" }) ~= nil
	end)

	local judge = Security.judge(on, { name = "requests" })

	eq(
		{ #judge("2.31.0"), #judge("2.19.0"), #judge("2.32.0") },
		{ 1, 2, 0 },
		"Once known, versions are judged, with the duplicate record counted once"
	)

	ok(
		Security.judge(on, { name = "requests" }) == judge,
		"The judge of a package must be reused while its advisories are the same"
	)

	eq(
		Security.item_data(on, { name = "requests", extra = "ignored" }, "2.31.0", "Requests"),
		{
			deps_version = {
				ecosystem = "pypi",
				package = { name = "requests" },
				version = "2.31.0",
				label = "Requests",
			},
		},
		"A version item must carry what its documentation needs, and nothing else"
	)

	-- A delegate without an ecosystem of its own is a Maven one.
	local maven = { opts = options(true) }

	local maven_package = { namespace = "org.example", name = "demo" }

	eq(
		Security.item_data(maven, maven_package, "1.0", "org.example:demo").deps_version.ecosystem,
		"maven",
		"A source that names no ecosystem is a Maven source"
	)

	-- A failed lookup leaves nothing known and does not raise.
	install()

	local failing = new_source(true)

	Security.watch(failing, { name = "requests" })

	answers[1]({ code = 6, stderr = "curl: (6) Could not resolve host" })

	wait(function()
		return failing.osv_pipeline:stats().errors > 0
	end)

	eq(Security.judge(failing, { name = "requests" }), nil, "A failed lookup must leave versions unmarked")

	--------------------------------------------------------------------------------
	-- IN A VERSION LIST
	--------------------------------------------------------------------------------

	local deferred = {}

	rawset(Util, "defer", function(_, fn)
		table.insert(deferred, fn)
	end)

	local function complete(source, registry)
		source.registry_list = { registry }

		local responses = {}

		VersionCompletion.complete(source, {
			get_pos = function()
				return { row = 0, col = 0 }
			end,
		}, { value = "" }, function(result)
			table.insert(responses, result)
		end, {
			package = { name = "requests" },
			key = "requests",
			label = "Requests",
			catalog = source.catalog,
			sort = function(entries)
				table.sort(entries, function(left, right)
					return left.value > right.value
				end)

				return entries
			end,
			describe = function(version)
				return version.published
			end,
		})

		local pending = deferred

		deferred = {}

		for _, fn in ipairs(pending) do
			fn()
		end

		return responses
	end

	local function registry_with(versions)
		return {
			id = "index",
			name = "index",
			kind = "test",
			public = true,
			capabilities = { versions = true },
			versions = function(_, _, _, callback)
				callback(vim.deepcopy(versions), nil)
			end,
		}
	end

	local published = {
		{ value = "2.19.0", timestamp = 0 },
		{ value = "2.31.0", timestamp = 0, published = "2023-05-22" },
		{ value = "2.32.0", timestamp = 0 },
	}

	local function described(result)
		local map = {}

		for _, item in ipairs(result.items) do
			map[item.label] = item.labelDetails.description
		end

		return map
	end

	-- Off: the list is exactly what it was before this feature existed.
	install()

	local plain = new_source(false)

	plain.catalog = {}

	local plain_responses = complete(plain, registry_with(published))
	local plain_final = plain_responses[#plain_responses]

	eq(#requests, 0, "With lookups off a version list must not cause one")

	eq(
		{ described(plain_final), plain_final.items[1].data },
		{ { ["2.19.0"] = "Requests", ["2.31.0"] = "2023-05-22", ["2.32.0"] = "Requests" } },
		"With lookups off, versions carry no note and no data"
	)

	-- On: the list arrives without waiting, the notes follow.
	install()

	local watched = new_source(true)

	watched.catalog = {}

	local first = complete(watched, registry_with(published))

	eq(#requests, 1, "A version list must start a lookup for its package")

	eq(
		described(first[#first]),
		{ ["2.19.0"] = "Requests", ["2.31.0"] = "2023-05-22", ["2.32.0"] = "Requests" },
		"The list must be shown at once, unmarked, while the lookup is still out"
	)

	eq(
		first[#first].items[1].data.deps_version,
		{
			ecosystem = "pypi",
			package = { name = "requests" },
			version = "2.32.0",
			label = "Requests",
		},
		"Each version must carry what its documentation needs"
	)

	answers[1](answer("requests"))

	wait(function()
		return Security.judge(watched, { name = "requests" }) ~= nil
	end)

	local second = complete(watched, registry_with(published))

	eq(#requests, 1, "The next request must use the answer, not ask again")

	eq(
		described(second[#second]),
		{
			["2.19.0"] = "Requests · 2 vulnerabilities",
			["2.31.0"] = "2023-05-22 · 1 vulnerability",
			["2.32.0"] = "Requests",
		},
		"Once the answer is in, affected versions are marked next to what was already shown"
	)

	eq(
		{ second[#second].items[1].label, second[#second].items[3].label },
		{ "2.32.0", "2.19.0" },
		"Marking a version must not change the order of the list"
	)

	--------------------------------------------------------------------------------
	-- DOCUMENTATION
	--------------------------------------------------------------------------------

	local item = {
		label = "2.31.0",
		data = Security.item_data(watched, { name = "requests" }, "2.31.0", "Requests"),
	}

	ok(Security.handles(item), "A version item must be recognised")
	ok(not Security.handles({ label = "x" }), "An item without data is not a version item")
	ok(not Security.handles({ data = { npm = {} } }), "Another kind of item is not a version item")
	ok(not Security.handles({ data = { deps_version = {} } }), "An incomplete version item is not handled")

	-- Through the unified source, in a fresh session: the documentation
	-- waits for the lookup.
	install()

	local unified = Unified.new(options(true))
	local resolved

	unified:resolve(item, function(result)
		resolved = result
	end)

	eq(resolved, nil, "Documentation must wait for the lookup")
	eq(#requests, 1, "Asking for documentation must look the package up")

	answers[1](answer("requests"))

	wait(function()
		return resolved ~= nil
	end)

	eq(
		resolved.documentation,
		{
			kind = "markdown",
			value = table.concat({
				"**Requests** `2.31.0`",
				"",
				"1 known vulnerability",
				"",
				"- **GHSA-9wx4-h78v-vm56** (moderate) Session does not verify after verify=False",
				"  Fixed in `2.32.0` · CVE-2024-35195",
			}, "\n"),
		},
		"A version's documentation must list what affects it"
	)

	eq(item.documentation, nil, "Resolving must not alter the item it was given")

	-- Asked again: answered from what is known.
	local again

	unified:resolve(
		{ label = "2.32.0", data = Security.item_data(watched, { name = "requests" }, "2.32.0", "Requests") },
		function(result)
			again = result
		end
	)

	eq(#requests, 1, "A second version of the same package must not cause another lookup")

	eq(
		again.documentation.value,
		"**Requests** `2.32.0`\n\nNo known vulnerabilities.",
		"A version nothing affects must say so"
	)

	eq(
		unified:pipelines()[1]:stats().name,
		"osv",
		"The lookups must be visible in the unified source's diagnostics"
	)

	-- A failed lookup leaves the item without documentation.
	install()

	local broken = Unified.new(options(true))
	local unresolved

	broken:resolve(item, function(result)
		unresolved = result
	end)

	answers[1]({ code = 6, stderr = "curl: (6) Could not resolve host" })

	wait(function()
		return unresolved ~= nil
	end)

	eq(unresolved.documentation, nil, "A failed lookup must not invent documentation")

	-- Lookups switched off after the item was made.
	install()

	local disabled

	Unified.new(options(false)):resolve(item, function(result)
		disabled = result
	end)

	eq(
		{ disabled.label, disabled.documentation, #requests },
		{ "2.31.0", nil, 0 },
		"With lookups off an item passes through without a request"
	)

	-- Other items still reach their delegates.
	local other

	unified:resolve({ label = "x" }, function(result)
		other = result
	end)

	eq(other, { label = "x" }, "An item that is not a version must be resolved as before")
end
