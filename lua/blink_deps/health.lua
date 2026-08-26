local M = {}

function M.check()
	vim.health.start("blink-cmp-deps")

	if type(vim.system) == "function" then
		vim.health.ok("vim.system is available")
	else
		vim.health.error("vim.system is required")
	end

	if vim.fn.executable("curl") == 1 then
		vim.health.ok("curl is available")
	else
		vim.health.error("curl is required for dependency completion")
	end

	local ok_blink = pcall(require, "blink.cmp")
	if ok_blink then
		vim.health.ok("blink.cmp is available")
	else
		vim.health.error("blink.cmp could not be loaded")
	end

	vim.health.info("Maven Central is the default backend")
	vim.health.info("Maven, Gradle Groovy DSL, and Gradle Kotlin DSL completion are available")
	vim.health.info("JDTLS/vscode-maven integration is optional and disabled by default")
end

return M
