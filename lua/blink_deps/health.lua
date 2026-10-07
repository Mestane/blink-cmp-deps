local M = {}

--------------------------------------------------------------------------------
-- :checkhealth blink_deps
--
-- Renders the report built by blink_deps.diagnostics. What is checked is
-- decided there; this only maps it onto vim.health.
--------------------------------------------------------------------------------

function M.check()
	local Diagnostics = require("blink_deps.diagnostics")
	local Source = require("blink_deps")

	-- The buffer :checkhealth was called from. By the time this runs the
	-- current buffer is the health report itself.
	local path = vim.fn.bufname("#")

	if path ~= "" then
		path = vim.fn.fnamemodify(path, ":p")
	end

	local report = Diagnostics.report({
		source = Source.latest(),
		path = path,
	})

	for _, section in ipairs(report) do
		vim.health.start(section.title)

		for _, entry in ipairs(section.entries) do
			if entry.level == "ok" then
				vim.health.ok(entry.text)
			elseif entry.level == "warn" then
				vim.health.warn(entry.text, entry.advice)
			elseif entry.level == "error" then
				vim.health.error(entry.text, entry.advice)
			else
				vim.health.info(entry.text)
			end
		end
	end
end

return M
