local Util = require("blink_deps.util")
return function(test)
	local eq = test.eq
	--------------------------------------------------------------------------------
	-- SHARED RESULT HELPERS
	--------------------------------------------------------------------------------
	local docs = Util.dedupe_docs({
		{
			g = "org.example",
			a = "demo",
			latestVersion = "1.0.0",
		},
		{
			g = "org.example",
			a = "demo",
			latestVersion = "1.0.0",
		},
		{
			g = "org.example",
			a = "other",
			latestVersion = "2.0.0",
		},
	})
	eq(
		#docs,
		2,
		"duplicate Central/JDTLS documents must be removed"
	)
	local artifacts = Util.extract_artifacts(
		docs,
		"org.example"
	)
	eq(
		#artifacts,
		2,
		"artifact extraction must preserve distinct artifacts"
	)
	eq(
		artifacts[1].artifact,
		"demo",
		"artifacts must be sorted by artifactId"
	)
	eq(
		artifacts[2].artifact,
		"other",
		"artifacts must be sorted by artifactId"
	)
	--------------------------------------------------------------------------------
	-- DEBUG LOG
	--------------------------------------------------------------------------------
	local debug_original_notify = vim.notify
	local debug_original_schedule = vim.schedule
	local debug_messages = {}
	vim.notify = function(message)
		table.insert(
			debug_messages,
			message
		)
	end
	-- The real vim.schedule defers to the event loop, which never runs
	-- during a synchronous test.
	vim.schedule = function(fn)
		fn()
	end
	Util.debug_log({ opts = {} }, "quiet")
	Util.debug_log(nil, "no source")
	Util.debug_log({}, "no opts")
	eq(
		#debug_messages,
		0,
		"debug log must stay silent unless debug is enabled"
	)
	Util.debug_log(
		{ opts = { debug = true } },
		"loud %s",
		"value"
	)
	eq(
		debug_messages,
		{ "[blink-cmp-deps] loud value" },
		"debug log must format and prefix the message"
	)
	vim.notify = debug_original_notify
	vim.schedule = debug_original_schedule
end
