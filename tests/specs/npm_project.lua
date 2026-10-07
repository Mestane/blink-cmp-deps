local Project = require("blink_deps.npm_project")
local Registries = require("blink_deps.registries")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- Projects are built in a temporary directory. Nothing here reads a
	-- project of whoever runs the suite.
	--------------------------------------------------------------------------------

	local root = vim.fn.tempname()

	local function write(relative, text)
		local path = root .. "/" .. relative

		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

		local file = assert(io.open(path, "wb"))

		file:write(text)
		file:close()

		return path
	end

	local function new_source(manifest, opts)
		return {
			ecosystem = "npm",
			manifest_path = manifest and (root .. "/" .. manifest) or nil,
			opts = opts or {},
		}
	end

	-- The layout npm has written since version 7.
	local function modern(packages)
		return vim.json.encode({
			name = "demo",
			lockfileVersion = 3,
			packages = packages,
		})
	end

	local INSTALLED = modern({
		[""] = { name = "demo", version = "1.0.0" },
		["node_modules/react"] = { version = "18.3.1" },
		["node_modules/react-dom"] = { version = "18.3.1" },
		["node_modules/@types/node"] = { version = "20.19.43", dev = true },
		["node_modules/@types/react"] = { version = "18.3.3", dev = true },
		["node_modules/ms"] = { version = "2.1.3" },
		["node_modules/debug/node_modules/ms"] = { version = "2.0.0" },
		["node_modules/debug"] = { version = "2.6.9" },
		["node_modules/only-nested/node_modules/hidden"] = { version = "1.0.0" },
		["node_modules/only-nested/node_modules/hidden/node_modules/hidden"] = { version = "2.0.0-rc.1" },
		["node_modules/workspace-link"] = { resolved = "packages/ui", link = true },
		["packages/ui"] = { name = "workspace-link", version = "0.1.0" },
		["node_modules/versionless"] = {},
	})

	write("app/package.json", "{}")
	write("app/node_modules/.package-lock.json", INSTALLED)

	local function names(packages)
		local list = {}

		for _, package in ipairs(packages) do
			table.insert(list, package.name .. "@" .. tostring(package.version or package.latest_version))
		end

		return list
	end

	--------------------------------------------------------------------------------
	-- READING
	--------------------------------------------------------------------------------

	local packages = Project.read(root .. "/app/node_modules/.package-lock.json")

	eq(
		names(packages),
		{
			"@types/node@20.19.43",
			"@types/react@18.3.3",
			"debug@2.6.9",
			"hidden@2.0.0-rc.1",
			"ms@2.1.3",
			"react@18.3.1",
			"react-dom@18.3.1",
		},
		"Each installed package must be listed once, by name, at the version the project's code gets"
	)

	local by_name = {}

	for _, package in ipairs(packages) do
		by_name[package.name] = package
	end

	eq(
		by_name.ms,
		{ name = "ms", version = "2.1.3", versions = { "2.1.3", "2.0.0" } },
		"A package with a private copy elsewhere must report every version in the tree"
	)

	eq(
		by_name.hidden.versions,
		{ "2.0.0-rc.1", "1.0.0" },
		"A package present only as private copies must still be found"
	)

	eq(
		by_name["workspace-link"],
		nil,
		"A workspace link has no version of its own and is not listed"
	)

	-- The older layout, nested by dependency.
	local legacy = write("legacy/package-lock.json", vim.json.encode({
		name = "demo",
		lockfileVersion = 1,
		dependencies = {
			express = {
				version = "4.17.1",
				dependencies = {
					debug = { version = "2.6.9" },
				},
			},
			debug = { version = "4.3.4" },
			["@scope/pkg"] = { version = "1.0.0" },
		},
	}))

	eq(
		Project.read(legacy),
		{
			{ name = "@scope/pkg", version = "1.0.0", versions = { "1.0.0" } },
			{ name = "debug", version = "4.3.4", versions = { "4.3.4", "2.6.9" } },
			{ name = "express", version = "4.17.1", versions = { "4.17.1" } },
		},
		"The lockfile layout from before npm 7 must be read too"
	)

	-- Things that are not lockfiles.
	for name, text in pairs({
		["empty.json"] = "",
		["text.json"] = "not json",
		["array.json"] = "[]",
		["other.json"] = '{"name":"demo","version":"1.0.0"}',
		["wrong-type.json"] = '{"packages":"oops"}',
	}) do
		local found, err = Project.read(write("bad/" .. name, text))

		eq(found, nil, name .. " is not a lockfile")
		ok(type(err) == "string" and err ~= "", "A file that cannot be read must say why")
	end

	eq(
		Project.read(root .. "/does/not/exist.json"),
		nil,
		"A missing file must not raise"
	)

	eq(Project.parse(nil), nil, "A reduction that never came back must not raise")
	eq(Project.parse(""), {}, "A lockfile without packages is an empty project")

	-- Hostile names cannot break the line format.
	eq(
		#Project.read(write("hostile/package-lock.json", modern({
			["node_modules/a\tb"] = { version = "1.0.0" },
			["node_modules/ok"] = { version = "1.0.0\n9.9.9" },
			["node_modules/fine"] = { version = "1.0.0" },
			[1] = { version = "1.0.0" },
			["node_modules/number-version"] = { version = 2 },
		}))),
		1,
		"Entries that could corrupt the result must be dropped on their own"
	)

	--------------------------------------------------------------------------------
	-- LOCATING
	--------------------------------------------------------------------------------

	local function located(manifest)
		local path = Project.locate(root .. "/" .. manifest)

		return path and path:sub(#root + 2) or nil
	end

	eq(
		located("app/package.json"),
		"app/node_modules/.package-lock.json",
		"What is installed must be found next to the manifest"
	)

	-- Declared but not installed.
	write("fresh/package.json", "{}")
	write("fresh/package-lock.json", modern({ ["node_modules/a"] = { version = "1.0.0" } }))

	eq(
		located("fresh/package.json"),
		"fresh/package-lock.json",
		"Without an install, the project's lockfile must be used"
	)

	-- Installed wins over declared.
	write("both/package.json", "{}")
	write("both/package-lock.json", modern({ ["node_modules/a"] = { version = "1.0.0" } }))
	write("both/node_modules/.package-lock.json", modern({ ["node_modules/a"] = { version = "1.0.1" } }))

	eq(
		located("both/package.json"),
		"both/node_modules/.package-lock.json",
		"What is installed must be preferred over what is declared"
	)

	write("published/package.json", "{}")
	write("published/npm-shrinkwrap.json", modern({ ["node_modules/a"] = { version = "1.0.0" } }))

	eq(
		located("published/package.json"),
		"published/npm-shrinkwrap.json",
		"A shrinkwrap file must be recognised"
	)

	-- A monorepo keeps its lockfile above the package being edited.
	write("mono/package-lock.json", modern({ ["node_modules/shared"] = { version = "3.0.0" } }))
	write("mono/packages/ui/package.json", "{}")

	eq(
		located("mono/packages/ui/package.json"),
		"mono/package-lock.json",
		"A lockfile in a directory above must be found"
	)

	-- The nearest one wins.
	write("mono/packages/own/package.json", "{}")
	write("mono/packages/own/package-lock.json", modern({ ["node_modules/own"] = { version = "1.0.0" } }))

	eq(
		located("mono/packages/own/package.json"),
		"mono/packages/own/package-lock.json",
		"The nearest lockfile must win"
	)

	-- A directory called like a lockfile is not one.
	write("trap/package.json", "{}")
	vim.fn.mkdir(root .. "/trap/package-lock.json", "p")

	ok(
		located("trap/package.json") ~= "trap/package-lock.json",
		"A directory with a lockfile's name must not be taken for one"
	)

	-- The search stops after a bounded number of levels.
	local deep = "deep" .. string.rep("/level", Project.MAX_DEPTH + 1)

	write("deep/package-lock.json", modern({}))
	write(deep .. "/package.json", "{}")

	eq(located(deep .. "/package.json"), nil, "The search upwards must be bounded")

	eq(Project.locate(nil), nil, "A missing manifest path has no lockfile")
	eq(Project.locate(""), nil, "An empty manifest path has no lockfile")

	--------------------------------------------------------------------------------
	-- REGISTRY
	--------------------------------------------------------------------------------

	local registry = Project.REGISTRY

	eq(
		{ registry.id, registry.name, registry.offline, registry.public },
		{ "npm-project", "This project", true },
		"The project must describe itself as an offline registry"
	)

	for capability in pairs(registry.capabilities) do
		ok(
			type(registry[capability]) == "function",
			"The project must implement its declared capability " .. capability
		)
	end

	eq(
		Registries.with(new_source("app/package.json"), "search")[1],
		registry,
		"An npm source must ask the project first"
	)

	--------------------------------------------------------------------------------
	-- SEARCH
	--------------------------------------------------------------------------------

	local source = new_source("app/package.json")

	local function search(text, subject)
		local seen = {}

		registry:search(subject or source, text, function(found, err)
			seen.err = err
			seen.names = names(found)
		end)

		return seen
	end

	eq(
		search("reac"),
		{ names = { "react@18.3.1", "react-dom@18.3.1", "@types/react@18.3.3" } },
		"The beginning of a name must find the project's packages, scoped ones after"
	)

	eq(
		search("node"),
		{ names = { "@types/node@20.19.43" } },
		"The part after the scope must be matched from its beginning"
	)

	eq(
		search("@types/"),
		{ names = { "@types/node@20.19.43", "@types/react@18.3.3" } },
		"A scope must find everything under it"
	)

	eq(
		search("dom"),
		{ names = { "react-dom@18.3.1" } },
		"A match in the middle of a name must be found"
	)

	eq(search("REACT-D"), { names = { "react-dom@18.3.1" } }, "Matching must ignore case")
	eq(search("zzz"), { names = {} }, "No match is an empty answer, not an error")
	eq(search("  "), { names = {} }, "An empty search matches nothing")
	eq(search("re.ct"), { names = {} }, "The text is matched literally, not as a pattern")

	eq(
		source.npm_project_pipeline:stats().network,
		1,
		"The lockfile must be read once, however many searches use it"
	)

	-- A result handed out must not be a way to alter the project's list.
	registry:search(source, "ms", function(found)
		found[1].latest_version = "tampered"
	end)

	eq(search("ms"), { names = { "ms@2.1.3" } }, "A consumer must not be able to corrupt the list")

	--------------------------------------------------------------------------------
	-- VERSIONS
	--------------------------------------------------------------------------------

	local function versions(name, subject)
		local seen = {}

		registry:versions(subject or source, { name = name }, function(list, err)
			seen.versions = list
			seen.err = err
		end)

		return seen
	end

	eq(
		versions("ms"),
		{
			versions = {
				{ value = "2.1.3", timestamp = 0 },
				{ value = "2.0.0", timestamp = 0 },
			},
		},
		"Every version of a package in the tree must be reported"
	)

	eq(versions("react").versions, { { value = "18.3.1", timestamp = 0 } }, "A single copy is a single version")
	eq(versions("not-installed"), { versions = {} }, "A package the project does not have has no versions here")
	eq(versions("reac"), { versions = {} }, "Versions are looked up by exact name")

	--------------------------------------------------------------------------------
	-- THE FILE CHANGES
	--------------------------------------------------------------------------------

	write("changing/package.json", "{}")
	write("changing/package-lock.json", modern({ ["node_modules/before"] = { version = "1.0.0" } }))

	local changing = new_source("changing/package.json")

	eq(search("be", changing), { names = { "before@1.0.0" } }, "The project must be read as it is")

	-- An install: different content and length.
	write("changing/package-lock.json", modern({
		["node_modules/before"] = { version = "1.0.0" },
		["node_modules/better"] = { version = "2.0.0" },
	}))

	eq(
		search("be", changing),
		{ names = { "before@1.0.0", "better@2.0.0" } },
		"A changed lockfile must be read again without restarting"
	)

	--------------------------------------------------------------------------------
	-- NOTHING THERE
	--------------------------------------------------------------------------------

	write("bare/package.json", "{}")

	eq(
		search("react", new_source("bare/package.json")),
		{ names = {} },
		"A project that was never installed simply has nothing to offer"
	)

	eq(
		search("react", new_source(nil)),
		{ names = {} },
		"A source that has not said which manifest it is completing has nothing to offer"
	)

	write("broken/package.json", "{}")
	write("broken/package-lock.json", "{ not json")

	eq(
		search("react", new_source("broken/package.json")),
		{ names = {} },
		"A lockfile that cannot be read is an empty project, not an error"
	)

	eq(
		Project.is_enabled(new_source(nil, { npm_project = { enabled = false } })),
		false,
		"The project must be switchable off"
	)

	eq(Project.is_enabled({ opts = {} }), true, "The project must be enabled by default")

	--------------------------------------------------------------------------------
	-- LARGE LOCKFILES
	--
	-- A lockfile over the threshold is read on a worker thread. The threshold
	-- is lowered so an ordinary one takes that path; the thread is real, so
	-- the answer has to be waited for.
	--------------------------------------------------------------------------------

	local original_threshold = Project.ASYNC_BYTES

	Project.ASYNC_BYTES = 1

	local threaded = new_source("app/package.json")
	local answer

	registry:search(threaded, "reac", function(found)
		answer = names(found)
	end)

	eq(answer, nil, "A large lockfile must not be read on the calling thread")

	vim.wait(5000, function()
		return answer ~= nil
	end, 5)

	eq(
		answer,
		{ "react@18.3.1", "react-dom@18.3.1", "@types/react@18.3.3" },
		"A lockfile read on a worker thread must give the same packages"
	)

	-- A file the worker cannot read comes back as an empty project.
	answer = nil

	registry:search(new_source("broken/package.json"), "react", function(found)
		answer = names(found)
	end)

	vim.wait(5000, function()
		return answer ~= nil
	end, 5)

	eq(answer, {}, "A lockfile the worker cannot read must be an empty project")

	Project.ASYNC_BYTES = original_threshold

	vim.fn.delete(root, "rf")
end
