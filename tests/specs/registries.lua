local Central = require("blink_deps.central")
local Registries = require("blink_deps.registries")
local Repository = require("blink_deps.repository")

return function(test)
	local eq = test.eq
	local ok = test.ok

	local function ids(registries)
		local result = {}

		for _, registry in ipairs(registries) do
			table.insert(result, registry.id)
		end

		return result
	end

	--------------------------------------------------------------------------------
	-- LIST
	--------------------------------------------------------------------------------

	eq(
		ids(Registries.list({ opts = {} })),
		{ "local", "central" },
		"The local repository and Maven Central must be the default registries"
	)

	eq(
		ids(Registries.list({
			opts = {
				central = {
					enabled = false,
				},
			},
		})),
		{ "local" },
		"Disabling Maven Central must leave the local repository"
	)

	eq(
		ids(Registries.list({
			opts = {
				local_repository = {
					enabled = false,
				},
			},
		})),
		{ "central" },
		"Disabling the local repository must leave Maven Central"
	)

	eq(
		ids(Registries.list({
			opts = {
				central = {
					enabled = false,
				},
				local_repository = {
					enabled = false,
				},
			},
		})),
		{},
		"Disabling both must leave no registries"
	)

	local configured = {
		opts = {
			repositories = {
				{
					name = "Company",
					url = "https://repo.company.test/maven/",
				},
				{
					name = "Company Nexus",
					type = "nexus",
					url = "https://nexus.company.test",
					repository = "maven-releases",
				},
				-- Unusable entries: skipped, not fatal.
				{ name = "No URL" },
				{ type = "nexus", url = "https://nexus.company.test" },
				"not a table",
				-- The first entry again, spelled differently.
				{
					name = "Duplicate",
					url = "https://repo.company.test/maven",
				},
			},
		},
	}

	eq(
		ids(Registries.list(configured)),
		{
			"local",
			"central",
			"maven:https://repo.company.test/maven",
			"nexus:https://nexus.company.test/repository/maven-releases",
		},
		"The local repository comes first, then configuration order, skipping invalid and duplicate entries"
	)

	ok(
		Registries.list(configured) == Registries.list(configured),
		"The registry list must be built once per source"
	)

	eq(
		ids(Registries.list({
			opts = {
				repositories = "not a list",
			},
		})),
		{ "local", "central" },
		"A malformed repositories option must be ignored"
	)

	--------------------------------------------------------------------------------
	-- CONTRACT
	--------------------------------------------------------------------------------

	for _, registry in ipairs(Registries.list(configured)) do
		ok(
			type(registry.id) == "string" and registry.id ~= "",
			"A registry must have an id"
		)

		ok(
			type(registry.name) == "string" and registry.name ~= "",
			"A registry must have a name"
		)

		ok(
			type(registry.kind) == "string",
			"A registry must declare its kind"
		)

		ok(
			type(registry.capabilities) == "table",
			"A registry must declare its capabilities"
		)

		for capability in pairs(registry.capabilities) do
			ok(
				type(registry[capability]) == "function",
				"Registry "
					.. registry.id
					.. " must implement its declared capability "
					.. capability
			)
		end
	end

	local described = {}

	for _, registry in ipairs(Registries.list(configured)) do
		table.insert(described, {
			name = registry.name,
			kind = registry.kind,
		})
	end

	eq(
		described,
		{
			{ name = "Local repository", kind = "local" },
			{ name = "Maven Central", kind = "central" },
			{ name = "Company", kind = "maven" },
			{ name = "Company Nexus", kind = "nexus" },
		},
		"Registries must carry the configured name and their kind"
	)

	local offline = {}

	for _, registry in ipairs(Registries.list(configured)) do
		if registry.offline then
			table.insert(offline, registry.id)
		end
	end

	eq(
		offline,
		{ "local" },
		"Only the local repository must be marked as answering from disk"
	)

	--------------------------------------------------------------------------------
	-- CAPABILITY FILTER
	--------------------------------------------------------------------------------

	eq(
		ids(Registries.with(configured, "versions")),
		ids(Registries.list(configured)),
		"Every current registry must provide versions"
	)

	eq(
		ids(Registries.with(configured, "packages")),
		{
			"central",
			"nexus:https://nexus.company.test/repository/maven-releases",
		},
		"Only registries with a search API must list the packages of a namespace"
	)

	eq(
		Registries.with(configured, "no_such_operation"),
		{},
		"An unknown capability must match no registry"
	)

	ok(
		Registries.with(configured, "versions")
			== Registries.with(configured, "versions"),
		"A capability filter must be computed once per source"
	)

	-- A registry that does not declare an operation is never offered for it.
	local partial = {
		opts = {},
		registry_list = {
			{
				id = "a",
				capabilities = { versions = true },
			},
			{
				id = "b",
				capabilities = {},
			},
		},
	}

	eq(
		ids(Registries.with(partial, "versions")),
		{ "a" },
		"Only registries declaring a capability must be returned for it"
	)

	--------------------------------------------------------------------------------
	-- DISPATCH
	--------------------------------------------------------------------------------

	do
		local Util = require("blink_deps.util")
		local original_defer = Util.defer

		local delays = {}
		local deferred = {}

		rawset(Util, "defer", function(ms, fn)
			table.insert(delays, ms)
			table.insert(deferred, fn)
		end)

		local function dispatch_source(registries)
			return {
				opts = {},
				registry_list = registries,
			}
		end

		local visited = {}

		local function visit(registry)
			table.insert(visited, registry.id)
		end

		local mixed = dispatch_source({
			{ id = "remote-a", capabilities = { versions = true } },
			{ id = "disk", offline = true, capabilities = { versions = true } },
			{ id = "other", capabilities = { packages = true } },
			{ id = "remote-b", capabilities = { versions = true } },
		})

		local count = Registries.dispatch(
			mixed,
			"versions",
			{ debounce_ms = 250 },
			visit
		)

		eq(count, 3, "Dispatch must report how many registries will be visited")
		eq(visited, { "disk" }, "A registry answering from disk must be visited at once")
		eq(delays, { 250 }, "Remote registries must be deferred by the debounce")

		deferred[1]()

		eq(
			visited,
			{ "disk", "remote-a", "remote-b" },
			"Remote registries must be visited in order after the debounce"
		)

		-- Cancelled during the debounce: the network is never touched.
		visited = {}
		deferred = {}

		Registries.dispatch(
			mixed,
			"versions",
			{
				debounce_ms = 250,
				cancelled = function()
					return true
				end,
			},
			visit
		)

		deferred[1]()

		eq(
			visited,
			{ "disk" },
			"A request cancelled during the debounce must not visit remote registries"
		)

		-- Nothing remote: no timer is started at all.
		deferred = {}

		Registries.dispatch(
			dispatch_source({
				{ id = "disk", offline = true, capabilities = { versions = true } },
			}),
			"versions",
			{ debounce_ms = 250 },
			visit
		)

		eq(#deferred, 0, "Without remote registries no timer must be started")

		eq(
			Registries.dispatch(
				dispatch_source({}),
				"versions",
				{ debounce_ms = 250 },
				visit
			),
			0,
			"Dispatch over no registries must report zero"
		)

		rawset(Util, "defer", original_defer)
	end

	--------------------------------------------------------------------------------
	-- INVALID REPOSITORY
	--------------------------------------------------------------------------------

	eq(Repository.registry(nil), nil, "A missing repository must yield no registry")
	eq(Repository.registry({}), nil, "A repository without a URL must yield no registry")

	--------------------------------------------------------------------------------
	-- VERSIONS THROUGH THE CONTRACT
	--
	-- Network behaviour is covered by the central and repository specs. These
	-- cover the shape every registry must answer in.
	--------------------------------------------------------------------------------

	local original_vim_system = vim.system
	local original_vim_schedule = vim.schedule

	local requests = {}
	local answers = {}

	rawset(vim, "schedule", function(fn)
		fn()
	end)

	rawset(vim, "system", function(cmd, _, on_exit)
		table.insert(requests, vim.deepcopy(cmd))
		table.insert(answers, on_exit)
		return {}
	end)

	local source = {
		opts = {
			cache = {
				enabled = false,
			},
			-- Left out so the spec never walks a real ~/.m2. The local
			-- registry has its own spec.
			local_repository = {
				enabled = false,
			},
			repositories = {
				{
					name = "Company",
					url = "https://repo.company.test/maven",
				},
			},
		},
	}

	local package = {
		namespace = "com.company",
		name = "demo",
	}

	local results = {}

	for _, registry in ipairs(Registries.with(source, "versions")) do
		registry:versions(source, package, function(versions, err)
			results[registry.id] = {
				versions = versions,
				err = err,
			}
		end)
	end

	eq(#requests, 2, "Each registry must issue its own request")

	ok(
		vim.tbl_contains(requests[1], "q=g:com.company AND a:demo"),
		"Maven Central must be asked for the exact coordinate"
	)

	ok(
		vim.tbl_contains(requests[1], "core=gav"),
		"Maven Central must be asked for individual versions"
	)

	ok(
		vim.tbl_contains(requests[1], "rows=" .. tostring(Central.VERSION_ROWS)),
		"Maven Central must be asked for the configured number of versions"
	)

	eq(
		requests[2][#requests[2]],
		"https://repo.company.test/maven/com/company/demo/maven-metadata.xml",
		"A Maven repository must be asked for the artifact metadata"
	)

	answers[1]({
		code = 0,
		stdout = vim.json.encode({
			response = {
				numFound = 3,
				docs = {
					{ g = "com.company", a = "demo", v = "2.0.0", timestamp = 2000 },
					{ g = "com.company", a = "demo", v = "1.0.0", timestamp = 1000 },
					{ g = "com.company", a = "demo" },
				},
			},
		}) .. "\n200",
	})

	answers[2]({
		code = 0,
		stdout = "<metadata><versioning><versions>"
			.. "<version>3.0.0-company</version>"
			.. "</versions></versioning></metadata>\n200",
	})

	eq(
		results.central,
		{
			versions = {
				{ value = "2.0.0", timestamp = 2000 },
				{ value = "1.0.0", timestamp = 1000 },
			},
		},
		"Maven Central versions must carry their publication time"
	)

	eq(
		results["maven:https://repo.company.test/maven"],
		{
			versions = {
				{ value = "3.0.0-company", timestamp = 0 },
			},
		},
		"Repository versions must use the same shape, without a publication time"
	)

	-- Failure: an empty list and the error, never a raise.
	results = {}

	local failing = {
		namespace = "com.company",
		name = "missing",
	}

	for _, registry in ipairs(Registries.with(source, "versions")) do
		registry:versions(source, failing, function(versions, err)
			results[registry.id] = {
				versions = versions,
				err = err,
			}
		end)
	end

	-- Central fails at the transport level and retries once; the retry is
	-- a new request, issued after the repository's.
	answers[3]({
		code = 7,
		stderr = "curl: (7) Failed to connect",
	})

	answers[4]({
		code = 0,
		stdout = "Not Found\n404",
	})

	answers[5]({
		code = 7,
		stderr = "curl: (7) Failed to connect",
	})

	eq(
		results,
		{
			central = {
				versions = {},
				err = "curl: (7) Failed to connect",
			},
			["maven:https://repo.company.test/maven"] = {
				versions = {},
				err = "HTTP 404",
			},
		},
		"A failing registry must answer with an empty list and its error"
	)

	rawset(vim, "system", original_vim_system)
	rawset(vim, "schedule", original_vim_schedule)
end
