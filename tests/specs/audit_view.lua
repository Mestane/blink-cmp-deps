local Unified = require("blink_deps")
local View = require("blink_deps.audit_view")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- FROM FINDINGS TO DIAGNOSTICS
	--------------------------------------------------------------------------------

	local function finding(fields)
		return vim.tbl_extend("force", {
			row = 3,
			col = 10,
			end_col = 16,
			label = "requests",
			version = "2.31.0",
			ecosystem = "pypi",
			package = { name = "requests" },
			vulnerabilities = {
				{ id = "GHSA-aaaa", aliases = { "PYSEC-1", "CVE-2024-1" } },
				{ id = "GHSA-bbbb", aliases = {} },
			},
			severity = "moderate",
			fixed = "2.32.4",
		}, fields or {})
	end

	local diagnostic = View.to_diagnostics({ finding() })[1]

	eq(
		{
			diagnostic.lnum,
			diagnostic.col,
			diagnostic.end_lnum,
			diagnostic.end_col,
			diagnostic.severity,
			diagnostic.message,
			diagnostic.source,
			diagnostic.code,
		},
		{
			2,
			10,
			2,
			16,
			vim.diagnostic.severity.WARN,
			"requests 2.31.0: 2 known vulnerabilities, fixed in 2.32.4",
			"blink-cmp-deps",
			"CVE-2024-1",
		},
		"A finding must become a diagnostic over exactly the version, coded by the CVE people search for"
	)

	eq(
		diagnostic.user_data.blink_deps.vulnerabilities[2].id,
		"GHSA-bbbb",
		"The finding itself must travel with the diagnostic, for whoever wants the details"
	)

	for severity, expected in pairs({
		critical = vim.diagnostic.severity.ERROR,
		high = vim.diagnostic.severity.ERROR,
		moderate = vim.diagnostic.severity.WARN,
		medium = vim.diagnostic.severity.WARN,
		low = vim.diagnostic.severity.INFO,
		unheard = vim.diagnostic.severity.INFO,
	}) do
		eq(
			View.to_diagnostics({ finding({ severity = severity }) })[1].severity,
			expected,
			"A " .. severity .. " vulnerability must have the matching diagnostic severity"
		)
	end

	local ungraded = View.to_diagnostics({
		{
			row = 1,
			col = 0,
			end_col = 3,
			label = "x",
			version = "1.0",
			vulnerabilities = { { id = "OSV-1", aliases = {} } },
		},
	})[1]

	eq(
		{ ungraded.severity, ungraded.message, ungraded.code },
		{ vim.diagnostic.severity.INFO, "x 1.0: 1 known vulnerability, no fixed version recorded", "OSV-1" },
		"A vulnerability without a grade, a fix or a CVE must still be reported, as information"
	)

	eq(View.to_diagnostics({}), {}, "No findings means no diagnostics")
	eq(View.to_diagnostics(nil), {}, "Missing findings mean no diagnostics")

	--------------------------------------------------------------------------------
	-- SUMMARY
	--------------------------------------------------------------------------------

	local function summary(found, declared, failed)
		local findings = {}

		for _ = 1, found do
			table.insert(findings, {})
		end

		return View.summary(findings, { declared = declared, checked = declared, failed = failed, done = true })
	end

	eq(summary(0, 0, 0), "no pinned dependencies to check in this file", "A file with nothing to check must say so")
	eq(summary(0, 1, 0), "no known vulnerabilities in 1 package", "A clean file with one package")
	eq(summary(0, 12, 0), "no known vulnerabilities in 12 packages", "A clean file")
	eq(summary(1, 12, 0), "1 dependency has known vulnerabilities", "One finding is singular")
	eq(summary(3, 12, 0), "3 dependencies have known vulnerabilities", "Several findings are counted")

	eq(
		summary(3, 12, 2),
		"3 dependencies have known vulnerabilities; 2 packages could not be checked",
		"Packages that could not be checked must be mentioned"
	)

	eq(
		summary(0, 12, 1),
		"no known vulnerabilities in 12 packages; 1 package could not be checked",
		"A clean result with a failed lookup must not read as fully clean"
	)

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- Real buffers, real autocmds and real diagnostics; curl is replaced and
	-- answers are reduced on a real worker thread, so they are waited for.
	--------------------------------------------------------------------------------

	local requests
	local answers
	local notified

	local original_notify = vim.notify

	local function install()
		requests = {}
		answers = {}
		notified = {}

		rawset(vim, "system", function(cmd, _, on_exit)
			local name

			for position, argument in ipairs(cmd) do
				if argument == "--data-binary" then
					name = vim.json.decode(cmd[position + 1]).package.name
				end
			end

			table.insert(requests, name)
			answers[name] = on_exit

			return {}
		end)

		rawset(vim, "notify", function(message, level)
			table.insert(notified, { message, level })
		end)
	end

	local function wait(condition)
		vim.wait(5000, condition, 5)
	end

	local function options(security, extra)
		return vim.tbl_extend("force", {
			cache = { enabled = false },
			retries = 0,
			security = security,
		}, extra or {})
	end

	local function answer(name, fixed, severity)
		answers[name]({
			code = 0,
			stdout = vim.json.encode({
				vulns = fixed and {
					{
						id = "GHSA-" .. name,
						database_specific = { severity = severity or "HIGH" },
						affected = {
							{
								package = { ecosystem = "PyPI", name = name },
								ranges = {
									{ type = "ECOSYSTEM", events = { { introduced = "0" }, { fixed = fixed } } },
								},
							},
						},
					},
				} or {},
			}) .. "\n200",
		})
	end

	local directory = vim.fn.tempname()

	vim.fn.mkdir(directory, "p")

	local function write(name, lines)
		local path = directory .. "/" .. name

		vim.fn.writefile(lines, path)

		return path
	end

	local function shown(bufnr)
		local list = {}

		for _, entry in ipairs(vim.diagnostic.get(bufnr, { namespace = View.NAMESPACE })) do
			table.insert(list, string.format("%d:%d-%d %s", entry.lnum, entry.col, entry.end_col, entry.message))
		end

		return list
	end

	--------------------------------------------------------------------------------
	-- OFF
	--------------------------------------------------------------------------------

	install()

	eq(View.is_enabled(Unified.new(options(nil))), false, "Diagnostics are off while security lookups are off")
	eq(View.is_enabled(Unified.new(options({ enabled = true }))), true, "They follow security lookups on")

	eq(
		View.is_enabled(Unified.new(options({ enabled = true, diagnostics = false }))),
		false,
		"They can be switched off on their own"
	)

	vim.cmd("edit " .. vim.fn.fnameescape(write("requirements.txt", { "requests==2.31.0" })))

	eq(
		{ #requests, vim.fn.exists(":DepsAudit") },
		{ 0, 0 },
		"A source without security lookups must check nothing and define no command"
	)

	--------------------------------------------------------------------------------
	-- WHEN A FILE IS READ
	--------------------------------------------------------------------------------

	install()

	local source = Unified.new(options({ enabled = true }))

	-- The buffer was open before the source existed.
	local first = vim.api.nvim_get_current_buf()

	eq(requests, { "requests" }, "A buffer already open must be checked when the source is created")
	eq(vim.fn.exists(":DepsAudit"), 2, "The command must be defined")

	answer("requests", "2.32.0")

	wait(function()
		return #shown(first) > 0
	end)

	eq(
		shown(first),
		{ "0:10-16 requests 2.31.0: 1 known vulnerability, fixed in 2.32.0" },
		"What is found must be shown over the version"
	)

	-- Another file, read afterwards.
	install()

	vim.cmd("edit " .. vim.fn.fnameescape(write("requirements-dev.txt", { "# dev", "pytest==7.0.0", "clean==1.0.0" })))

	local second = vim.api.nvim_get_current_buf()

	eq(requests, { "pytest", "clean" }, "Reading a manifest must check it")

	answer("clean", nil)
	answer("pytest", "7.2.0", "MODERATE")

	wait(function()
		return #shown(second) > 0
	end)

	eq(
		shown(second),
		{ "1:8-13 pytest 7.0.0: 1 known vulnerability, fixed in 7.2.0" },
		"Only the dependency with something against it is marked"
	)

	eq(#shown(first), 1, "Checking one buffer must not disturb another's diagnostics")

	-- A file that is not a manifest.
	install()

	vim.cmd("edit " .. vim.fn.fnameescape(write("notes.txt", { "requests==2.31.0" })))

	eq(#requests, 0, "A file that is not a manifest must not be checked")

	--------------------------------------------------------------------------------
	-- WHEN A FILE IS WRITTEN
	--------------------------------------------------------------------------------

	install()

	vim.cmd("buffer " .. second)

	vim.api.nvim_buf_set_lines(second, 1, 2, false, { "pytest==7.2.0" })

	eq(#requests, 0, "Typing must not start a check")

	vim.cmd("silent write")

	wait(function()
		return #shown(second) == 0
	end)

	eq(
		{ shown(second), #requests },
		{ {}, 0 },
		"Writing the file checks it again, from what is already known, and clears a fixed finding"
	)

	--------------------------------------------------------------------------------
	-- A BUFFER THAT CHANGES WHILE IT IS CHECKED
	--------------------------------------------------------------------------------

	install()

	vim.cmd("edit " .. vim.fn.fnameescape(write("constraints.txt", { "slow==1.0.0" })))

	local changing = vim.api.nvim_get_current_buf()

	vim.api.nvim_buf_set_lines(changing, 0, 0, false, { "# added while the lookup was out" })

	answer("slow", "2.0.0")

	wait(function()
		return source.osv_pipeline:stats().running == 0
	end)

	vim.wait(50)

	eq(
		shown(changing),
		{},
		"Findings for text that has since changed must not be shown: their positions may be wrong"
	)

	vim.cmd("silent write")

	wait(function()
		return #shown(changing) > 0
	end)

	eq(
		shown(changing),
		{ "1:6-11 slow 1.0.0: 1 known vulnerability, fixed in 2.0.0" },
		"The next check must show them where the version now is"
	)

	--------------------------------------------------------------------------------
	-- :DepsAudit
	--------------------------------------------------------------------------------

	install()

	vim.cmd("DepsAudit")

	wait(function()
		return #notified > 0
	end)

	eq(
		notified[1],
		{ "blink-cmp-deps: 1 dependency has known vulnerabilities", vim.log.levels.WARN },
		"The command must check the current file and say what it found"
	)

	install()

	vim.cmd("buffer " .. second)
	vim.cmd("DepsAudit")

	wait(function()
		return #notified > 0
	end)

	eq(
		notified[1],
		{ "blink-cmp-deps: no known vulnerabilities in 2 packages", vim.log.levels.INFO },
		"A clean file must be reported as clean"
	)

	install()

	vim.cmd("edit " .. vim.fn.fnameescape(directory .. "/notes.txt"))
	vim.cmd("DepsAudit")

	eq(
		{ notified[1][2], #requests },
		{ vim.log.levels.WARN, 0 },
		"In a file that cannot be checked the command must say so and ask nothing"
	)

	--------------------------------------------------------------------------------
	-- SWITCHED OFF SOURCES
	--------------------------------------------------------------------------------

	install()

	-- Attaching another source replaces the first.
	Unified.new(options({ enabled = true }, { enabled_sources = { "maven" } }))

	install()

	vim.cmd("edit " .. vim.fn.fnameescape(write("requirements-other.txt", { "requests==2.31.0" })))

	eq(#requests, 0, "A manifest the user has switched off must not be checked")

	-- A source with diagnostics off detaches and clears what was shown.
	View.attach(Unified.new(options({ enabled = true, diagnostics = false })))

	eq(
		{ vim.fn.exists(":DepsAudit"), shown(first), shown(changing) },
		{ 0, {}, {} },
		"Turning diagnostics off must remove the command and everything shown"
	)

	--------------------------------------------------------------------------------
	-- SETUP
	--------------------------------------------------------------------------------

	install()

	local configured = Unified.setup(options({ enabled = true }))

	ok(Unified.latest() == configured, "setup must create the source at once")
	eq(vim.fn.exists(":DepsAudit"), 2, "setup must start what the plugin does outside completion")

	ok(
		Unified.new({}) == configured and Unified.new(nil) == configured,
		"A provider given no options of its own must be given the configured source"
	)

	ok(
		Unified.new({}, { opts = {} }) == configured,
		"The same holds when blink passes an empty provider config"
	)

	ok(
		Unified.new({ debug = true }) ~= configured,
		"A provider with options of its own gets a source of its own"
	)

	rawset(vim, "notify", original_notify)

	vim.cmd("silent! %bwipeout!")
	vim.fn.delete(directory, "rf")
end
