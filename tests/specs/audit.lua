local Audit = require("blink_deps.audit")
local Unified = require("blink_deps")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- Lookups go through the real transport with curl replaced, and their
	-- answers are reduced on a real worker thread, so they are waited for.
	--------------------------------------------------------------------------------

	local requests
	local answers

	local function install()
		requests = {}
		answers = {}

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
	end

	local function wait(condition)
		vim.wait(5000, condition, 5)
	end

	local function new_source(enabled)
		return Unified.new({
			cache = { enabled = false },
			retries = 0,
			security = { enabled = enabled ~= false },
		})
	end

	-- An OSV answer for a PyPI package: each vulnerability as
	-- { id, fixed, severity }, affecting everything below its fix, or
	-- everything when it has none.
	local function answer(name, vulnerabilities)
		local vulns = {}

		for _, vulnerability in ipairs(vulnerabilities) do
			local events = { { introduced = "0" } }

			if vulnerability[2] then
				table.insert(events, { fixed = vulnerability[2] })
			end

			table.insert(vulns, {
				id = vulnerability[1],
				summary = "Summary of " .. vulnerability[1],
				database_specific = vulnerability[3] and { severity = vulnerability[3] } or nil,
				affected = {
					{
						package = { ecosystem = "PyPI", name = name },
						ranges = { { type = "ECOSYSTEM", events = events } },
					},
				},
			})
		end

		answers[name]({
			code = 0,
			stdout = vim.json.encode({ vulns = vulns }) .. "\n200",
		})
	end

	local function run(source, lines)
		local seen = {
			reports = {},
		}

		seen.cancel = Audit.run(source, "requirements", lines, function(findings, progress)
			table.insert(seen.reports, { findings = findings, progress = progress })

			seen.findings = findings
			seen.progress = progress
		end)

		return seen
	end

	local function brief(findings)
		local list = {}

		for _, finding in ipairs(findings) do
			table.insert(
				list,
				string.format(
					"%d %s %s: %d, %s, fixed %s",
					finding.row,
					finding.label,
					finding.version,
					#finding.vulnerabilities,
					tostring(finding.severity),
					tostring(finding.fixed)
				)
			)
		end

		return list
	end

	--------------------------------------------------------------------------------
	-- NOTHING TO DO
	--------------------------------------------------------------------------------

	install()

	local off = run(new_source(false), { "requests==2.31.0" })

	eq(
		{ off.findings, off.progress, #requests },
		{ {}, { declared = 0, checked = 0, failed = 0, done = true }, 0 },
		"With lookups off a file is reported clean at once, and nothing is asked"
	)

	local seen_unsupported

	Audit.run(new_source(), "gradle", { 'implementation "g:a:1.0"' }, function(findings, progress)
		seen_unsupported = { findings, progress.done }
	end)

	eq(seen_unsupported, { {}, true }, "A manifest that cannot be listed is reported clean at once")

	local empty = run(new_source(), { "# nothing pinned", "flask" })

	eq(
		{ empty.findings, empty.progress, #requests },
		{ {}, { declared = 0, checked = 0, failed = 0, done = true }, 0 },
		"A file declaring no versions is reported clean at once"
	)

	--------------------------------------------------------------------------------
	-- A FILE
	--------------------------------------------------------------------------------

	install()

	local source = new_source()

	local audit = run(source, {
		"# requirements",
		"requests==2.31.0",
		"clean-pkg==1.0.0",
		"Django>=4.2,<5.0",
		"Requests==2.19.0  # an older pin of the same project",
		"nofix==0.1.0",
	})

	eq(
		requests,
		{ "requests", "clean-pkg", "django", "nofix" },
		"Each distinct package must be looked up once, however often the file names it"
	)

	eq(#audit.reports, 0, "Nothing is reported before an answer arrives")

	answer("clean-pkg", {})

	wait(function()
		return source.osv_pipeline:stats().network >= 1 and source.osv_pipeline:stats().running == 3
	end)

	eq(#audit.reports, 0, "A package with nothing against it is not worth a report of its own")

	answer("requests", {
		{ "GHSA-moderate", "2.32.0", "MODERATE" },
		{ "GHSA-critical", "2.20.0", "CRITICAL" },
		{ "GHSA-later", "2.32.4", "LOW" },
	})

	wait(function()
		return #audit.reports == 1
	end)

	eq(
		brief(audit.findings),
		{
			"2 requests 2.31.0: 2, moderate, fixed 2.32.4",
			"5 Requests 2.19.0: 3, critical, fixed 2.32.4",
		},
		"Every place a package is declared is judged at its own version"
	)

	eq(
		audit.progress,
		{ declared = 4, checked = 2, failed = 0, done = false },
		"Progress must say how far the check has come"
	)

	answer("nofix", { { "GHSA-open", nil, "HIGH" } })

	wait(function()
		return #audit.reports == 2
	end)

	answer("django", { { "GHSA-django", "4.2.5", nil } })

	wait(function()
		return audit.progress.done
	end)

	eq(
		brief(audit.findings),
		{
			"2 requests 2.31.0: 2, moderate, fixed 2.32.4",
			"4 Django 4.2: 1, nil, fixed 4.2.5",
			"5 Requests 2.19.0: 3, critical, fixed 2.32.4",
			"6 nofix 0.1.0: 1, high, fixed nil",
		},
		"Findings are in file order; a vulnerability without a fix leaves no version known to be clear"
	)

	eq(
		audit.progress,
		{ declared = 4, checked = 4, failed = 0, done = true },
		"The last report must say the check is done"
	)

	local finding = audit.findings[1]

	eq(
		{
			finding.row,
			finding.col,
			finding.end_col,
			finding.ecosystem,
			finding.package,
			finding.vulnerabilities[1].id,
			finding.vulnerabilities[1].summary,
		},
		{ 2, 10, 16, "pypi", { name = "requests" }, "GHSA-moderate", "Summary of GHSA-moderate" },
		"A finding must say where the version is written and what affects it"
	)

	-- What a report hands out is the caller's to keep.
	audit.findings[1].version = "tampered"

	local again = run(source, { "requests==2.31.0" })

	eq(#requests, 4, "A package already looked up this session must not be asked about again")

	eq(
		{ again.progress.done, brief(again.findings) },
		{ true, { "1 requests 2.31.0: 2, moderate, fixed 2.32.4" } },
		"With everything already known, the check finishes at once and is not affected by earlier callers"
	)

	--------------------------------------------------------------------------------
	-- A FEW AT A TIME
	--------------------------------------------------------------------------------

	install()

	local many = {}

	for index = 1, Audit.CONCURRENCY + 3 do
		table.insert(many, "pkg-" .. index .. "==1.0.0")
	end

	local crowded = run(new_source(), many)

	eq(#requests, Audit.CONCURRENCY, "Only a few packages may be looked up at once")

	answer("pkg-1", { { "GHSA-1", "2.0.0", "LOW" } })

	wait(function()
		return #requests == Audit.CONCURRENCY + 1
	end)

	eq(
		requests[#requests],
		"pkg-" .. (Audit.CONCURRENCY + 1),
		"As one lookup finishes the next package in the file is started"
	)

	for index = 2, Audit.CONCURRENCY + 3 do
		wait(function()
			return answers["pkg-" .. index] ~= nil
		end)

		answer("pkg-" .. index, {})
	end

	wait(function()
		return crowded.progress and crowded.progress.done
	end)

	eq(
		{ #requests, crowded.progress.checked, #crowded.findings },
		{ Audit.CONCURRENCY + 3, Audit.CONCURRENCY + 3, 1 },
		"Every package must be checked in the end"
	)

	--------------------------------------------------------------------------------
	-- FAILURES
	--------------------------------------------------------------------------------

	install()

	local partial = run(new_source(), { "good==1.0.0", "bad==1.0.0" })

	answers["bad"]({ code = 6, stderr = "curl: (6) Could not resolve host" })

	answer("good", { { "GHSA-good", "1.1.0", "HIGH" } })

	wait(function()
		return partial.progress and partial.progress.done
	end)

	eq(
		{ brief(partial.findings), partial.progress },
		{
			{ "1 good 1.0.0: 1, high, fixed 1.1.0" },
			{ declared = 2, checked = 2, failed = 1, done = true },
		},
		"A failed lookup is counted and does not hide what the others found"
	)

	--------------------------------------------------------------------------------
	-- CANCELLING
	--------------------------------------------------------------------------------

	install()

	local stopped_source = new_source()
	local stopped = run(stopped_source, { "first==1.0.0", "second==1.0.0" })

	stopped.cancel()

	answer("first", { { "GHSA-first", "2.0.0", "HIGH" } })

	wait(function()
		return stopped_source.osv_pipeline:stats().network >= 1
			and stopped_source.osv_pipeline:stats().running <= 1
	end)

	eq(#stopped.reports, 0, "A cancelled check must report nothing further")

	ok(
		stopped_source.osv_pipeline.memory ~= nil,
		"Cancelling a check must not discard what its lookups learn"
	)
end
