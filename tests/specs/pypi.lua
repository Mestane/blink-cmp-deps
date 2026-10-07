local Pypi = require("blink_deps.pypi")
local Registries = require("blink_deps.registries")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- PROJECT NAMES
	--------------------------------------------------------------------------------

	for written, expected in pairs({
		["requests"] = "requests",
		["Django"] = "django",
		["Typing_Extensions"] = "typing-extensions",
		["zope.interface"] = "zope-interface",
		["a"] = "a",
		["ruamel.yaml.clib"] = "ruamel-yaml-clib",
	}) do
		eq(Pypi.project_path(written), expected, written .. " is filed under " .. expected)
	end

	for _, name in ipairs({
		"",
		"two words",
		"../etc",
		"-leading",
		"trailing-",
		"trailing.",
		"name/extra",
		"name?x",
		"name@1",
		"naïve",
	}) do
		eq(
			Pypi.project_path(name),
			nil,
			"'" .. name .. "' is not a project name and must not reach the URL"
		)
	end

	eq(Pypi.project_path(nil), nil, "A missing name is not a project name")

	--------------------------------------------------------------------------------
	-- PROJECT PAGES
	--------------------------------------------------------------------------------

	local function file(filename, extra)
		return vim.tbl_extend("force", {
			filename = filename,
			url = "https://files.test/" .. filename,
			hashes = {},
			yanked = false,
		}, extra or {})
	end

	local PAGE = vim.json.encode({
		meta = { ["api-version"] = "1.4" },
		name = "demo-pkg",
		versions = { "1.0.0", "1.1.0", "2.0.0rc1", "0.9" },
		files = {
			file("demo_pkg-1.0.0-py3-none-any.whl", { ["upload-time"] = "2024-03-02T10:00:00.000000Z" }),
			file("demo-pkg-1.0.0.tar.gz", { ["upload-time"] = "2024-03-01T09:00:00.000000Z" }),
			-- Every file of 1.1.0 is yanked, with and without a reason.
			file("demo_pkg-1.1.0-py3-none-any.whl", { yanked = "broken metadata" }),
			file("demo-pkg-1.1.0.tar.gz", { yanked = true }),
			-- Only one file of 2.0.0rc1 is.
			file("demo_pkg-2.0.0rc1-cp312-cp312-manylinux_2_17_x86_64.whl", { yanked = true }),
			file("demo_pkg-2.0.0rc1-1-py3-none-any.whl"),
			file("demo-pkg-0.9.zip", { ["upload-time"] = "2020-01-05T00:00:00Z" }),
			-- Not one of the listed versions.
			file("demo_pkg-9.9.9-py3-none-any.whl"),
			{ url = "https://files.test/nameless", yanked = false },
			"not a file",
		},
	})

	eq(
		Pypi.read(PAGE),
		{
			name = "demo-pkg",
			versions = {
				{ value = "1.0.0", published = "2024-03-01" },
				{ value = "1.1.0", yanked = true },
				{ value = "2.0.0rc1" },
				{ value = "0.9", published = "2020-01-05" },
			},
		},
		"A page must reduce to its versions, with yanked ones marked and first upload dates"
	)

	-- An index implementing the first version of the API lists no versions.
	eq(
		Pypi.read(vim.json.encode({
			meta = { ["api-version"] = "1.0" },
			name = "old-index",
			files = {
				file("old_index-1.0-py3-none-any.whl"),
				file("old-index-1.0.tar.gz"),
				file("old-index-1.1.tar.bz2"),
				file("old-index-1.2.tgz"),
				file("README.txt"),
			},
		})).versions,
		{
			{ value = "1.0" },
			{ value = "1.1" },
			{ value = "1.2" },
		},
		"Without a versions list, versions must be taken from the file names"
	)

	eq(
		Pypi.read('{"name":"empty","files":[],"versions":[]}'),
		{ name = "empty", versions = {} },
		"A project without files has no versions"
	)

	for _, body in ipairs({
		"",
		"<!DOCTYPE html><html><body><a href='x'>x</a></body></html>",
		"[]",
		'{"projects":[]}',
		'{"files":"oops"}',
	}) do
		local project, err = Pypi.read(body)

		eq(project, nil, "Something that is not a project page must not reduce")
		ok(type(err) == "string" and err ~= "", "A failed reduction must say why")
	end

	eq(Pypi.parse(nil), nil, "A reduction that never came back must not raise")

	--------------------------------------------------------------------------------
	-- CURRENT RELEASE
	--------------------------------------------------------------------------------

	local function current(versions)
		local release = Pypi.current_release(versions)

		return release and release.value or nil
	end

	eq(
		current({
			{ value = "1.9" },
			{ value = "1.10" },
			{ value = "2.0rc1" },
			{ value = "1.11", yanked = true },
			{ value = "1.10.post1" },
		}),
		"1.10.post1",
		"What pip installs: the newest release that is neither yanked nor a prerelease"
	)

	eq(current({ { value = "0.1a1" }, { value = "0.1a2" } }), "0.1a2", "With only prereleases, the newest of them")
	eq(current({ { value = "1.0", yanked = true } }), "1.0", "With everything yanked, the newest of all")
	eq(current({}), nil, "A project without versions has no current release")

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
			ecosystem = "pypi",
			opts = vim.tbl_extend("force", {
				cache = {
					enabled = false,
				},
				retries = 0,
			}, opts or {}),
		}
	end

	local function url_of(index)
		return requests[index].cmd[#requests[index].cmd]
	end

	local registry = Pypi.REGISTRY

	--------------------------------------------------------------------------------
	-- REGISTRY
	--------------------------------------------------------------------------------

	eq(
		{ registry.id, registry.name, registry.public, registry.offline },
		{ "pypi", "PyPI", true },
		"PyPI must describe itself as the public index"
	)

	for capability in pairs(registry.capabilities) do
		ok(
			type(registry[capability]) == "function",
			"PyPI must implement its declared capability " .. capability
		)
	end

	eq(Registries.list(new_source()), { registry }, "A Python source must use PyPI")

	eq(
		Registries.list(new_source({ pypi = { enabled = false } })),
		{},
		"PyPI must be removable from a Python source"
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

	versions(source, "Demo_Pkg")
	versions(source, "demo.pkg")

	eq(#requests, 1, "Different spellings of one project must share a request")

	eq(
		url_of(1),
		"https://pypi.org/simple/demo-pkg/",
		"The project must be requested under its normalised name"
	)

	ok(
		vim.tbl_contains(requests[1].cmd, "--compressed"),
		"A project page must be requested compressed"
	)

	ok(
		requests[1].stdin:find("Accept: application/vnd.pypi.simple.v1+json", 1, true) ~= nil,
		"The JSON form of the simple index must be asked for"
	)

	answers[1]({ code = 0, stdout = PAGE .. "\n200" })

	eq(
		results[1],
		{
			versions = {
				{ value = "1.0.0", timestamp = 0, published = "2024-03-01" },
				{ value = "1.1.0", timestamp = 0, yanked = true },
				{ value = "2.0.0rc1", timestamp = 0 },
				{ value = "0.9", timestamp = 0, published = "2020-01-05" },
			},
		},
		"Versions must use the contract's shape, with yanked releases and dates"
	)

	eq(results[2], results[1], "Every waiter must receive the versions")

	-- Another index.
	install()

	versions(new_source({ pypi = { index_url = "https://pypi.company.test/simple/" } }), "demo")

	eq(url_of(1), "https://pypi.company.test/simple/demo/", "A configured index must be used")

	-- Unknown project: nothing went wrong.
	install()
	results = {}
	source = new_source()

	versions(source, "not-a-project")

	answers[1]({ code = 0, stdout = "404 Not Found\n404" })

	eq(results[1], { versions = {} }, "An unknown project must be an empty answer, not an error")

	versions(source, "not a project")

	eq(#requests, 1, "An impossible project name must not be requested")

	-- Failures.
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

	-- An index that only serves HTML.
	answers[2]({ code = 0, stdout = "<html><a href='demo-1.0.tar.gz'>demo-1.0.tar.gz</a></html>\n200" })

	eq(
		results[2],
		{ versions = {}, err = "unreadable index response: not JSON" },
		"An index answering in HTML must be reported, not read as an empty project"
	)

	--------------------------------------------------------------------------------
	-- LARGE PAGES
	--------------------------------------------------------------------------------

	local original_threshold = Pypi.ASYNC_BYTES

	Pypi.ASYNC_BYTES = 1

	rawset(vim, "schedule", original_schedule)

	install()
	results = {}

	versions(new_source(), "demo-pkg")

	answers[1]({ code = 0, stdout = PAGE .. "\n200" })

	eq(#results, 0, "A large page must not be reduced before the request returns")

	vim.wait(5000, function()
		return #results > 0
	end, 5)

	eq(
		results[1].versions[2],
		{ value = "1.1.0", timestamp = 0, yanked = true },
		"A page reduced on a worker thread must give the same versions"
	)

	Pypi.ASYNC_BYTES = original_threshold

	rawset(vim, "schedule", function(fn)
		fn()
	end)

	--------------------------------------------------------------------------------
	-- SEARCH: THE EXACT NAME
	--------------------------------------------------------------------------------

	install()
	results = {}
	source = new_source()

	local function search(text)
		registry:search(source, text, function(packages, err)
			table.insert(results, { packages = packages, err = err })
		end)
	end

	search("Demo_Pkg")

	eq(url_of(1), "https://pypi.org/simple/demo-pkg/", "A search must ask whether the project exists")

	answers[1]({ code = 0, stdout = PAGE .. "\n200" })

	eq(
		results[1],
		{ packages = { { name = "demo-pkg", latest_version = "1.0.0" } } },
		"An existing project must be offered under the index's name, at the release pip would install"
	)

	-- The page fetched for the search answers the version lookup too.
	versions(source, "demo-pkg")

	eq(#requests, 1, "Versions of a project just searched for must not be fetched again")

	search("no-such")

	answers[2]({ code = 0, stdout = "Not Found\n404" })

	eq(results[3], { packages = {} }, "A name that is no project must find nothing, without an error")

	search("two words")
	search("")

	eq(#requests, 2, "Text that cannot be a project name must not be requested")

	search("failing")

	answers[3]({ code = 7, stderr = "curl: (7) Failed to connect" })

	eq(
		results[#results],
		{ packages = {}, err = "curl: (7) Failed to connect" },
		"A failed lookup must report its error"
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

	versions(new_source({ cache = cache }), "demo-pkg")

	answers[1]({ code = 0, stdout = PAGE .. "\n200" })

	versions(new_source({ cache = cache }), "demo-pkg")

	eq(#requests, 1, "Versions must be served from disk in a later session")
	eq(results[2], results[1], "Persisted versions must match the fetched ones")

	local stored = vim.fn.globpath(dir, "pypi/*.json", false, true)

	ok(
		#stored == 1 and vim.fn.getfsize(stored[1]) < #PAGE,
		"The cache must hold the reduced versions, not the whole page"
	)

	vim.fn.delete(dir, "rf")

	rawset(vim, "schedule", original_schedule)
end
