local Osv = require("blink_deps.osv")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- OFF BY DEFAULT
	--------------------------------------------------------------------------------

	eq(Osv.is_enabled({ opts = {} }), false, "Security lookups must be off unless asked for")
	eq(Osv.is_enabled({ opts = { security = {} } }), false, "An empty security option does not turn them on")
	eq(Osv.is_enabled({ opts = { security = { enabled = "yes" } } }), false, "Only true turns them on")
	eq(Osv.is_enabled({ opts = { security = { enabled = true } } }), true, "They must be switchable on")

	--------------------------------------------------------------------------------
	-- NAMING A PACKAGE
	--------------------------------------------------------------------------------

	local function identify(ecosystem, package)
		return { Osv.identify(ecosystem, package) }
	end

	eq(
		identify("maven", { namespace = "org.springframework", name = "spring-core" }),
		{ "Maven", "org.springframework:spring-core" },
		"A Maven package is named groupId:artifactId"
	)

	eq(identify("cargo", { name = "tokio" }), { "crates.io", "tokio" }, "A crate is looked up on crates.io")
	eq(identify("npm", { name = "@types/node" }), { "npm", "@types/node" }, "An npm package keeps its scope")

	eq(
		identify("pypi", { name = "Typing_Extensions" }),
		{ "PyPI", "typing-extensions" },
		"A Python project is named as an index spells it"
	)

	eq(identify("unknown", { name = "x" }), {}, "An unknown ecosystem is not looked up")
	eq(identify("maven", { name = "no-group" }), {}, "A Maven package without a group cannot be named")
	eq(identify("npm", nil), {}, "A missing package cannot be named")
	eq(identify("npm", {}), {}, "A package without a name cannot be named")

	--------------------------------------------------------------------------------
	-- READING A RESPONSE
	--------------------------------------------------------------------------------

	local RESPONSE = vim.json.encode({
		vulns = {
			{
				id = "GHSA-aaaa-bbbb-cccc",
				summary = "Request smuggling",
				aliases = { "CVE-2024-0001", "PYSEC-2024-1" },
				database_specific = { severity = "HIGH" },
				affected = {
					{
						package = { ecosystem = "PyPI", name = "Demo.Pkg" },
						versions = { "1.0", "1.1" },
						ranges = {
							{
								type = "ECOSYSTEM",
								events = { { introduced = "0" }, { fixed = "1.2" } },
							},
							{
								type = "GIT",
								repo = "https://github.com/x/y",
								events = { { introduced = "0" }, { fixed = "abc123" } },
							},
						},
					},
					-- The same advisory, about another package.
					{
						package = { ecosystem = "PyPI", name = "other" },
						versions = { "9.9" },
					},
					-- And about a package of the same name elsewhere.
					{
						package = { ecosystem = "npm", name = "demo-pkg" },
						versions = { "7.7" },
					},
				},
			},
			{
				id = "GHSA-withdrawn",
				withdrawn = "2024-01-01T00:00:00Z",
				affected = {
					{ package = { ecosystem = "PyPI", name = "demo-pkg" }, versions = { "1.0" } },
				},
			},
			{
				id = "PYSEC-2023-9",
				affected = {
					{
						package = { ecosystem = "PyPI", name = "demo-pkg" },
						ecosystem_specific = { severity = "Moderate" },
						ranges = {
							{
								type = "ECOSYSTEM",
								events = {
									{ introduced = "2.0" },
									{ last_affected = "2.3" },
									{ limit = "3.0" },
									"not an event",
								},
							},
						},
					},
				},
			},
			{
				id = "GHSA-elsewhere",
				affected = {
					{ package = { ecosystem = "PyPI", name = "unrelated" }, versions = { "1.0" } },
				},
			},
			{ summary = "no id" },
			"not an advisory",
		},
		next_page_token = "page-2",
	})

	eq(
		Osv.read("PyPI", "demo-pkg", RESPONSE),
		{
			advisories = {
				{
					id = "GHSA-aaaa-bbbb-cccc",
					summary = "Request smuggling",
					severity = "high",
					aliases = { "CVE-2024-0001", "PYSEC-2024-1" },
					versions = { "1.0", "1.1" },
					ranges = {
						{
							{ kind = "introduced", version = "0" },
							{ kind = "fixed", version = "1.2" },
						},
					},
				},
				{
					id = "PYSEC-2023-9",
					severity = "moderate",
					aliases = {},
					versions = {},
					ranges = {
						{
							{ kind = "introduced", version = "2.0" },
							{ kind = "last_affected", version = "2.3" },
						},
					},
				},
			},
			next_page_token = "page-2",
		},
		"A response must reduce to the advisories about this package, in this ecosystem"
	)

	eq(
		Osv.read("PyPI", "demo-pkg", "{}"),
		{ advisories = {} },
		"A package nothing is known about is an empty object, and an empty answer"
	)

	eq(
		#Osv.read("npm", "demo-pkg", RESPONSE).advisories,
		1,
		"The same response read for another ecosystem keeps that ecosystem's part"
	)

	for _, body in ipairs({ "", "not json", "[]x", '{"vulns":"oops"}', "<html>blocked</html>" }) do
		local parsed, err = Osv.read("PyPI", "demo-pkg", body)

		eq(parsed, nil, "Something that is not an OSV response must not be read as one")
		ok(type(err) == "string" and err ~= "", "A failed read must say why")
	end

	eq(Osv.parse(nil), nil, "A reduction that never came back must not raise")

	--------------------------------------------------------------------------------
	-- JUDGING A VERSION
	--------------------------------------------------------------------------------

	local function ids(found)
		local list = {}

		for _, advisory in ipairs(found) do
			table.insert(list, advisory.id .. (advisory.fixed and (" -> " .. advisory.fixed) or ""))
		end

		return list
	end

	local advisories = {
		{
			id = "A",
			summary = "Listed and ranged",
			severity = "high",
			aliases = { "CVE-1" },
			versions = { "1.0.0", "1.1.0" },
			ranges = {
				{
					{ kind = "introduced", version = "0" },
					{ kind = "fixed", version = "1.2.0" },
				},
			},
		},
		{
			-- Two separate stretches in one range.
			id = "B",
			aliases = {},
			versions = {},
			ranges = {
				{
					{ kind = "introduced", version = "2.0.0" },
					{ kind = "fixed", version = "2.0.5" },
					{ kind = "introduced", version = "2.5.0" },
					{ kind = "fixed", version = "2.6.0" },
				},
			},
		},
		{
			-- No fix: affected up to and including a version.
			id = "C",
			aliases = {},
			versions = {},
			ranges = {
				{
					{ kind = "introduced", version = "3.0.0" },
					{ kind = "last_affected", version = "3.2.0" },
				},
			},
		},
		{
			-- Only an explicit list.
			id = "D",
			aliases = {},
			versions = { "9.9.9" },
			ranges = {},
		},
	}

	local judge = Osv.judge(advisories, "npm")

	for version, expected in pairs({
		["0.5.0"] = { "A -> 1.2.0" },
		["1.1.0"] = { "A -> 1.2.0" },
		["1.2.0"] = {},
		["1.9.0"] = {},
		["2.0.0"] = { "B -> 2.0.5" },
		["2.0.4"] = { "B -> 2.0.5" },
		["2.0.5"] = {},
		["2.4.9"] = {},
		["2.5.0"] = { "B -> 2.6.0" },
		["2.6.0"] = {},
		["3.0.0"] = { "C" },
		["3.2.0"] = { "C" },
		["3.2.1"] = {},
		["9.9.9"] = { "D" },
	}) do
		eq(ids(judge(version)), expected, version .. " must be judged correctly")
	end

	eq(
		judge("1.0.0")[1],
		{
			id = "A",
			summary = "Listed and ranged",
			severity = "high",
			aliases = { "CVE-1" },
			fixed = "1.2.0",
		},
		"A finding must carry what there is to show about it"
	)

	eq(judge(""), {}, "An empty version is affected by nothing")
	eq(judge(nil), {}, "A missing version is affected by nothing")

	eq(
		ids(Osv.affecting(advisories, "npm", "2.5.3")),
		{ "B -> 2.6.0" },
		"A single version can be judged without building a judge first"
	)

	eq(Osv.affecting(advisories, "unknown", "1.0.0"), {}, "An unknown ecosystem has no findings")
	eq(Osv.affecting({}, "npm", "1.0.0"), {}, "No advisories means no findings")
	eq(Osv.affecting(nil, "npm", "1.0.0"), {}, "Missing advisories must not raise")

	-- Each ecosystem orders versions by its own rules.
	local boundary = {
		{
			id = "X",
			aliases = {},
			versions = {},
			ranges = {
				{
					{ kind = "introduced", version = "0" },
					{ kind = "fixed", version = "1.10" },
				},
			},
		},
	}

	eq(
		#Osv.affecting(boundary, "pypi", "1.9"),
		1,
		"1.9 is below 1.10 as versions, though not as text"
	)

	eq(#Osv.affecting(boundary, "pypi", "1.10rc1"), 1, "A release candidate is below its release")
	eq(#Osv.affecting(boundary, "pypi", "1.10.post1"), 0, "A post release is above its release")
	eq(#Osv.affecting(boundary, "pypi", "1.10.0"), 0, "Another spelling of the fixed version is fixed")

	local qualified = {
		{
			id = "Y",
			aliases = {},
			versions = {},
			ranges = {
				{
					{ kind = "introduced", version = "5.3.0" },
					{ kind = "fixed", version = "5.3.20" },
				},
			},
		},
	}

	eq(#Osv.affecting(qualified, "maven", "5.3.9.RELEASE"), 1, "A Maven qualifier does not hide a version in range")
	eq(#Osv.affecting(qualified, "maven", "5.3.20"), 0, "The fixed Maven version is not affected")
	eq(#Osv.affecting(qualified, "cargo", "5.3.20-rc.1"), 1, "A semver prerelease is below the release that fixes")

	-- A list of versions is judged quickly: comparisons are remembered.
	local many = {}

	for index = 1, 40 do
		local listed = {}

		for patch = 1, 200 do
			table.insert(listed, "0." .. index .. "." .. patch)
		end

		table.insert(many, {
			id = "M" .. index,
			aliases = {},
			versions = listed,
			ranges = {
				{
					{ kind = "introduced", version = "0" },
					{ kind = "fixed", version = "1." .. index .. ".0" },
				},
			},
		})
	end

	local started = vim.uv.hrtime()
	local quick = Osv.judge(many, "pypi")
	local findings = 0

	for minor = 1, 200 do
		findings = findings + #quick("1." .. (minor % 50) .. ".5")
	end

	local elapsed = (vim.uv.hrtime() - started) / 1e6

	ok(findings > 0, "The timing run must actually find something")

	ok(
		elapsed < 1000,
		string.format("Judging 200 versions against 40 advisories took %.0f ms; it used to take seconds", elapsed)
	)

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A response is always reduced on a worker thread, which is real, so every
	-- answer has to be waited for.
	--------------------------------------------------------------------------------

	local requests
	local answers

	local function install()
		requests = {}
		answers = {}

		rawset(vim, "system", function(cmd, opts, on_exit)
			table.insert(requests, {
				cmd = vim.deepcopy(cmd),
				stdin = opts and opts.stdin,
			})

			table.insert(answers, on_exit)

			return {}
		end)
	end

	local function new_source(opts)
		return {
			opts = vim.tbl_extend("force", {
				cache = {
					enabled = false,
				},
				retries = 0,
				security = {
					enabled = true,
				},
			}, opts or {}),
		}
	end

	local function wait(condition)
		vim.wait(5000, condition, 5)
	end

	local function body_of(index)
		local cmd = requests[index].cmd

		for position, argument in ipairs(cmd) do
			if argument == "--data-binary" then
				return vim.json.decode(cmd[position + 1])
			end
		end

		return nil
	end

	local function lookup(source, ecosystem, package)
		local seen = {}

		Osv.advisories(source, ecosystem, package, function(found, err)
			seen.done = true
			seen.advisories = found
			seen.err = err
		end)

		return seen
	end

	local function page(vulns, token)
		return {
			code = 0,
			stdout = vim.json.encode({ vulns = vulns, next_page_token = token }) .. "\n200",
		}
	end

	local function advisory(id, name)
		return {
			id = id,
			affected = {
				{ package = { ecosystem = "PyPI", name = name or "demo-pkg" }, versions = { "1.0" } },
			},
		}
	end

	--------------------------------------------------------------------------------
	-- LOOKUP
	--------------------------------------------------------------------------------

	install()

	local source = new_source()

	local first = lookup(source, "pypi", { name = "Demo_Pkg" })
	local second = lookup(source, "pypi", { name = "demo.pkg" })

	eq(#requests, 1, "Different spellings of one package must share a lookup")

	eq(requests[1].cmd[#requests[1].cmd], Osv.URL, "The query endpoint must be asked")

	eq(
		body_of(1),
		{ package = { ecosystem = "PyPI", name = "demo-pkg" } },
		"A lookup must send the ecosystem and the package name, and nothing else"
	)

	ok(
		requests[1].stdin:find("Content-Type: application/json", 1, true) ~= nil,
		"The query must be sent as JSON"
	)

	eq(Osv.known(source, "pypi", { name = "demo-pkg" }), nil, "Nothing is known before the answer arrives")

	-- The same response as its last page. Rebuilt, not edited as text: the
	-- encoder does not promise where in the object the token ends up.
	local last_page = vim.json.decode(RESPONSE)

	last_page.next_page_token = nil

	answers[1]({ code = 0, stdout = vim.json.encode(last_page) .. "\n200" })

	wait(function()
		return first.done and second.done
	end)

	eq(#first.advisories, 2, "Every waiter must receive the advisories")
	eq(first.advisories, second.advisories, "Both waiters must receive the same answer")

	eq(
		#Osv.known(source, "pypi", { name = "Demo-Pkg" }),
		2,
		"After the answer, what is known can be read without asking again"
	)

	lookup(source, "pypi", { name = "demo-pkg" })

	eq(#requests, 1, "A package already looked up must not be asked about again")

	-- Other ecosystems name their packages their own way.
	install()

	lookup(new_source(), "maven", { namespace = "org.example", name = "demo" })
	lookup(new_source(), "cargo", { name = "tokio" })
	lookup(new_source(), "npm", { name = "@scope/demo" })

	eq(
		{ body_of(1).package, body_of(2).package, body_of(3).package },
		{
			{ ecosystem = "Maven", name = "org.example:demo" },
			{ ecosystem = "crates.io", name = "tokio" },
			{ ecosystem = "npm", name = "@scope/demo" },
		},
		"Each ecosystem must be queried under OSV's name for it"
	)

	-- Nothing to ask.
	install()

	local nothing = lookup(new_source(), "unknown", { name = "x" })

	eq(
		{ nothing.done, nothing.advisories, #requests },
		{ true, {}, 0 },
		"An ecosystem OSV is not consulted for must answer at once, without a request"
	)

	--------------------------------------------------------------------------------
	-- PAGES
	--------------------------------------------------------------------------------

	install()

	local paged = lookup(new_source(), "pypi", { name = "demo-pkg" })

	answers[1](page({ advisory("P1") }, "token-2"))

	wait(function()
		return #requests == 2
	end)

	eq(
		body_of(2),
		{ package = { ecosystem = "PyPI", name = "demo-pkg" }, page_token = "token-2" },
		"A further page must be asked for with the token of the one before"
	)

	answers[2](page({ advisory("P2"), advisory("P3") }, nil))

	wait(function()
		return paged.done
	end)

	eq(
		{ paged.advisories[1].id, paged.advisories[2].id, paged.advisories[3].id },
		{ "P1", "P2", "P3" },
		"The advisories of every page must be gathered in order"
	)

	-- A response that never stops offering pages.
	install()

	local endless = lookup(new_source(), "pypi", { name = "demo-pkg" })

	for number = 1, Osv.MAX_PAGES do
		wait(function()
			return #requests == number
		end)

		answers[number](page({ advisory("E" .. number) }, "again"))
	end

	wait(function()
		return endless.done
	end)

	eq(
		{ #requests, #endless.advisories },
		{ Osv.MAX_PAGES, Osv.MAX_PAGES },
		"Paging must stop at the limit, keeping what was read"
	)

	--------------------------------------------------------------------------------
	-- FAILURES
	--------------------------------------------------------------------------------

	install()

	local failing = new_source()
	local failed = lookup(failing, "pypi", { name = "demo-pkg" })

	answers[1]({ code = 28, stderr = "curl: (28) Operation timed out" })

	wait(function()
		return failed.done
	end)

	eq(
		{ failed.advisories, failed.err },
		{ {}, "curl: (28) Operation timed out" },
		"A failed lookup must answer with nothing and the error"
	)

	eq(Osv.known(failing, "pypi", { name = "demo-pkg" }), nil, "A failed lookup must leave nothing known")

	local retried = lookup(failing, "pypi", { name = "demo-pkg" })

	eq(#requests, 2, "A failed lookup must not be cached")

	answers[2]({ code = 0, stdout = "<html>blocked</html>\n200" })

	wait(function()
		return retried.done
	end)

	eq(
		retried.err,
		"unreadable OSV response: not JSON",
		"Something that is not an OSV response must be reported, not read as no advisories"
	)

	--------------------------------------------------------------------------------
	-- CONFIG AND PERSISTENCE
	--------------------------------------------------------------------------------

	install()

	lookup(new_source({ security = { enabled = true, url = "https://osv.company.test/v1/query" } }), "npm", { name = "x" })

	eq(
		requests[1].cmd[#requests[1].cmd],
		"https://osv.company.test/v1/query",
		"A configured endpoint must be used"
	)

	install()

	local dir = vim.fn.tempname()

	local cache = {
		enabled = true,
		dir = dir,
	}

	local stored = lookup(new_source({ cache = cache }), "pypi", { name = "demo-pkg" })

	answers[1](page({ advisory("S1") }, nil))

	wait(function()
		return stored.done
	end)

	local later = lookup(new_source({ cache = cache }), "pypi", { name = "demo-pkg" })

	eq(#requests, 1, "Advisories must be served from disk in a later session")
	eq(later.advisories, stored.advisories, "Persisted advisories must match the fetched ones")

	-- No advisories is worth remembering too.
	local clean = lookup(new_source({ cache = cache }), "pypi", { name = "clean-pkg" })

	answers[2]({ code = 0, stdout = "{}\n200" })

	wait(function()
		return clean.done
	end)

	lookup(new_source({ cache = cache }), "pypi", { name = "clean-pkg" })

	eq(#requests, 2, "A package with no advisories must not be asked about again either")

	vim.fn.delete(dir, "rf")
end
