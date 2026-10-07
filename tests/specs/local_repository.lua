local LocalRepository = require("blink_deps.local_repository")

return function(test)
	local eq = test.eq

	--------------------------------------------------------------------------------
	-- PATH PARSING
	--------------------------------------------------------------------------------

	eq(
		LocalRepository.parse_relative_path(
			"org/springframework/kafka/spring-kafka/3.3.0/spring-kafka-3.3.0.pom"
		),
		{
			g = "org.springframework.kafka",
			a = "spring-kafka",
			latestVersion = "3.3.0",
		},
		"A repository path must yield its coordinate"
	)

	eq(
		LocalRepository.parse_relative_path("junit/junit/4.13.2/junit-4.13.2.pom"),
		{
			g = "junit",
			a = "junit",
			latestVersion = "4.13.2",
		},
		"A single segment group must be supported"
	)

	eq(
		LocalRepository.parse_relative_path("junit/4.13.2/junit-4.13.2.pom"),
		nil,
		"A path too short to hold a coordinate must be rejected"
	)

	eq(
		LocalRepository.parse_relative_path(""),
		nil,
		"An empty path must be rejected"
	)

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- The scan shells out to find. It is replaced so the spec neither depends
	-- on nor walks the real ~/.m2 of whoever runs it.
	--------------------------------------------------------------------------------

	local original_vim_system = vim.system
	local original_vim_schedule = vim.schedule

	local scans
	local scan_callbacks

	local function install()
		scans = {}
		scan_callbacks = {}

		rawset(vim, "schedule", function(fn)
			fn()
		end)

		rawset(vim, "system", function(cmd, _, on_exit)
			table.insert(scans, vim.deepcopy(cmd))
			table.insert(scan_callbacks, on_exit)
			return {}
		end)
	end

	local function restore()
		rawset(vim, "system", original_vim_system)
		rawset(vim, "schedule", original_vim_schedule)
	end

	-- A directory that really exists, so the scan is attempted.
	local root = vim.fn.tempname()

	vim.fn.mkdir(root, "p")

	local function new_source(local_repository)
		return {
			opts = {
				local_repository = local_repository or {
					path = root,
				},
			},
		}
	end

	local function catalog(source)
		local seen = {}

		LocalRepository.catalog(source, function(entries)
			seen.called = (seen.called or 0) + 1
			seen.entries = entries
		end)

		return seen
	end

	local function listing(paths)
		local lines = {}

		for _, path in ipairs(paths) do
			table.insert(lines, root .. "/" .. path)
		end

		return table.concat(lines, "\n") .. "\n"
	end

	--------------------------------------------------------------------------------
	-- CONFIG
	--------------------------------------------------------------------------------

	eq(
		LocalRepository.root(new_source()),
		root,
		"A configured path must be used as the repository root"
	)

	eq(
		LocalRepository.root({ opts = {} }),
		vim.fn.expand("~/.m2/repository"),
		"The default root must be the user's Maven repository"
	)

	--------------------------------------------------------------------------------
	-- SCAN
	--------------------------------------------------------------------------------

	install()

	local source = new_source()

	local first = catalog(source)
	local second = catalog(source)

	eq(#scans, 1, "Concurrent requests must share one scan")
	eq(scans[1][1], "find", "The scan must use find")
	eq(scans[1][2], root, "The scan must start at the repository root")
	eq(first.called, nil, "A request must wait for the scan to finish")

	scan_callbacks[1]({
		code = 0,
		stdout = listing({
			"org/example/demo/1.0.0/demo-1.0.0.pom",
			"org/example/demo/1.1.0/demo-1.1.0.pom",
			"com/company/client/2.0.0/client-2.0.0.pom",
			"too/short.pom",
		}) .. "/somewhere/else/a/b/1.0/b-1.0.pom\n",
	})

	local expected = {
		{
			g = "org.example",
			a = "demo",
			latestVersion = "1.1.0",
			versions = { "1.0.0", "1.1.0" },
		},
		{
			g = "com.company",
			a = "client",
			latestVersion = "2.0.0",
			versions = { "2.0.0" },
		},
	}

	eq(first.entries, expected, "A scan must yield one entry per coordinate")
	eq(second.entries, expected, "Every waiting request must receive the catalog")
	eq(first.called, 1, "A request must be answered exactly once")

	local third = catalog(source)

	eq(#scans, 1, "The repository must be scanned once per session")
	eq(third.entries, expected, "A later request must be served from memory")

	eq(
		source.local_repository_pipeline:stats(),
		{
			name = "local-repository",
			memory = 1,
			shared = 1,
			disk = 0,
			network = 1,
			errors = 0,
			entries = 1,
			running = 0,
		},
		"The scan must run on the shared pipeline"
	)

	--------------------------------------------------------------------------------
	-- VERSIONS
	--------------------------------------------------------------------------------

	local function versions_of(target, namespace, name)
		local seen = {}

		LocalRepository.versions(
			target,
			{ namespace = namespace, name = name },
			function(versions, err)
				seen.versions = versions
				seen.err = err
			end
		)

		return seen
	end

	eq(
		versions_of(source, "org.example", "demo"),
		{
			versions = {
				{ value = "1.0.0", timestamp = 0 },
				{ value = "1.1.0", timestamp = 0 },
			},
		},
		"Every version present on disk must be reported for a coordinate"
	)

	eq(
		versions_of(source, "org.example", "unknown"),
		{ versions = {} },
		"A coordinate that was never downloaded must yield no versions and no error"
	)

	eq(
		versions_of(source, "org.example.demo", ""),
		{ versions = {} },
		"A group and artifact must not be confused across the separator"
	)

	eq(#scans, 1, "Version lookups must reuse the session's scan")

	-- The newest version is decided by version order, not by text order.
	install()

	local ordered_source = new_source()
	local ordered = catalog(ordered_source)

	scan_callbacks[1]({
		code = 0,
		stdout = listing({
			"org/example/lib/9.0/lib-9.0.pom",
			"org/example/lib/10.0/lib-10.0.pom",
			"org/example/lib/10.0/lib-10.0-sources.pom",
			"org/example/lib/2.0-RC1/lib-2.0-RC1.pom",
		}),
	})

	eq(
		ordered.entries,
		{
			{
				g = "org.example",
				a = "lib",
				latestVersion = "10.0",
				versions = { "9.0", "10.0", "2.0-RC1" },
			},
		},
		"The latest version must be chosen by version order and each version listed once"
	)

	--------------------------------------------------------------------------------
	-- REGISTRY
	--------------------------------------------------------------------------------

	local registry = LocalRepository.REGISTRY

	eq(
		{
			id = registry.id,
			kind = registry.kind,
			offline = registry.offline,
			capabilities = registry.capabilities,
		},
		{
			id = "local",
			kind = "local",
			offline = true,
			capabilities = { versions = true },
		},
		"The local repository must describe itself as an offline registry"
	)

	local through_registry

	registry:versions(
		ordered_source,
		{ namespace = "org.example", name = "lib" },
		function(versions)
			through_registry = versions
		end
	)

	eq(
		#through_registry,
		3,
		"The registry must answer version lookups from the catalog"
	)

	eq(
		LocalRepository.is_enabled(new_source({ enabled = false })),
		false,
		"A disabled local repository must report itself as disabled"
	)

	eq(
		LocalRepository.is_enabled({ opts = {} }),
		true,
		"The local repository must be enabled by default"
	)

	--------------------------------------------------------------------------------
	-- FAILED SCAN
	--------------------------------------------------------------------------------

	install()

	source = new_source()

	local failed = catalog(source)

	scan_callbacks[1]({
		code = 2,
		stderr = "find: unknown predicate",
	})

	eq(failed.entries, {}, "A failed scan must yield an empty catalog")

	catalog(source)

	eq(#scans, 1, "A failed scan must not be repeated on every request")

	--------------------------------------------------------------------------------
	-- NOTHING TO SCAN
	--------------------------------------------------------------------------------

	install()

	local missing = catalog(new_source({
		path = root .. "/does-not-exist",
	}))

	eq(missing.entries, {}, "A missing repository must yield an empty catalog")
	eq(#scans, 0, "A missing repository must not be scanned")

	local disabled = catalog(new_source({
		enabled = false,
		path = root,
	}))

	eq(disabled.entries, {}, "A disabled local repository must yield nothing")
	eq(#scans, 0, "A disabled local repository must not be scanned")

	restore()

	vim.fn.delete(root, "rf")
end
