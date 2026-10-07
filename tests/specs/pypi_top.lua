local Top = require("blink_deps.pypi_top")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- THE LIST
	--------------------------------------------------------------------------------

	local LIST = vim.json.encode({
		last_update = "2026-10-01 12:40:51",
		rows = {
			{ project = "boto3", download_count = 2460723068 },
			{ project = "requests", download_count = 900000000 },
			{ project = "typing-extensions", download_count = 800000000 },
			{ project = "Django", download_count = 30000000 },
			{ project = "requests-oauthlib", download_count = 20000000 },
			{ project = "djangorestframework", download_count = 10000000 },
			{ project = "zope.interface", download_count = 9000000 },
			{ project = "types-requests", download_count = 8000000 },
			{ project = "no-count" },
			{ download_count = 5 },
			{ project = "" },
			{ project = "bad\tname", download_count = 1 },
			"not a row",
		},
	})

	eq(
		Top.read(LIST),
		{
			{ name = "boto3", key = "boto3", downloads = 2460723068 },
			{ name = "requests", key = "requests", downloads = 900000000 },
			{ name = "typing-extensions", key = "typing-extensions", downloads = 800000000 },
			{ name = "Django", key = "django", downloads = 30000000 },
			{ name = "requests-oauthlib", key = "requests-oauthlib", downloads = 20000000 },
			{ name = "djangorestframework", key = "djangorestframework", downloads = 10000000 },
			{ name = "zope.interface", key = "zope-interface", downloads = 9000000 },
			{ name = "types-requests", key = "types-requests", downloads = 8000000 },
			{ name = "no-count", key = "no-count", downloads = 0 },
		},
		"The list must be read in its published order, with unusable rows dropped"
	)

	eq(Top.read('{"rows":[]}'), {}, "An empty list has no projects")

	for _, body in ipairs({ "", "not json", "[]", '{"projects":[]}', '{"rows":"oops"}' }) do
		local projects, err = Top.read(body)

		eq(projects, nil, "Something that is not a project list must not be read as one")
		ok(type(err) == "string" and err ~= "", "A failed read must say why")
	end

	eq(Top.parse(nil), nil, "A reduction that never came back must not raise")

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- The list is always reduced on a worker thread, which is real, so every
	-- answer has to be waited for.
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

	local function new_source(opts)
		return {
			ecosystem = "pypi",
			opts = vim.tbl_extend("force", {
				cache = {
					enabled = false,
				},
				retries = 0,
			}, opts or {}),
		}
	end

	local function wait(condition)
		vim.wait(5000, condition, 5)
	end

	local registry = Top.REGISTRY

	eq(
		{ registry.id, registry.offline, registry.public, registry.capabilities },
		{ "pypi-top", nil, nil, { search = true } },
		"The list is a remote source that can only search; it is neither the index nor on disk"
	)

	--------------------------------------------------------------------------------
	-- SEARCH
	--------------------------------------------------------------------------------

	install()

	local source = new_source()

	local function search(text, subject)
		local seen = {}

		registry:search(subject or source, text, function(packages, err)
			seen.done = true
			seen.err = err
			seen.names = {}

			for _, package in ipairs(packages) do
				table.insert(seen.names, package.name)
			end

			seen.first = packages[1]
		end)

		return seen
	end

	local first = search("reque")
	local second = search("djan")

	wait(function()
		return #requests > 0
	end)

	eq(#requests, 1, "Concurrent searches must share one download of the list")

	eq(requests[1][#requests[1]], Top.URL, "The published list must be downloaded")

	ok(vim.tbl_contains(requests[1], "--compressed"), "The list must be requested compressed")

	for _, argument in ipairs(requests[1]) do
		ok(
			not argument:find("reque", 1, true) and not argument:find("djan", 1, true),
			"What the user typed must never be part of the request"
		)
	end

	answers[1]({ code = 0, stdout = LIST .. "\n200" })

	wait(function()
		return first.done and second.done
	end)

	eq(
		first.names,
		{ "requests", "requests-oauthlib", "types-requests" },
		"Names starting with the text come first, most downloaded first, then names containing it"
	)

	eq(
		first.first,
		{ name = "requests", downloads = 900000000 },
		"A result carries its name and downloads, and no version"
	)

	eq(second.names, { "Django", "djangorestframework" }, "Matching must ignore case")

	-- From here on the list is in memory and searches answer at once.
	eq(search("typing_ext").names, { "typing-extensions" }, "An underscore must match a hyphen")
	eq(search("zope.int").names, { "zope.interface" }, "A dot must match a dot, a hyphen or an underscore")
	eq(search("zope-int").names, { "zope.interface" }, "A hyphen must match a dot")
	eq(search("BOTO").names, { "boto3" }, "The text is matched whatever its case")
	eq(search("zzz").names, {}, "No match is an empty answer")
	eq(search("  ").names, {}, "An empty search matches nothing")
	eq(search("-").names, {}, "A lone separator matches nothing")
	eq(search("re.ue").names, {}, "The text is matched literally, not as a pattern")

	eq(#requests, 1, "The list must be downloaded once per session")

	-- A result handed out must not be a way to alter the list.
	registry:search(source, "boto", function(packages)
		packages[1].name = "tampered"
	end)

	eq(search("boto").names, { "boto3" }, "A consumer must not be able to corrupt the list")

	--------------------------------------------------------------------------------
	-- BOUNDED RESULTS
	--------------------------------------------------------------------------------

	local rows = {}

	for index = 1, 200 do
		table.insert(rows, { project = "pkg-" .. index, download_count = 1000 - index })
	end

	for index = 1, 200 do
		table.insert(rows, { project = "other-pkg-" .. index, download_count = 500 - index })
	end

	install()

	local crowded = new_source()
	local many = search("pkg", crowded)

	wait(function()
		return #requests > 0
	end)

	answers[1]({ code = 0, stdout = vim.json.encode({ rows = rows }) .. "\n200" })

	wait(function()
		return many.done
	end)

	eq(#many.names, Top.MAX_RESULTS, "The number of results must be bounded")

	eq(
		{ many.names[1], many.names[Top.MAX_RESULTS] },
		{ "pkg-1", "pkg-" .. Top.MAX_RESULTS },
		"The results kept must be the most downloaded names starting with the text"
	)

	local few = search("pkg-19", crowded)

	eq(
		{ #few.names, few.names[1], few.names[12] },
		{ 22, "pkg-19", "other-pkg-19" },
		"Names containing the text fill what the ones starting with it leave"
	)

	--------------------------------------------------------------------------------
	-- FAILURES
	--------------------------------------------------------------------------------

	install()

	local failing = new_source()
	local failed = search("reque", failing)

	wait(function()
		return #requests > 0
	end)

	answers[1]({ code = 6, stderr = "curl: (6) Could not resolve host" })

	wait(function()
		return failed.done
	end)

	eq(
		{ failed.names, failed.err },
		{ {}, "curl: (6) Could not resolve host" },
		"An unreachable list must answer with nothing and the error"
	)

	local retried = search("reque", failing)

	wait(function()
		return #requests > 1
	end)

	eq(#requests, 2, "A failed download must not be cached")

	answers[2]({ code = 0, stdout = "<html>moved</html>\n200" })

	wait(function()
		return retried.done
	end)

	eq(
		retried.err,
		"unreadable project list: not a project list",
		"Something that is not the list must be reported, not read as an empty one"
	)

	--------------------------------------------------------------------------------
	-- CONFIG
	--------------------------------------------------------------------------------

	install()

	search("reque", new_source({ pypi_top = { url = "https://mirror.company.test/top.json" } }))

	wait(function()
		return #requests > 0
	end)

	eq(
		requests[1][#requests[1]],
		"https://mirror.company.test/top.json",
		"A configured address must be used"
	)

	eq(Top.is_enabled(new_source({ pypi_top = { enabled = false } })), false, "The list must be switchable off")
	eq(Top.is_enabled({ opts = {} }), true, "The list must be enabled by default")

	--------------------------------------------------------------------------------
	-- PERSISTENCE
	--------------------------------------------------------------------------------

	install()

	local dir = vim.fn.tempname()

	local cache = {
		enabled = true,
		dir = dir,
	}

	local stored = search("reque", new_source({ cache = cache }))

	wait(function()
		return #requests > 0
	end)

	answers[1]({ code = 0, stdout = LIST .. "\n200" })

	wait(function()
		return stored.done
	end)

	local later = search("reque", new_source({ cache = cache }))

	eq(#requests, 1, "The list must be served from disk in a later session")
	eq(later.names, stored.names, "A persisted list must give the same results")

	vim.fn.delete(dir, "rf")
end
