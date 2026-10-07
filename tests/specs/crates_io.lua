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
			{ value = "0.9.0", yanked = false, features = {} },
			{ value = "1.0.0", yanked = true, features = { "derive", "std" } },
			{ value = "1.1.0", yanked = false, features = { "std", "unstable" } },
		},
		"Entries must be read in order, with features merged and damaged lines skipped"
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

	-- Not a search result.
	install()
	results = {}
	source = new_source()

	search("serde")

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
	search("tokio")

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
