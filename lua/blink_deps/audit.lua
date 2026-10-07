local Declared = require("blink_deps.declared")
local Osv = require("blink_deps.osv")
local Security = require("blink_deps.security")
local Util = require("blink_deps.util")

--------------------------------------------------------------------------------
-- AUDIT
--
-- Checks the dependencies a manifest declares against what is known about
-- them, and reports the ones with something wrong: where each is written,
-- and what is wrong with it.
--
-- It produces findings as plain data and shows nothing. Diagnostics are one
-- way to show them; a command, a picker or a quickfix list could show the
-- same findings another way.
--
-- Checking a file means one lookup per distinct package, and a manifest
-- may declare dozens. They are made a few at a time, and findings are
-- reported as they come in, so the first ones do not wait for the last.
--
-- Nothing is looked up unless the user has turned security lookups on.
--------------------------------------------------------------------------------

local M = {}

-- How many packages are looked up at once. Enough to finish a large
-- manifest in a few seconds, few enough not to look like a flood to the
-- service or to open dozens of connections.
M.CONCURRENCY = 4

local SEVERITY_ORDER = {
	critical = 1,
	high = 2,
	moderate = 3,
	medium = 3,
	low = 4,
}

--------------------------------------------------------------------------------
-- FINDINGS
--------------------------------------------------------------------------------

-- The most severe label among some vulnerabilities, or nil if none says.
local function worst_severity(vulnerabilities)
	local worst

	for _, vulnerability in ipairs(vulnerabilities) do
		local rank = SEVERITY_ORDER[vulnerability.severity]

		if rank and (not worst or rank < SEVERITY_ORDER[worst]) then
			worst = vulnerability.severity
		end
	end

	return worst
end

-- The lowest version that leaves every one of the vulnerabilities behind:
-- the highest of their fixed versions. Nil when any of them has no fix
-- recorded, since then no version is known to be clear.
local function clear_version(vulnerabilities, compare)
	local clear

	for _, vulnerability in ipairs(vulnerabilities) do
		if not vulnerability.fixed then
			return nil
		end

		if not clear or compare(vulnerability.fixed, clear) > 0 then
			clear = vulnerability.fixed
		end
	end

	return clear
end

local function package_key(entry)
	return entry.ecosystem
		.. "\n"
		.. (entry.package.namespace or "")
		.. "\n"
		.. entry.package.name
end

--------------------------------------------------------------------------------
-- RUN
--
-- source       the unified source: its options decide whether anything is
--              looked up, and it holds what is already known
-- manifest_id  which kind of manifest the lines are
-- lines        the file
-- report       function(findings, progress), called whenever more is known
--              and once more at the end
--
-- findings is the complete list so far, in file order, each
--
--   row, col, end_col  where the version is written (row 1 based, columns
--                      0 based bytes)
--   label              the package as the file writes it
--   version            the version declared
--   ecosystem, package what was looked up
--   vulnerabilities    what affects that version, as blink_deps.osv
--                      reports it
--   severity           the most severe label among them, or nil
--   fixed              the lowest version clear of all of them, or nil
--
-- progress is { declared, checked, failed, done }: how many distinct
-- packages the file declares, how many have been looked up, how many of
-- those lookups failed, and whether this is the last report.
--
-- Returns a function that cancels the run: nothing further is looked up or
-- reported.
--------------------------------------------------------------------------------

function M.run(source, manifest_id, lines, report)
	local probe = {
		opts = source.opts,
		root = source,
	}

	if not Osv.is_enabled(probe) or not Declared.supports(manifest_id) then
		report({}, { declared = 0, checked = 0, failed = 0, done = true })

		return function() end
	end

	local declared = Declared.scan(manifest_id, lines)

	-- One lookup per package, however many times the file names it.
	local queue = {}
	local entries_of = {}

	for _, entry in ipairs(declared) do
		local key = package_key(entry)

		if not entries_of[key] then
			entries_of[key] = {}
			table.insert(queue, key)
		end

		table.insert(entries_of[key], entry)
	end

	local progress = {
		declared = #queue,
		checked = 0,
		failed = 0,
		done = false,
	}

	local findings = {}
	local cancelled = false
	local running = 0
	local next_index = 1

	local function publish()
		table.sort(findings, function(left, right)
			if left.row ~= right.row then
				return left.row < right.row
			end

			return left.col < right.col
		end)

		report(vim.deepcopy(findings), vim.deepcopy(progress))
	end

	-- Judges every place a package is declared, once it has been looked up.
	local function judge_package(key)
		local entries = entries_of[key]
		local first = entries[1]

		local delegate = {
			opts = source.opts,
			root = source,
			ecosystem = first.ecosystem,
		}

		local judge = Security.judge(delegate, first.package)

		if not judge then
			return false
		end

		local compare = Osv.comparator(first.ecosystem)
		local added = false

		for _, entry in ipairs(entries) do
			local vulnerabilities = judge(entry.version)

			if #vulnerabilities > 0 then
				table.insert(findings, {
					row = entry.row,
					col = entry.col,
					end_col = entry.end_col,
					label = entry.label,
					version = entry.version,
					ecosystem = entry.ecosystem,
					package = entry.package,
					vulnerabilities = vulnerabilities,
					severity = worst_severity(vulnerabilities),
					fixed = clear_version(vulnerabilities, compare),
				})

				added = true
			end
		end

		return added
	end

	local start_next

	local function finished(key, err)
		running = running - 1

		if cancelled then
			return
		end

		progress.checked = progress.checked + 1

		local added = false

		if err then
			progress.failed = progress.failed + 1

			Util.debug_log(
				source,
				"Vulnerability lookup failed for %s: %s",
				entries_of[key][1].label,
				tostring(err)
			)
		else
			added = judge_package(key)
		end

		if progress.checked == progress.declared then
			progress.done = true
			publish()

			return
		end

		-- Reported only when there is something new to show; the end is
		-- always reported.
		if added then
			publish()
		end

		start_next()
	end

	start_next = function()
		while not cancelled and running < M.CONCURRENCY and next_index <= #queue do
			local key = queue[next_index]
			local first = entries_of[key][1]

			next_index = next_index + 1
			running = running + 1

			Osv.advisories(probe, first.ecosystem, first.package, function(_, err)
				finished(key, err)
			end)
		end
	end

	if #queue == 0 then
		progress.done = true
		publish()
	else
		start_next()
	end

	return function()
		cancelled = true
	end
end

return M
