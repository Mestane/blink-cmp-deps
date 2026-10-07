local Audit = require("blink_deps.audit")
local Declared = require("blink_deps.declared")
local Manifests = require("blink_deps.manifests")
local Osv = require("blink_deps.osv")

--------------------------------------------------------------------------------
-- AUDIT VIEW
--
-- Shows what blink_deps.audit finds in a buffer as Neovim diagnostics: the
-- version is underlined and a line says what is wrong with it. Whatever the
-- user already has for diagnostics, signs, virtual text, ]d, a list of
-- them, applies to these without further configuration.
--
-- A buffer is checked when it is read and when it is written, not while it
-- is being typed in: the answer comes from a lookup per package, and a
-- version half typed is not one worth looking up.
--
-- All of this is off unless security lookups are on.
--------------------------------------------------------------------------------

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("blink_deps_audit")

local GROUP = "blink_deps_audit"

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

-- Diagnostics follow security lookups, and can be switched off on their
-- own to keep only the notes shown during completion.
function M.is_enabled(source)
	if not Osv.is_enabled(source) then
		return false
	end

	return source.opts.security.diagnostics ~= false
end

--------------------------------------------------------------------------------
-- FROM FINDINGS TO DIAGNOSTICS
--------------------------------------------------------------------------------

-- A vulnerability someone could be exploiting today is an error; one worth
-- knowing about is a warning; the rest, and anything OSV does not grade,
-- is information.
local SEVERITY = {
	critical = vim.diagnostic.severity.ERROR,
	high = vim.diagnostic.severity.ERROR,
	moderate = vim.diagnostic.severity.WARN,
	medium = vim.diagnostic.severity.WARN,
	low = vim.diagnostic.severity.INFO,
}

-- The identifier most people would search for: a CVE if any record names
-- one, otherwise the record's own id.
local function best_id(vulnerability)
	for _, alias in ipairs(vulnerability.aliases or {}) do
		if alias:match("^CVE%-") then
			return alias
		end
	end

	return vulnerability.id
end

function M.message(finding)
	local count = #finding.vulnerabilities

	local text = string.format(
		"%s %s: %d known %s",
		finding.label,
		finding.version,
		count,
		count == 1 and "vulnerability" or "vulnerabilities"
	)

	if finding.fixed then
		return text .. ", fixed in " .. finding.fixed
	end

	return text .. ", no fixed version recorded"
end

-- Pure: findings in, diagnostics out.
function M.to_diagnostics(findings)
	local diagnostics = {}

	for _, finding in ipairs(findings or {}) do
		table.insert(diagnostics, {
			lnum = finding.row - 1,
			col = finding.col,
			end_lnum = finding.row - 1,
			end_col = finding.end_col,
			severity = SEVERITY[finding.severity] or vim.diagnostic.severity.INFO,
			message = M.message(finding),
			source = "blink-cmp-deps",
			code = best_id(finding.vulnerabilities[1]),
			user_data = {
				blink_deps = finding,
			},
		})
	end

	return diagnostics
end

--------------------------------------------------------------------------------
-- WHICH MANIFEST A BUFFER IS
--
-- The first manifest matching the buffer's file whose dependencies can be
-- listed and which the user has not switched off. Nil for any other
-- buffer.
--------------------------------------------------------------------------------

local function manifest_of(source, bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
		return nil
	end

	local path = vim.api.nvim_buf_get_name(bufnr)

	if path == "" then
		return nil
	end

	for _, manifest in ipairs(Manifests.for_path(path)) do
		if Declared.supports(manifest.id)
			and (not source.enabled_sources or source.enabled_sources[manifest.id])
		then
			return manifest.id
		end
	end

	return nil
end

--------------------------------------------------------------------------------
-- REFRESH
--
-- Checks one buffer and shows what is found, replacing what was shown
-- before. A check still running for the buffer is cancelled.
--
-- on_done, optional, receives the last findings and progress.
--------------------------------------------------------------------------------

local running = {}

function M.refresh(source, bufnr, on_done)
	bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr

	if running[bufnr] then
		running[bufnr]()
		running[bufnr] = nil
	end

	local manifest_id = M.is_enabled(source) and manifest_of(source, bufnr) or nil

	if not manifest_id then
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.diagnostic.reset(M.NAMESPACE, bufnr)
		end

		if on_done then
			on_done({}, { declared = 0, checked = 0, failed = 0, done = true })
		end

		return
	end

	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- True while the buffer still holds the text that was checked. The
	-- change counter answers that cheaply when it has not moved; it also
	-- moves for things that leave the text as it was, such as finishing
	-- to load a file, so a moved counter is settled by comparing.
	local function unchanged()
		if vim.api.nvim_buf_get_changedtick(bufnr) == tick then
			return true
		end

		return vim.deep_equal(lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end

	running[bufnr] = Audit.run(
		source,
		manifest_id,
		lines,
		function(findings, progress)
			if progress.done then
				running[bufnr] = nil
			end

			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end

			-- The positions are those of the text that was checked. If
			-- the buffer has changed since, they may point anywhere;
			-- the next check will be right.
			if unchanged() then
				vim.diagnostic.set(M.NAMESPACE, bufnr, M.to_diagnostics(findings))
			end

			if progress.done and on_done then
				on_done(findings, progress)
			end
		end
	)
end

--------------------------------------------------------------------------------
-- SUMMARY
--
-- What :DepsAudit reports when a check finishes.
--------------------------------------------------------------------------------

function M.summary(findings, progress)
	if progress.declared == 0 then
		return "no pinned dependencies to check in this file"
	end

	local text

	if #findings == 0 then
		text = "no known vulnerabilities in "
			.. progress.declared
			.. (progress.declared == 1 and " package" or " packages")
	else
		text = #findings
			.. (#findings == 1 and " dependency has" or " dependencies have")
			.. " known vulnerabilities"
	end

	if progress.failed > 0 then
		text = text
			.. "; "
			.. progress.failed
			.. (progress.failed == 1 and " package" or " packages")
			.. " could not be checked"
	end

	return text
end

--------------------------------------------------------------------------------
-- ATTACH
--
-- Makes the given source the one that checks buffers: when they are read,
-- when they are written, and on :DepsAudit. Called again, it replaces the
-- previous source; a source with diagnostics off detaches.
--------------------------------------------------------------------------------

function M.attach(source)
	local group = vim.api.nvim_create_augroup(GROUP, { clear = true })

	pcall(vim.api.nvim_del_user_command, "DepsAudit")

	if not M.is_enabled(source) then
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			vim.diagnostic.reset(M.NAMESPACE, bufnr)
		end

		return false
	end

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		group = group,
		desc = "blink-cmp-deps: check declared dependencies",
		callback = function(event)
			M.refresh(source, event.buf)
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		desc = "blink-cmp-deps: stop checking a wiped buffer",
		callback = function(event)
			if running[event.buf] then
				running[event.buf]()
				running[event.buf] = nil
			end
		end,
	})

	vim.api.nvim_create_user_command("DepsAudit", function()
		local bufnr = vim.api.nvim_get_current_buf()

		if not manifest_of(source, bufnr) then
			vim.notify("blink-cmp-deps: this file is not one whose dependencies can be checked", vim.log.levels.WARN)
			return
		end

		M.refresh(source, bufnr, function(findings, progress)
			vim.notify(
				"blink-cmp-deps: " .. M.summary(findings, progress),
				(#findings > 0 or progress.failed > 0) and vim.log.levels.WARN or vim.log.levels.INFO
			)
		end)
	end, {
		desc = "Check this file's dependencies for known vulnerabilities",
	})

	-- Buffers opened before the source existed.
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			M.refresh(source, bufnr)
		end
	end

	return true
end

return M
