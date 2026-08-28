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
end
