local Npm = require("blink_deps.npm_registry")
local Registries = require("blink_deps.registries")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- PACKAGE NAMES
	--------------------------------------------------------------------------------

	for _, name in ipairs({
		"react",
		"lodash.merge",
		"ts-node",
		"@types/node",
		"@babel/plugin-transform-runtime",
		"JSONStream",
		"a",
		"under_score",
		"@scope/with.dot_and-dash",
	}) do
		ok(Npm.is_package_name(name), name .. " is a package name")
	end

	for _, name in ipairs({
		"",
		"two words",
		"../etc/passwd",
		"@scope",
		"@scope/",
		"@/name",
		"@scope/name/extra",
		"name/extra",
		".hidden",
		"name?query",
		"name#fragment",
		"@@scope/name",
		string.rep("a", 215),
	}) do
		ok(
			not Npm.is_package_name(name),
			"'" .. name:sub(1, 30) .. "' is not a package name and must not reach the URL"
		)
	end

	ok(not Npm.is_package_name(nil), "A missing name is not a package name")

	--------------------------------------------------------------------------------
	-- PACKAGE DOCUMENTS
	--------------------------------------------------------------------------------

	local DOCUMENT = vim.json.encode({
		name = "demo",
		["dist-tags"] = {
			latest = "1.1.0",
			next = "2.0.0-rc.1",
			legacy = "1.1.0",
		},
		versions = {
			["1.0.0"] = { name = "demo", version = "1.0.0", deprecated = "use 1.1.0" },
			["1.1.0"] = { name = "demo", version = "1.1.0" },
			["2.0.0-rc.1"] = { name = "demo", version = "2.0.0-rc.1", deprecated = "" },
			["0.9.0"] = { name = "demo", version = "0.9.0" },
		},
		modified = "2026-01-01T00:00:00.000Z",
	})

	eq(
		Npm.reduce(DOCUMENT),
		{
			versions = { "0.9.0", "1.0.0", "1.1.0", "2.0.0-rc.1" },
			deprecated = { "1.0.0" },
			tags = {
				latest = "1.1.0",
				next = "2.0.0-rc.1",
				legacy = "1.1.0",
			},
		},
		"A document must reduce to its versions, the deprecated ones and its tags"
	)

	eq(
		Npm.reduce('{"name":"empty","versions":{}}'),
		{ versions = {}, deprecated = {}, tags = {} },
		"A package without versions must reduce to empty lists"
	)

	for _, body in ipairs({
		"",
		"not json",
		"[]",
		'"text"',
		'{"error":"not found"}',
		'{"versions":"oops"}',
	}) do
		local reduced, err = Npm.reduce(body)

		eq(reduced, nil, "Something that is not a package document must not reduce")
		ok(type(err) == "string" and err ~= "", "A failed reduction must say why")
	end

	--------------------------------------------------------------------------------
	-- HARNESS
	--------------------------------------------------------------------------------

	local original_schedule = vim.schedule

	local requests
	local answers

	rawset(vim, "schedule", function(fn)
		fn()
	end)

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
			ecosystem = "npm",
			opts = vim.tbl_extend("force", {
				cache = {
					enabled = false,
				},
				retries = 0,
			}, opts or {}),
		}
	end

	local function url_of(index)
		local cmd = requests[index].cmd

		return cmd[#cmd]
	end

	local function request_for(fragment)
		for index in ipairs(requests) do
			if url_of(index):find(fragment, 1, true) then
				return index
			end
		end

		return nil
	end

	local registry = Npm.REGISTRY

	--------------------------------------------------------------------------------
	-- REGISTRY
	--------------------------------------------------------------------------------

	eq(
		{ registry.id, registry.name, registry.public, registry.offline },
		{ "npm", "npm", true },
		"npm must describe itself as the public registry"
	)

	for capability in pairs(registry.capabilities) do
		ok(
			type(registry[capability]) == "function",
			"npm must implement its declared capability " .. capability
		)
	end

	eq(
		Registries.list(new_source()),
		{ registry },
		"An npm source must use the npm registry"
	)

	eq(
		Registries.list(new_source({ npm = { enabled = false } })),
		{},
		"The npm registry must be removable from an npm source"
	)

	--------------------------------------------------------------------------------
	-- VERSIONS
	--------------------------------------------------------------------------------

	install()

	local source = new_source()
	local results = {}

	local function versions(target, name)
		registry:versions(target, { name = name }, function(list, err)
			table.insert(results, { versions = list, err = err })
		end)
	end

	versions(source, "demo")
	versions(source, "demo")

	eq(#requests, 1, "Concurrent lookups of one package must share a request")
	eq(url_of(1), "https://registry.npmjs.org/demo", "Versions must be read from the package document")

	ok(
		vim.tbl_contains(requests[1].cmd, "--compressed"),
		"A package document must be requested compressed"
	)

	ok(
		requests[1].stdin:find("Accept: application/vnd.npm.install-v1+json", 1, true) ~= nil,
		"The abbreviated document must be asked for"
	)

	answers[1]({
		code = 0,
		stdout = DOCUMENT .. "\n200",
	})

	eq(
		results[1],
		{
			versions = {
				{ value = "0.9.0", timestamp = 0 },
				{ value = "1.0.0", timestamp = 0, deprecated = true },
				{ value = "1.1.0", timestamp = 0, tags = { "latest", "legacy" } },
				{ value = "2.0.0-rc.1", timestamp = 0, tags = { "next" } },
			},
		},
		"Versions must carry deprecation and the dist-tags pointing at them"
	)

	eq(results[2], results[1], "Every waiter must receive the versions")

	-- Scoped packages.
	install()

	versions(new_source(), "@types/node")

	eq(
		url_of(1),
		"https://registry.npmjs.org/@types%2fnode",
		"The slash of a scoped name must be encoded, as npm encodes it"
	)

	-- Another registry.
	install()

	versions(new_source({ npm = { registry_url = "https://npm.company.test/" } }), "demo")

	eq(
		url_of(1),
		"https://npm.company.test/demo",
		"A configured registry must be used"
	)

	-- Unknown package: nothing went wrong.
	install()
	results = {}
	source = new_source()

	versions(source, "not-a-package")

	answers[1]({ code = 0, stdout = '{"error":"Not found"}\n404' })

	eq(results[1], { versions = {} }, "An unknown package must be an empty answer, not an error")

	versions(source, "not a package")

	eq(#requests, 1, "An impossible package name must not be requested")

	-- Failures are reported and not cached.
	install()
	results = {}
	source = new_source()

	versions(source, "demo")

	answers[1]({ code = 28, stderr = "curl: (28) Operation timed out" })

	eq(
		results[1],
		{ versions = {}, err = "curl: (28) Operation timed out" },
		"A failed lookup must answer with an empty list and the error"
	)

	versions(source, "demo")

	eq(#requests, 2, "A failed lookup must not be cached")

	answers[2]({ code = 0, stdout = '{"maintenance":true}\n200' })

	eq(
		results[2],
		{ versions = {}, err = "malformed npm response: not a package document" },
		"A response that is not a package document must be an error"
	)

	--------------------------------------------------------------------------------
	-- LARGE DOCUMENTS
	--
	-- A document over the threshold is reduced on a worker thread. The
	-- threshold is lowered so that an ordinary document takes that path; the
	-- thread is real, so the answer has to be waited for.
	--------------------------------------------------------------------------------

	local original_threshold = Npm.ASYNC_DECODE_BYTES

	Npm.ASYNC_DECODE_BYTES = 1

	rawset(vim, "schedule", original_schedule)

	install()
	results = {}

	versions(new_source(), "demo")

	answers[1]({ code = 0, stdout = DOCUMENT .. "\n200" })

	eq(#results, 0, "A large document must not be decoded before the request returns")

	vim.wait(5000, function()
		return #results > 0
	end, 5)

	eq(
		#results[1].versions,
		4,
		"A document reduced on a worker thread must give the same versions"
	)

	eq(
		results[1].versions[3],
		{ value = "1.1.0", timestamp = 0, tags = { "latest", "legacy" } },
		"Tags and flags must survive the trip between threads"
	)

	-- A failure on the worker comes back as an error, not a crash.
	install()
	results = {}

	versions(new_source(), "demo")

	answers[1]({ code = 0, stdout = "<html>gateway</html>\n200" })

	vim.wait(5000, function()
		return #results > 0
	end, 5)

	eq(
		results[1],
		{ versions = {}, err = "malformed npm response: invalid JSON" },
		"A document the worker cannot read must be reported as an error"
	)

	Npm.ASYNC_DECODE_BYTES = original_threshold

	rawset(vim, "schedule", function(fn)
		fn()
	end)

	--------------------------------------------------------------------------------
	-- SEARCH
	--------------------------------------------------------------------------------

	eq(
		Npm.search_spec(new_source(), "react router"),
		{
			url = "https://registry.npmjs.org/-/v1/search",
			query = {
				text = "react router",
				size = Npm.SEARCH_ROWS,
			},
			decode = "json",
		},
		"Search must use the registry's search endpoint"
	)

	local function found(objects)
		return {
			code = 0,
			stdout = vim.json.encode({ objects = objects, total = #objects }) .. "\n200",
		}
	end

	install()
	results = {}
	source = new_source()

	local function search(text)
		registry:search(source, text, function(packages, err)
			table.insert(results, { packages = packages, err = err })
		end)
	end

	-- Two words: not a package name, so only the search is issued.
	search("react router")

	eq(#requests, 1, "Text that cannot be a package name must not be looked up directly")

	answers[1](found({
		{ package = { name = "obscure-exact", version = "0.0.1" }, downloads = { weekly = 3 } },
		{
			package = { name = "react-router", version = "7.1.0", description = "Declarative routing" },
			downloads = { weekly = 900 },
		},
		{ package = { name = "tie-first", version = "1.0.0" }, downloads = { weekly = 50 } },
		{ package = { name = "tie-second", version = "1.0.0" }, downloads = { weekly = 50 } },
		{ package = { name = "no-downloads", version = "1.0.0" } },
		{ package = { version = "1.0.0" } },
		{ downloads = { weekly = 1 } },
		"not an object",
	}))

	local names = {}

	for _, package in ipairs(results[1].packages) do
		table.insert(names, package.name)
	end

	eq(
		names,
		{ "react-router", "tie-first", "tie-second", "obscure-exact", "no-downloads" },
		"Results must be ordered by downloads, ties in the registry's order, unusable entries dropped"
	)

	eq(
		results[1].packages[1],
		{
			name = "react-router",
			latest_version = "7.1.0",
			description = "Declarative routing",
			downloads = 900,
		},
		"A result must carry its release, description and downloads, and nothing else"
	)

	search("React  Router ")

	eq(#requests, 2, "A search is cached by its text as typed, apart from case")

	-- Failures.
	install()
	results = {}
	source = new_source()

	search("react router")

	answers[1]({ code = 0, stdout = '{"error":"maintenance"}\n200' })

	eq(
		results[1],
		{ packages = {}, err = "malformed npm response" },
		"A response without results must be an error, not an empty answer"
	)

	search("   ")

	eq(#requests, 1, "An empty search must not be requested")

	--------------------------------------------------------------------------------
	-- THE EXACT NAME
	--------------------------------------------------------------------------------

	install()
	results = {}
	source = new_source()

	search("@scope/demo")

	eq(#requests, 2, "A search for a possible package name must also look it up directly")

	local latest = request_for("/@scope%2fdemo/latest")
	local api = request_for("/-/v1/search")

	ok(latest ~= nil and api ~= nil, "One request must go to the search and one to the package")

	answers[api](found({
		{ package = { name = "@scope/demo-tools", version = "3.0.0" }, downloads = { weekly = 900 } },
	}))

	eq(#results, 0, "The search must wait for the exact lookup before answering")

	answers[latest]({
		code = 0,
		stdout = vim.json.encode({
			name = "@scope/demo",
			version = "1.2.3",
			description = "The demo",
		}) .. "\n200",
	})

	eq(
		results[1],
		{
			packages = {
				{ name = "@scope/demo", latest_version = "1.2.3", description = "The demo" },
				{ name = "@scope/demo-tools", latest_version = "3.0.0", downloads = 900 },
			},
		},
		"A package named exactly what was typed must come first"
	)

	-- Already in the results: moved up, once, keeping its downloads.
	install()
	results = {}
	source = new_source()

	search("demo")

	answers[request_for("/demo/latest")]({
		code = 0,
		stdout = '{"name":"demo","version":"1.1.0"}\n200',
	})

	answers[request_for("/-/v1/search")](found({
		{ package = { name = "demo-popular", version = "3.0.0" }, downloads = { weekly = 900 } },
		{ package = { name = "demo", version = "1.1.0" }, downloads = { weekly = 5 } },
	}))

	eq(
		results[1].packages,
		{
			{ name = "demo", latest_version = "1.1.0", downloads = 5 },
			{ name = "demo-popular", latest_version = "3.0.0", downloads = 900 },
		},
		"An exact hit already in the results must be moved first, once, with its details"
	)

	-- No such package: the results stand, and the miss is remembered.
	install()
	results = {}
	source = new_source()

	search("demo")

	answers[request_for("/demo/latest")]({ code = 0, stdout = '"Not Found"\n404' })

	answers[request_for("/-/v1/search")](found({
		{ package = { name = "demo-popular", version = "3.0.0" }, downloads = { weekly = 900 } },
	}))

	eq(#results[1].packages, 1, "Without an exact hit the results must be returned as they are")

	search("demo")

	eq(#requests, 2, "A package found not to exist must not be looked up again this session")

	-- The search fails but the package exists.
	install()
	results = {}
	source = new_source()

	search("demo")

	answers[request_for("/-/v1/search")]({ code = 0, stdout = "slow down\n429" })

	answers[request_for("/demo/latest")]({
		code = 0,
		stdout = '{"name":"demo","version":"1.1.0"}\n200',
	})

	eq(
		results[1],
		{ packages = { { name = "demo", latest_version = "1.1.0" } } },
		"An exact hit must be offered even when the search itself failed"
	)

	-- Both fail: the search's error is reported.
	install()
	results = {}
	source = new_source()

	search("demo")

	answers[request_for("/-/v1/search")]({ code = 0, stdout = "slow down\n429" })
	answers[request_for("/demo/latest")]({ code = 7, stderr = "curl: (7) Failed to connect" })

	eq(
		results[1],
		{ packages = {}, err = "HTTP 429" },
		"With nothing to offer, the search's failure must be reported"
	)

	--------------------------------------------------------------------------------
	-- PERSISTENCE
	--------------------------------------------------------------------------------

	install()

	local dir = vim.fn.tempname()

	local cache = {
		enabled = true,
		dir = dir,
	}

	results = {}

	versions(new_source({ cache = cache }), "demo")

	answers[1]({ code = 0, stdout = DOCUMENT .. "\n200" })

	versions(new_source({ cache = cache }), "demo")

	eq(#requests, 1, "Versions must be served from disk in a later session")
	eq(results[2], results[1], "Persisted versions must match the fetched ones")

	-- What is kept is the reduced list, not the document.
	local stored = vim.fn.globpath(dir, "npm-versions/*.json", false, true)

	eq(#stored, 1, "One cache entry must be written per package")

	ok(
		vim.fn.getfsize(stored[1]) < #DOCUMENT,
		"The cache must hold the reduced versions, not the whole document"
	)

	vim.fn.delete(dir, "rf")

	rawset(vim, "schedule", original_schedule)
end
