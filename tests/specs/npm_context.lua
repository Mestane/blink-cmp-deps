local Context = require("blink_deps.npm_context")

return function(test)
	local eq = test.eq

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A fixture is a package.json fragment with a cursor mark in it. The
	-- mark is not | as in the other context specs, because | is part of the
	-- range syntax being tested.
	--------------------------------------------------------------------------------

	local MARK = "‸"

	local function at(fixture)
		local lines = vim.split(fixture, "\n", { plain = true })

		for row, line in ipairs(lines) do
			local column = line:find(MARK, 1, true)

			if column then
				lines[row] = line:sub(1, column - 1) .. line:sub(column + #MARK)

				return Context.at(lines, row, column - 1)
			end
		end

		error("fixture has no cursor")
	end

	local function summary(fixture)
		local ctx = at(fixture)

		if not ctx then
			return nil
		end

		ctx.row = nil
		ctx.col = nil

		return ctx
	end

	--------------------------------------------------------------------------------
	-- PACKAGE NAMES
	--------------------------------------------------------------------------------

	eq(
		summary('{\n  "dependencies": {\n    "rea‸"\n  }\n}'),
		{ kind = "name", value = "rea", section = "dependencies", form = "key" },
		"A key being typed in a dependency section is a package name"
	)

	eq(
		summary('{ "dependencies": { "react": "^18.2.0", "@types/no‸" } }'),
		{ kind = "name", value = "@types/no", section = "dependencies", form = "key" },
		"A later key is a package name too, scope included"
	)

	eq(
		summary('{ "dependencies": { "‸" } }').value,
		"",
		"An empty key is where a package name goes"
	)

	for _, section in ipairs({
		"dependencies",
		"devDependencies",
		"peerDependencies",
		"optionalDependencies",
	}) do
		eq(
			summary('{ "' .. section .. '": { "rea‸": "" } }').section,
			section,
			section .. " must be recognised"
		)
	end

	eq(
		summary('{ "bundledDependencies": ["react", "rea‸"] }'),
		{ kind = "name", value = "rea", section = "bundledDependencies", form = "list" },
		"An element of bundledDependencies is a package name"
	)

	eq(
		summary('{ "bundleDependencies": ["rea‸"] }').form,
		"list",
		"The other spelling of bundledDependencies must be recognised"
	)

	eq(summary('{ "dep‸" }'), nil, "A top level key is not a package name")
	eq(summary('{ "scripts": { "bui‸" } }'), nil, "A key in another section is not a package name")
	eq(summary('{ "files": ["di‸"] }'), nil, "An element of another array is not a package name")
	eq(summary('{ "name": "my-pa‸" }'), nil, "The package's own name is not a dependency")

	eq(
		summary('{ "config": { "dependencies": { "rea‸" } } }'),
		nil,
		"A nested object that happens to be called dependencies is not a dependency section"
	)

	--------------------------------------------------------------------------------
	-- VERSIONS
	--------------------------------------------------------------------------------

	eq(
		summary('{\n  "dependencies": {\n    "react": "^18.‸"\n  }\n}'),
		{
			kind = "version",
			value = "18.",
			range = "^18.",
			package = "react",
			section = "dependencies",
		},
		"A value in a dependency section is a version of its key"
	)

	eq(
		summary('{ "devDependencies": { "@types/node": "‸" } }'),
		{
			kind = "version",
			value = "",
			range = "",
			package = "@types/node",
			section = "devDependencies",
		},
		"A scoped package keeps its scope"
	)

	eq(
		summary('{ "dependencies": { "a": "1.0.0", "react": "18‸", "z": "2.0.0" } }').package,
		"react",
		"Neighbouring dependencies must not interfere"
	)

	eq(
		summary('{ "version": "1.0.‸" }'),
		nil,
		"The package's own version is not a dependency version"
	)

	eq(
		summary('{ "engines": { "node": ">=18‸" } }'),
		nil,
		"An engine constraint is not a dependency version"
	)

	--------------------------------------------------------------------------------
	-- RANGE OPERATORS
	--------------------------------------------------------------------------------

	local function typed(range)
		local ctx = summary('{ "dependencies": { "react": "' .. range .. '‸" } }')

		return ctx and { ctx.value, ctx.range } or nil
	end

	eq(typed("^18.2"), { "18.2", "^18.2" }, "A caret is not part of the version being typed")
	eq(typed("~18."), { "18.", "~18." }, "A tilde is not part of the version being typed")
	eq(typed(">=17.0.0 <19"), { "19", ">=17.0.0 <19" }, "Only the last comparator is being typed")
	eq(typed("17.x || 18"), { "18", "17.x || 18" }, "Only the last alternative is being typed")
	eq(typed("17 || "), { "", "17 || " }, "An alternative with no version yet has nothing typed")
	eq(typed("18.0.0-rc."), { "18.0.0-rc.", "18.0.0-rc." }, "A prerelease is one version")
	eq(typed("lat"), { "lat", "lat" }, "A dist tag being typed is offered completion like a version")

	--------------------------------------------------------------------------------
	-- NOT A REGISTRY RANGE
	--------------------------------------------------------------------------------

	for _, reference in ipairs({
		"workspace:*",
		"workspace:^",
		"file:../local",
		"link:../local",
		"git+https://github.com/x/y.git",
		"https://example.test/pkg.tgz",
		"github:user/repo",
		"user/repo",
		"catalog:",
	}) do
		eq(
			typed(reference),
			nil,
			"'" .. reference .. "' is a reference to something else, not a range"
		)
	end

	--------------------------------------------------------------------------------
	-- ALIASES
	--------------------------------------------------------------------------------

	eq(
		summary('{ "dependencies": { "react-17": "npm:react@^17.‸" } }'),
		{
			kind = "version",
			value = "17.",
			range = "^17.",
			package = "react",
			alias = "react-17",
			section = "dependencies",
		},
		"An alias completes the versions of the package it points to"
	)

	eq(
		summary('{ "dependencies": { "types": "npm:@types/node@‸" } }').package,
		"@types/node",
		"The @ that opens a scope is not the one before the version"
	)

	eq(
		summary('{ "dependencies": { "react-17": "npm:rea‸" } }'),
		{
			kind = "name",
			value = "rea",
			form = "alias",
			alias = "react-17",
			section = "dependencies",
		},
		"Before the @, an alias is naming its package"
	)

	eq(
		summary('{ "dependencies": { "types": "npm:@types/no‸" } }').kind,
		"name",
		"A scoped name in an alias is still a name until its version starts"
	)

	eq(
		summary('{ "dependencies": { "react": "npm:react@18‸" } }').alias,
		nil,
		"An alias to the same name is not reported as an alias"
	)

	--------------------------------------------------------------------------------
	-- OVERRIDES AND RESOLUTIONS
	--------------------------------------------------------------------------------

	eq(
		summary('{ "overrides": { "react": "18.‸" } }'),
		{
			kind = "version",
			value = "18.",
			range = "18.",
			package = "react",
			section = "overrides",
		},
		"An override is a version of the package it names"
	)

	eq(
		summary('{ "overrides": { "react@^17": "18.‸" } }'),
		{
			kind = "version",
			value = "18.",
			range = "18.",
			package = "react",
			alias = "react@^17",
			section = "overrides",
		},
		"An override selector with a range still names the package"
	)

	eq(
		summary('{ "overrides": { "@scope/pkg@1": "2.‸" } }').package,
		"@scope/pkg",
		"A scoped override selector keeps its scope and loses its range"
	)

	eq(
		summary('{ "overrides": { "parent": { "child": "1.‸" } } }').package,
		"child",
		"A nested override is about the innermost package"
	)

	eq(
		summary('{ "overrides": { "parent": { ".": "1.‸", "child": "2.0.0" } } }').package,
		"parent",
		"A dot stands for the package the enclosing override is about"
	)

	eq(
		summary('{ "overrides": { ".": "1.‸" } }'),
		nil,
		"A dot at the top of overrides stands for nothing"
	)

	eq(
		summary('{ "resolutions": { "**/react": "18.‸" } }').package,
		"react",
		"A yarn resolution pattern names the last package in its path"
	)

	eq(
		summary('{ "resolutions": { "parent/@scope/name": "1.‸" } }').package,
		"@scope/name",
		"A scoped package at the end of a resolution path keeps its scope"
	)

	eq(
		summary('{ "resolutions": { "@scope/name": "1.‸" } }').package,
		"@scope/name",
		"A plain scoped resolution is that package"
	)

	eq(
		summary('{ "pnpm": { "overrides": { "parent>child@1": "2.‸" } } }'),
		{
			kind = "version",
			value = "2.",
			range = "2.",
			package = "child",
			alias = "parent>child@1",
			section = "pnpm",
		},
		"A pnpm override names the package after the last >"
	)

	eq(
		summary('{ "pnpm": { "patchedDependencies": { "react@18": "patches/‸" } } }'),
		nil,
		"Other pnpm settings are not versions"
	)

	eq(
		summary('{ "overrides": { "rea‸" } }'),
		nil,
		"An override key is a selector, not a plain package name"
	)

	--------------------------------------------------------------------------------
	-- STRINGS AND ESCAPES
	--------------------------------------------------------------------------------

	eq(
		summary('{ "description": "say \\"dependencies\\": {", "dependencies": { "react": "18‸" } }').package,
		"react",
		"An escaped quote must not end a string"
	)

	eq(
		summary('{ "description": "a { [ : , b", "dependencies": { "react": "18‸" } }').package,
		"react",
		"Punctuation inside a string is not structure"
	)

	eq(
		summary('{ "keywords": ["a", "b"], "dependencies": { "react": "18‸" } }').package,
		"react",
		"An array before the section must be closed properly"
	)

	eq(
		summary('{ "scripts": { "x": "y" }, "dependencies": { "react": "18‸" } }').package,
		"react",
		"An object before the section must be closed properly"
	)

	--------------------------------------------------------------------------------
	-- NOT IN A STRING
	--------------------------------------------------------------------------------

	eq(summary('{ "dependencies": { ‸ } }'), nil, "Outside a string there is nothing to complete")
	eq(summary('{ "dependencies": { "react": ‸ } }'), nil, "Before a value's quote there is nothing to complete")
	eq(summary('{ "dependencies": { "react": "18"‸ } }'), nil, "After a closed string there is nothing to complete")
	eq(summary('{ "dependencies": { "react"‸: "18" } }'), nil, "After a closed key there is nothing to complete")
	eq(summary("‸"), nil, "An empty buffer has no context")

	--------------------------------------------------------------------------------
	-- MALFORMED INPUT
	--------------------------------------------------------------------------------

	eq(
		summary('{\n  "dependencies": {\n    "broken": "1\n    "react": "18‸"\n  }\n}').kind,
		"version",
		"A string left open on an earlier line must not swallow the next one"
	)

	eq(
		summary('["dependencies", { "react": "18‸" }]'),
		nil,
		"A file that is not an object has no dependency sections"
	)

	eq(
		summary('{ "dependencies": { "react": "1", "": "2‸" } }'),
		nil,
		"A value under an empty key belongs to no package"
	)

	eq(
		summary('{ "dependencies": { "react" "18‸" } }'),
		nil,
		"A value without its colon is not yet a value"
	)

	--------------------------------------------------------------------------------
	-- POSITION
	--------------------------------------------------------------------------------

	local positioned = at('{\n  "dependencies": {\n    "react": "^18.‸"\n  }\n}')

	eq(
		{ positioned.row, positioned.col, #positioned.value },
		{ 3, #'    "react": "^18.', 3 },
		"The position and the typed value must give the range to replace"
	)

	eq(Context.at({ "{}" }, 9, 0), nil, "A cursor beyond the buffer must not raise")
	eq(Context.at(nil, 1, 0), nil, "A missing buffer must not raise")

	--------------------------------------------------------------------------------
	-- ROBUSTNESS
	--------------------------------------------------------------------------------

	local hostile = {
		"}}}]]]",
		'{{{{[[[["',
		'{ "dependencies": { "a": "\\',
		'{ "overrides": { ".": { ".": { ".": "',
		'{ "pnpm": { "overrides": { ">>>@@@": "',
		'{ "resolutions": { "////@@//": "',
		'{ "dependencies": { "x": "npm:@@@@',
		"\0{\255\"dependencies\"\0:{\"",
		string.rep('{ "dependencies": ', 60) .. '"',
		'{ "dependencies": { "a": "%d+%s*(.-)" , "',
	}

	local raised

	for _, fixture in ipairs(hostile) do
		local lines = vim.split(fixture, "\n", { plain = true })

		for row, line in ipairs(lines) do
			for col = 0, #line do
				if not pcall(Context.at, lines, row, col) then
					raised = fixture
				end
			end
		end
	end

	eq(raised, nil, "No position in a malformed buffer may raise")
end
