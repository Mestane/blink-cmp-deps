local CratesIo = require("blink_deps.crates_io")
local Http = require("blink_deps.http")
local Registries = require("blink_deps.registries")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- INDEX PATHS
	--------------------------------------------------------------------------------

	eq(CratesIo.index_path("a"), "1/a", "A one letter crate lives under 1/")
	eq(CratesIo.index_path("cc"), "2/cc", "A two letter crate lives under 2/")
	eq(CratesIo.index_path("syn"), "3/s/syn", "A three letter crate lives under 3/ and its first letter")
	eq(CratesIo.index_path("serde"), "se/rd/serde", "A longer crate lives under its first four letters")
	eq(CratesIo.index_path("rand"), "ra/nd/rand", "A four letter crate uses the long layout")
	eq(CratesIo.index_path("Inflector"), "in/fl/inflector", "The path is lowercased")
	eq(CratesIo.index_path("serde_json"), "se/rd/serde_json", "Underscores are kept")
	eq(CratesIo.index_path("tokio-util"), "to/ki/tokio-util", "Hyphens are kept")

	for _, name in ipairs({ "", "a b", "../etc", "serde/..", "se?x", "naïve" }) do
		eq(
			CratesIo.index_path(name),
			nil,
			"'" .. name .. "' cannot be a crate name and must not reach the URL"
		)
	end

	eq(CratesIo.index_path(nil), nil, "A missing name has no path")

	--------------------------------------------------------------------------------
	-- INDEX ENTRIES
	--------------------------------------------------------------------------------

	local INDEX = table.concat({
		'{"name":"demo","vers":"0.9.0","deps":[],"features":{},"yanked":false}',
		'{"name":"demo","vers":"1.0.0","deps":[],"features":{"std":[],"derive":["dep:demo_derive"]},"yanked":true}',
		"this line is damaged",
		'{"name":"demo","vers":"1.1.0","features":{"std":[]},"features2":{"unstable":["dep:x"],"std":[]},"yanked":false}',
		'{"name":"demo","deps":[]}',
		'{"name":"demo","vers":""}',
		"",
	}, "\n")

	eq(
		CratesIo.parse_index(INDEX),
		{
			{ name = "demo", value = "0.9.0", yanked = false, features = {} },
			{ name = "demo", value = "1.0.0", yanked = true, features = { "derive", "std" } },
			{ name = "demo", value = "1.1.0", yanked = false, features = { "std", "unstable" } },
		},
		"Entries must be read in order, with features merged and damaged lines skipped"
	)

	-- An optional dependency is a feature of the same name, unless a feature
	-- claims it with dep:, in which case it cannot be enabled directly.
	eq(
		CratesIo.parse_index(vim.json.encode({
			name = "demo",
			vers = "1.0.0",
			deps = {
				{ name = "implicit", optional = true },
				{ name = "claimed", optional = true },
				{ name = "claimed_in_features2", optional = true },
				{ name = "required", optional = false },
				{ name = "unmarked" },
			},
			features = {
				json = { "dep:claimed", "implicit/extra" },
			},
			features2 = {
				tls = { "dep:claimed_in_features2" },
			},
		}))[1].features,
		{ "implicit", "json", "tls" },
		"Optional dependencies must be offered as features only when nothing claims them"
	)

	eq(CratesIo.parse_index(""), {}, "An empty index has no entries")
	eq(CratesIo.parse_index(nil), {}, "A missing body has no entries")

	--------------------------------------------------------------------------------
	-- HARNESS
	--------------------------------------------------------------------------------

	local requests
	local answers

	rawset(vim, "schedule", function(fn)
		fn()
	end)

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
			ecosystem = "cargo",
			opts = vim.tbl_extend("force", {
				cache = {
					enabled = false,
				},
				retries = 0,
			}, opts or {}),
		}
	end

	local registry = CratesIo.REGISTRY

	--------------------------------------------------------------------------------
	-- REGISTRY
	--------------------------------------------------------------------------------

	eq(
		{ registry.id, registry.name, registry.public, registry.offline },
		{ "crates-io", "crates.io", true },
		"crates.io must describe itself as the public registry"
	)

	for capability in pairs(registry.capabilities) do
		ok(
			type(registry[capability]) == "function",
			"crates.io must implement its declared capability " .. capability
		)
	end

	eq(
		Registries.list(new_source()),
		{ registry },
		"A Cargo source must use crates.io"
	)

	eq(
		Registries.list(new_source({ crates_io = { enabled = false } })),
		{},
		"crates.io must be removable from a Cargo source"
	)

	-- A Maven source is unaffected, and so is a source that declares nothing.
	local function ids(source)
		local list = {}

		for _, entry in ipairs(Registries.list(source)) do
			table.insert(list, entry.id)
		end

		return list
	end

	eq(
		ids({ ecosystem = "maven", opts = {} }),
		{ "local", "central" },
		"A Maven source must not be given Cargo registries"
	)

	eq(
		ids({ opts = {} }),
		{ "local", "central" },
		"A source without an ecosystem is a Maven source"
	)

	eq(
		ids({ ecosystem = "unknown", opts = {} }),
		{},
		"An unknown ecosystem has no registries"
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

	versions(source, "Demo")
	versions(source, "Demo")

	eq(#requests, 1, "Concurrent lookups of one crate must share a request")

	eq(
		requests[1][#requests[1]],
		"https://index.crates.io/de/mo/demo",
		"Versions must be read from the sparse index"
	)

	ok(
		vim.tbl_contains(requests[1], Http.USER_AGENT)
			and Http.USER_AGENT:find("https://github.com/Mestane/blink-cmp-deps", 1, true) ~= nil,
		"Requests must identify the client and where to reach its maintainers"
	)

	answers[1]({
		code = 0,
		stdout = INDEX .. "\n200",
	})

	eq(
		results[1],
		{
			versions = {
				{ value = "0.9.0", timestamp = 0 },
				{ value = "1.0.0", timestamp = 0, yanked = true },
				{ value = "1.1.0", timestamp = 0 },
			},
		},
		"Versions must use the contract's shape, with yanked releases marked"
	)

	eq(results[2], results[1], "Every waiter must receive the versions")

	versions(source, "demo")

	eq(#requests, 1, "A name differing only in case is the same crate")

	-- A crate that does not exist: nothing went wrong.
	install()
	results = {}
	source = new_source()

	versions(source, "not-a-crate")

	answers[1]({
		code = 0,
		stdout = "\n404",
	})

	eq(
		results[1],
		{ versions = {} },
		"An unknown crate must be an empty answer, not an error"
	)

	-- Text that cannot be a crate name never leaves the machine.
	versions(source, "not a crate")

	eq(#requests, 1, "An impossible crate name must not be requested")
	eq(results[2], { versions = {} }, "An impossible crate name has no versions")

	-- A real failure is reported and not cached.
	install()
	results = {}
	source = new_source()

	versions(source, "demo")

	answers[1]({
		code = 28,
		stderr = "curl: (28) Operation timed out",
	})

	eq(
		results[1],
		{ versions = {}, err = "curl: (28) Operation timed out" },
		"A failed lookup must answer with an empty list and the error"
	)

	versions(source, "demo")

	eq(#requests, 2, "A failed lookup must not be cached")

	-- A mirror can replace the index.
	install()

	versions(new_source({
		crates_io = {
			index_url = "https://mirror.test/index/",
		},
	}), "serde")

	eq(
		requests[1][#requests[1]],
		"https://mirror.test/index/se/rd/serde",
		"A configured index URL must be used"
	)

	--------------------------------------------------------------------------------
	-- SEARCH
	--------------------------------------------------------------------------------

	eq(
		CratesIo.search_spec(new_source(), "serde json"),
		{
			url = "https://crates.io/api/v1/crates",
			query = {
				q = "serde json",
				per_page = CratesIo.SEARCH_ROWS,
				sort = "downloads",
			},
			decode = "json",
		},
		"Search must use the web API"
	)

	eq(
		CratesIo.search_spec(
			new_source({ crates_io = { api_url = "https://registry.test/" } }),
			"x"
		).url,
		"https://registry.test/api/v1/crates",
		"A configured API URL must be used"
	)

	install()
	results = {}
	source = new_source()

	local function search(text)
		registry:search(source, text, function(packages, err)
			table.insert(results, { packages = packages, err = err })
		end)
	end

	search("serde json")
	search("  Serde JSON ")

	eq(#requests, 1, "Searches differing only in case and spacing must share a request")

	answers[1]({
		code = 0,
		stdout = vim.json.encode({
			crates = {
				{
					id = "serde_json",
					name = "serde_json",
					max_version = "2.0.0-rc.1",
					max_stable_version = "1.0.140",
					description = "A JSON serialization file format",
					downloads = 500000000,
				},
				{
					name = "only-prerelease",
					max_version = "0.1.0-alpha.1",
					max_stable_version = vim.NIL,
					description = vim.NIL,
				},
				{ id = "by-id-only", newest_version = "0.3.0" },
				{ description = "nameless" },
				"not a table",
			},
			meta = { total = 5 },
		}) .. "\n200",
	})

	eq(
		results[1],
		{
			packages = {
				{
					name = "serde_json",
					latest_version = "1.0.140",
					description = "A JSON serialization file format",
					downloads = 500000000,
				},
				{
					name = "only-prerelease",
					latest_version = "0.1.0-alpha.1",
				},
				{
					name = "by-id-only",
					latest_version = "0.3.0",
				},
			},
		},
		"Search results must prefer the stable release and drop unusable entries"
	)

	search("serde json")

	eq(#requests, 1, "A repeated search must be served from memory")

	-- Not a search result. The text has a space, so it cannot be a crate
	-- name and only the search is issued.
	install()
	results = {}
	source = new_source()

	search("serde json")

	eq(#requests, 1, "Text that cannot be a crate name must not be looked up in the index")

	answers[1]({
		code = 0,
		stdout = '{"errors":[{"detail":"maintenance"}]}\n200',
	})

	eq(
		results[1],
		{ packages = {}, err = "malformed crates.io response" },
		"A response without results must be an error, not an empty answer"
	)

	-- Rate limited.
	search("tokio util")

	answers[2]({
		code = 0,
		stdout = "slow down\n429",
	})

	eq(
		results[2],
		{ packages = {}, err = "HTTP 429" },
		"A rate limit must be reported as a failure"
	)

	search("   ")

	eq(#requests, 2, "An empty search must not be requested")
	eq(results[3], { packages = {} }, "An empty search has no results")

	--------------------------------------------------------------------------------
	-- THE EXACT NAME
	--
	-- Search results are ordered by downloads, which can push a little used
	-- crate off the page even when its exact name was typed. The index knows
	-- whether that crate exists.
	--------------------------------------------------------------------------------

	local function request_for(fragment)
		for index, request in ipairs(requests) do
			if request[#request]:find(fragment, 1, true) then
				return index
			end
		end

		return nil
	end

	local function popular()
		return {
			code = 0,
			stdout = vim.json.encode({
				crates = {
					{ name = "demo-popular", max_stable_version = "3.0.0", downloads = 900 },
					{ name = "demo-other", max_stable_version = "2.0.0", downloads = 800 },
				},
			}) .. "\n200",
		}
	end

	install()
	results = {}
	source = new_source()

	search("Demo")

	eq(#requests, 2, "A search for a possible crate name must also consult the index")

	local api = request_for("/api/v1/crates")
	local index = request_for("index.crates.io/de/mo/demo")

	ok(api ~= nil and index ~= nil, "One request must go to the API and one to the index")

	answers[api](popular())

	eq(#results, 0, "The search must wait for the exact lookup before answering")

	answers[index]({
		code = 0,
		stdout = INDEX .. "\n200",
	})

	eq(
		results[1],
		{
			packages = {
				{ name = "demo", latest_version = "1.1.0" },
				{ name = "demo-popular", latest_version = "3.0.0", downloads = 900 },
				{ name = "demo-other", latest_version = "2.0.0", downloads = 800 },
			},
		},
		"A crate named exactly what was typed must come first, with its current release"
	)

	-- The search already has the crate: it is moved up, not listed twice,
	-- and keeps what the search knows about it.
	install()
	results = {}
	source = new_source()

	search("demo")

	answers[request_for("index.crates.io")]({
		code = 0,
		stdout = INDEX .. "\n200",
	})

	answers[request_for("/api/v1/crates")]({
		code = 0,
		stdout = vim.json.encode({
			crates = {
				{ name = "demo-popular", max_stable_version = "3.0.0" },
				{ name = "demo", max_stable_version = "1.1.0", description = "A demo", downloads = 5 },
			},
		}) .. "\n200",
	})

	eq(
		results[1],
		{
			packages = {
				{ name = "demo", latest_version = "1.1.0", description = "A demo", downloads = 5 },
				{ name = "demo-popular", latest_version = "3.0.0" },
			},
		},
		"An exact hit already in the results must be moved first, once, with its details"
	)

	-- No such crate: the results are untouched.
	install()
	results = {}
	source = new_source()

	search("demo")

	answers[request_for("index.crates.io")]({ code = 0, stdout = "\n404" })
	answers[request_for("/api/v1/crates")](popular())

	eq(
		#results[1].packages,
		2,
		"Without an exact hit the search results must be returned as they are"
	)

	-- The search fails but the crate exists: that is still an answer.
	install()
	results = {}
	source = new_source()

	search("demo")

	answers[request_for("/api/v1/crates")]({ code = 0, stdout = "slow down\n429" })

	answers[request_for("index.crates.io")]({
		code = 0,
		stdout = INDEX .. "\n200",
	})

	eq(
		results[1],
		{
			packages = {
				{ name = "demo", latest_version = "1.1.0" },
			},
		},
		"An exact hit must be offered even when the search itself failed"
	)

	-- The index fails: the search stands on its own.
	install()
	results = {}
	source = new_source()

	search("demo")

	answers[request_for("index.crates.io")]({ code = 7, stderr = "curl: (7) Failed to connect" })
	answers[request_for("/api/v1/crates")](popular())

	eq(
		{ #results[1].packages, results[1].err },
		{ 2 },
		"A failed exact lookup must not fail the search"
	)

	--------------------------------------------------------------------------------
	-- FEATURES
	--------------------------------------------------------------------------------

	local function features_of(body)
		install()

		local seen = {}

		registry:features(new_source(), { name = "demo" }, function(list, err)
			seen.features = list
			seen.err = err
		end)

		answers[1](body)

		return seen
	end

	eq(
		features_of({ code = 0, stdout = INDEX .. "\n200" }),
		{ features = { "std", "unstable" } },
		"Features must be those of the newest release that is not yanked"
	)

	eq(
		features_of({
			code = 0,
			stdout = table.concat({
				'{"name":"demo","vers":"1.0.0","features":{"stable-only":[]}}',
				'{"name":"demo","vers":"2.0.0-rc.1","features":{"next":[]}}',
				'{"name":"demo","vers":"1.5.0","features":{"withdrawn":[]},"yanked":true}',
			}, "\n") .. "\n200",
		}),
		{ features = { "stable-only" } },
		"A prerelease or a yanked release must not decide the features offered"
	)

	eq(
		features_of({
			code = 0,
			stdout = '{"name":"demo","vers":"0.1.0-alpha.1","features":{"early":[]}}\n200',
		}),
		{ features = { "early" } },
		"A crate with only prereleases must still offer features"
	)

	eq(
		features_of({ code = 0, stdout = "\n404" }),
		{ features = {} },
		"An unknown crate has no features and is not an error"
	)

	eq(
		features_of({ code = 28, stderr = "curl: (28) Operation timed out" }),
		{ features = {}, err = "curl: (28) Operation timed out" },
		"A failed lookup must report its error"
	)

	--------------------------------------------------------------------------------
	-- PERSISTENCE
	--------------------------------------------------------------------------------

	install()

	local dir = vim.fn.tempname()

	local cached = new_source({
		cache = {
			enabled = true,
			dir = dir,
		},
	})

	results = {}

	versions(cached, "demo")

	answers[1]({
		code = 0,
		stdout = INDEX .. "\n200",
	})

	-- A new session with the same cache directory needs no request.
	versions(new_source({
		cache = {
			enabled = true,
			dir = dir,
		},
	}), "demo")

	eq(#requests, 1, "Index entries must be served from disk in a later session")
	eq(results[2], results[1], "Persisted versions must match the fetched ones")

	vim.fn.delete(dir, "rf")
end
