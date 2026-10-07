local Context = require("blink_deps.pyproject_context")

return function(test)
	local eq = test.eq

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A fixture is a pyproject.toml fragment with a cursor mark in it.
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
	-- REQUIREMENT STRINGS
	--------------------------------------------------------------------------------

	eq(
		summary('[project]\ndependencies = ["reque‸"]'),
		{ kind = "name", value = "reque", style = "pep508" },
		"A string in project.dependencies starts with a project name"
	)

	eq(
		summary('[project]\ndependencies = ["rich", "requests>=2.3‸"]'),
		{
			kind = "version",
			value = "2.3",
			operator = ">=",
			package = "requests",
			normalized = "requests",
			extras = {},
			style = "pep508",
		},
		"After an operator the cursor is in a version, in any element"
	)

	eq(
		summary('[project]\ndependencies = ["requests[sec‸"]').kind,
		"extra",
		"Inside brackets the cursor is in an extra"
	)

	eq(
		summary('[project]\ndependencies = ["‸"]'),
		{ kind = "name", value = "", style = "pep508" },
		"An empty string is where a project name goes"
	)

	-- The usual layout: one requirement per line.
	eq(
		summary('[project]\nname = "demo"\ndependencies = [\n    "rich",\n    "Typing_Extensions>=4.‸",\n]').normalized,
		"typing-extensions",
		"An array spread over lines must be read as one array"
	)

	eq(
		summary('[project]\ndependencies = [\n    "rich",  # terminal output\n    "reque‸",\n]').kind,
		"name",
		"A comment inside the array must not end it"
	)

	eq(
		summary('[project]\ndependencies = ["requests>=2 ; python_version >= \'3.‸"]'),
		nil,
		"An environment marker is not completed"
	)

	eq(
		summary('[project]\ndependencies = ["pkg @ https://example.test/p‸"]'),
		nil,
		"A direct URL is not completed"
	)

	--------------------------------------------------------------------------------
	-- WHERE REQUIREMENT ARRAYS LIVE
	--------------------------------------------------------------------------------

	for description, fixture in pairs({
		["optional dependencies"] = '[project.optional-dependencies]\ndev = ["pytest>=‸"]',
		["optional dependencies, dotted"] = '[project]\noptional-dependencies.dev = ["pytest>=‸"]',
		["dependency groups"] = '[dependency-groups]\ntest = ["pytest>=‸"]',
		["build requirements"] = '[build-system]\nrequires = ["setuptools>=‸"]',
		["uv dev dependencies"] = '[tool.uv]\ndev-dependencies = ["ruff>=‸"]',
		["uv constraints"] = '[tool.uv]\nconstraint-dependencies = ["grpcio>=‸"]',
		["pdm dev dependencies"] = '[tool.pdm.dev-dependencies]\ntest = ["pytest>=‸"]',
		["hatch environments"] = '[tool.hatch.envs.default]\ndependencies = ["pytest>=‸"]',
		["hatch extra dependencies"] = '[tool.hatch.envs.docs]\nextra-dependencies = ["mkdocs>=‸"]',
	}) do
		local ctx = summary(fixture)

		eq(
			ctx and { ctx.kind, ctx.operator, ctx.style },
			{ "version", ">=", "pep508" },
			"Requirements must be recognised in " .. description
		)
	end

	-- Strings that are not requirements.
	eq(summary('[project]\nname = "reque‸"'), nil, "The project's own name is not a dependency")
	eq(summary('[project]\nversion = "1.0.‸"'), nil, "The project's own version is not a dependency")
	eq(summary('[project]\nkeywords = ["reque‸"]'), nil, "Another array is not a list of requirements")
	eq(
		summary('[project]\nclassifiers = [\n  "Programming Language :: Pyth‸",\n]'),
		nil,
		"Classifiers are not requirements"
	)
	eq(summary('[tool.ruff]\nselect = ["E‸"]'), nil, "A tool's settings are not requirements")
	eq(summary('[project.scripts]\ndemo = "demo:ma‸"'), nil, "An entry point is not a dependency")
	eq(summary('[project]\ndependencies = "reque‸"'), nil, "A requirement must be an element of the array")
	eq(summary('[project.dependencies]\nx = ["reque‸"]'), nil, "A key under dependencies is not the list itself")

	eq(
		summary('[dependency-groups]\ntest = ["pytest", { include-group = "ba‸" }]'),
		nil,
		"An included group is a reference, not a requirement"
	)

	eq(
		summary('[project]\ndependencies = [["reque‸"]]'),
		nil,
		"A nested array is not a list of requirements"
	)

	--------------------------------------------------------------------------------
	-- POETRY: NAMES
	--------------------------------------------------------------------------------

	eq(
		summary("[tool.poetry.dependencies]\nreque‸"),
		{ kind = "name", value = "reque", form = "key", style = "poetry" },
		"A key being typed in a Poetry table is a project name"
	)

	eq(
		summary('[tool.poetry.dependencies]\npython = "^3.11"\n‸'),
		{ kind = "name", value = "", form = "key", style = "poetry" },
		"An empty line in a Poetry table is where a project name goes"
	)

	eq(
		summary("[tool.poetry.group.dev.dependencies]\npyte‸").kind,
		"name",
		"A dependency group's table must be recognised"
	)

	eq(
		summary("[tool.poetry.dev-dependencies]\npyte‸").kind,
		"name",
		"The older dev-dependencies table must be recognised"
	)

	eq(summary("[tool.poetry]\nna‸"), nil, "A key in Poetry's own settings is not a project name")
	eq(summary("[tool.poetry.dependencies]\nrequests.‸"), nil, "A dotted key is past the project name")
	eq(summary("[project]\ndepen‸"), nil, "A key in the project table is not a project name")

	--------------------------------------------------------------------------------
	-- POETRY: VERSIONS
	--------------------------------------------------------------------------------

	local poetry_version = {
		kind = "version",
		value = "2.3",
		constraint = "^2.3",
		package = "requests",
		normalized = "requests",
		style = "poetry",
	}

	eq(
		summary('[tool.poetry.dependencies]\nrequests = "^2.3‸"'),
		poetry_version,
		"A value in a Poetry table is a version of its key"
	)

	eq(
		summary('[tool.poetry.dependencies]\nrequests = { version = "^2.3‸", extras = ["security"] }'),
		poetry_version,
		"An inline table's version belongs to its key"
	)

	eq(
		summary('[tool.poetry.dependencies.requests]\nversion = "^2.3‸"'),
		poetry_version,
		"A dependency written as its own table must be understood"
	)

	eq(
		summary('[tool.poetry.group.test.dependencies]\nPytest_Cov = ">=5.‸"').normalized,
		"pytest-cov",
		"The name is reported as an index spells it"
	)

	local function typed(constraint)
		return summary('[tool.poetry.dependencies]\nrequests = "' .. constraint .. '‸"').value
	end

	eq(typed("^2."), "2.", "A caret is not part of the version being typed")
	eq(typed("~2.31"), "2.31", "A tilde is not part of the version being typed")
	eq(typed(">=2.0,<3"), "3", "Only the last comparator is being typed")
	eq(typed(">=2.0, <"), "", "A comparator with no version yet has nothing typed")
	eq(typed("~2.31 || ^3."), "3.", "Only the last alternative is being typed")
	eq(typed("!=2.30."), "2.30.", "An exclusion completes its version")
	eq(typed("==2.*"), "2.*", "A wildcard is part of the version being typed")
	eq(typed(""), "", "An empty constraint has nothing typed")

	eq(
		summary('[tool.poetry.dependencies]\npython = "^3.1‸"'),
		nil,
		"The supported interpreter is not a project to look up"
	)

	eq(
		summary('[tool.poetry.dependencies]\nlocal = { path = "../lo‸" }'),
		nil,
		"A path dependency is not completed"
	)

	eq(
		summary('[tool.poetry.dependencies]\nfork = { git = "https://github.com/x/‸" }'),
		nil,
		"A git dependency is not completed"
	)

	eq(
		summary('[tool.poetry.dependencies]\nrequests = { version = "^2", python = ">=3.‸" }'),
		nil,
		"A per dependency python constraint is not a version of the project"
	)

	--------------------------------------------------------------------------------
	-- POETRY: EXTRAS
	--------------------------------------------------------------------------------

	eq(
		summary('[tool.poetry.dependencies]\nhttpx = { version = "^0.27", extras = ["htt‸"] }'),
		{
			kind = "extra",
			value = "htt",
			package = "httpx",
			normalized = "httpx",
			style = "poetry",
		},
		"A string in a Poetry extras array is an extra"
	)

	eq(
		summary('[tool.poetry.dependencies]\nhttpx = { extras = "htt‸" }'),
		nil,
		"An extras value that is not an array is not an extra"
	)

	--------------------------------------------------------------------------------
	-- COMMENTS AND MALFORMED INPUT
	--------------------------------------------------------------------------------

	eq(summary('[project]\n# dependencies = ["reque‸"]'), nil, "A commented out list is not completed")

	eq(
		summary('# [tool.ruff]\n[project]\ndependencies = ["reque‸"]').kind,
		"name",
		"A commented out header must not become the current table"
	)

	eq(
		summary('[project]\ndescription = "broken\ndependencies = ["reque‸"]').kind,
		"name",
		"A string left open on an earlier line must not swallow the next one"
	)

	eq(
		summary('[project]\nreadme = """\n[project]\ndependencies = ["reque‸"]\n"""'),
		nil,
		"A table header inside a multi line string is text"
	)

	--------------------------------------------------------------------------------
	-- POSITION
	--------------------------------------------------------------------------------

	local positioned = at('[project]\ndependencies = [\n    "requests>=2.3‸",\n]')

	eq(
		{ positioned.row, positioned.col, #positioned.value },
		{ 3, #'    "requests>=2.3', 3 },
		"The position and the typed value must give the range to replace"
	)

	eq(Context.at({ "[project]" }, 9, 0), nil, "A cursor beyond the buffer must not raise")
	eq(Context.at(nil, 1, 0), nil, "A missing buffer must not raise")

	--------------------------------------------------------------------------------
	-- ROBUSTNESS
	--------------------------------------------------------------------------------

	local hostile = {
		'[project]\ndependencies = [[[[[["',
		'[tool.poetry.dependencies]\n= = { { "',
		'[tool.poetry.group..dependencies]\nx = "',
		'[project]\ndependencies = ["[[[,,,;;;@@@',
		"[tool.poetry.dependencies.]\n.. = \"\"",
		'[dependency-groups]\nx = [{ { ["',
		"\0[project]\n\255 = [\"\0\"",
		string.rep("[project]\ndependencies = [", 40) .. '"',
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
