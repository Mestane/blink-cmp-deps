local Context = require("blink_deps.requirements_context")
local Pep508 = require("blink_deps.pep508")

return function(test)
	local eq = test.eq

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A fixture is a requirements file with a cursor mark in it.
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
	-- NAME NORMALISATION
	--------------------------------------------------------------------------------

	for written, expected in pairs({
		["requests"] = "requests",
		["Django"] = "django",
		["typing_extensions"] = "typing-extensions",
		["Typing.Extensions"] = "typing-extensions",
		["zope.interface"] = "zope-interface",
		["a__b--c..d"] = "a-b-c-d",
	}) do
		eq(Pep508.normalize(written), expected, written .. " must normalise to " .. expected)
	end

	eq(Pep508.normalize(nil), "", "A missing name normalises to nothing")

	--------------------------------------------------------------------------------
	-- NAMES
	--------------------------------------------------------------------------------

	eq(summary("requ‸"), { kind = "name", value = "requ" }, "Text at the start of a line is a project name")
	eq(summary("  dja‸"), { kind = "name", value = "dja" }, "Indentation must not matter")
	eq(summary("typing_ext‸"), { kind = "name", value = "typing_ext" }, "Separators are part of a name")
	eq(summary("flask\nreq‸\ndjango"), { kind = "name", value = "req" }, "Neighbouring lines must not interfere")
	eq(summary("‸"), { kind = "name", value = "" }, "An empty line is where a name goes")
	eq(summary("requests ‸"), nil, "After a name with nothing begun there is nothing to complete")

	--------------------------------------------------------------------------------
	-- VERSIONS
	--------------------------------------------------------------------------------

	eq(
		summary("requests==2.3‸"),
		{
			kind = "version",
			value = "2.3",
			operator = "==",
			package = "requests",
			normalized = "requests",
			extras = {},
		},
		"After an operator the cursor is in a version"
	)

	for operator in pairs({
		["=="] = true,
		[">="] = true,
		["<="] = true,
		["~="] = true,
		["!="] = true,
		[">"] = true,
		["<"] = true,
		["==="] = true,
	}) do
		eq(
			{ summary("requests" .. operator .. "2.‸").operator, summary("requests" .. operator .. "2.‸").value },
			{ operator, "2." },
			"The operator " .. operator .. " must be recognised"
		)
	end

	eq(summary("requests>=‸").value, "", "An operator with no version yet has nothing typed")
	eq(summary("requests >= 2.‸").value, "2.", "Spaces around an operator must not matter")
	eq(summary("Typing_Extensions>=4‸").normalized, "typing-extensions", "The name is reported as an index spells it")
	eq(summary("Typing_Extensions>=4‸").package, "Typing_Extensions", "The name is also reported as written")

	-- Several clauses: only the last is being typed.
	eq(
		{ summary("requests>=2.31,<3‸").operator, summary("requests>=2.31,<3‸").value },
		{ "<", "3" },
		"Only the last specifier is being typed"
	)

	eq(summary("requests>=2.31, <‸").value, "", "A new clause with no version yet has nothing typed")
	eq(summary("requests (>=2.‸").value, "2.", "Specifiers in parentheses must be understood")
	eq(summary("requests==2.*‸").value, "2.*", "A wildcard is part of the version being typed")
	eq(summary("requests==1!2.0‸").value, "1!2.0", "An epoch is part of the version being typed")
	eq(summary("requests==2.0+loc‸").value, "2.0+loc", "A local version is part of the version being typed")

	-- A partial operator is not yet a specifier.
	eq(summary("requests=‸"), nil, "A single = is not an operator")
	eq(summary("requests~‸"), nil, "A lone ~ is not an operator")
	eq(summary("requests!‸"), nil, "A lone ! is not an operator")
	eq(summary("requests>=2.0 ‸"), nil, "After a finished version there is nothing to complete")

	--------------------------------------------------------------------------------
	-- EXTRAS
	--------------------------------------------------------------------------------

	eq(
		summary("requests[sec‸"),
		{
			kind = "extra",
			value = "sec",
			package = "requests",
			normalized = "requests",
			extras = {},
		},
		"Inside brackets the cursor is in an extra"
	)

	eq(
		summary("requests[security, so‸"),
		{
			kind = "extra",
			value = "so",
			package = "requests",
			normalized = "requests",
			extras = { "security" },
		},
		"A later extra is reported with the ones before it"
	)

	eq(summary("requests[‸").value, "", "An opened bracket is where an extra goes")
	eq(summary("requests [sec‸").kind, "extra", "A space before the bracket must not matter")

	eq(
		summary("requests[security,socks]>=2.‸"),
		{
			kind = "version",
			value = "2.",
			operator = ">=",
			package = "requests",
			normalized = "requests",
			extras = { "security", "socks" },
		},
		"After closed extras the specifier belongs to the same package"
	)

	eq(summary("requests[security]‸"), nil, "After closed extras with nothing begun there is nothing to complete")

	--------------------------------------------------------------------------------
	-- MARKERS, URLS AND PATHS
	--------------------------------------------------------------------------------

	eq(summary('requests>=2 ; python_version >= "3.‸'), nil, "An environment marker is not completed")
	eq(summary("requests ; sys_plat‸"), nil, "A marker without a specifier is not completed")
	eq(summary("requests @ https://example.test/req‸"), nil, "A direct URL is not completed")
	eq(summary("requests @ file:///tmp/re‸"), nil, "A file URL is not completed")
	eq(summary("https://example.test/pkg.wh‸"), nil, "A bare URL is not a requirement")
	eq(summary("git+https://github.com/x/y‸"), nil, "A VCS URL is not a requirement")
	eq(summary("./downloads/pkg‸"), nil, "A relative path is not a requirement")
	eq(summary("/abs/pkg‸"), nil, "An absolute path is not a requirement")
	eq(summary("~/pkg‸"), nil, "A home relative path is not a requirement")
	eq(summary(".‸"), nil, "The current directory is not a requirement")

	--------------------------------------------------------------------------------
	-- OPTIONS
	--------------------------------------------------------------------------------

	eq(summary("-r other‸"), nil, "An included file is not a requirement")
	eq(summary("-e ./loc‸"), nil, "An editable install is not a requirement")
	eq(summary("--index-url https://pypi.org/sim‸"), nil, "An index option is not a requirement")
	eq(summary("-c constr‸"), nil, "A constraints file is not a requirement")
	eq(summary("  --no-bin‸"), nil, "An indented option is still an option")
	eq(summary("requests==2.31.0 --hash=sha256:ab‸"), nil, "A hash after a requirement is not completed")

	--------------------------------------------------------------------------------
	-- COMMENTS
	--------------------------------------------------------------------------------

	eq(summary("# requ‸"), nil, "A comment line is not completed")
	eq(summary("  # requ‸"), nil, "An indented comment line is not completed")
	eq(summary("requests>=2 # pinned to 2.‸"), nil, "A trailing comment is not completed")
	eq(summary("#requ‸"), nil, "A comment without a space after # is still a comment")

	eq(
		summary("# first\nrequests>=2.‸").kind,
		"version",
		"A comment on another line must not interfere"
	)

	--------------------------------------------------------------------------------
	-- CONTINUED LINES
	--------------------------------------------------------------------------------

	eq(
		summary("requests \\\n    >=2.‸"),
		{
			kind = "version",
			value = "2.",
			operator = ">=",
			package = "requests",
			normalized = "requests",
			extras = {},
		},
		"A specifier on a continuation line belongs to the requirement above"
	)

	eq(
		summary("requests==2.31.0 \\\n    --hash=sha256:ab‸"),
		nil,
		"A hash on a continuation line is not completed"
	)

	eq(
		summary("-r base.txt \\\n    req‸"),
		nil,
		"A continued option is still an option"
	)

	eq(
		summary("flask\\x\nreq‸").kind,
		"name",
		"A backslash that does not end a line does not continue it"
	)

	--------------------------------------------------------------------------------
	-- POSITION
	--------------------------------------------------------------------------------

	local positioned = at("flask\nrequests>=2.3‸")

	eq(
		{ positioned.row, positioned.col, #positioned.value },
		{ 2, #"requests>=2.3", 3 },
		"The position and the typed value must give the range to replace"
	)

	eq(Context.at({ "requests" }, 9, 0), nil, "A cursor beyond the buffer must not raise")
	eq(Context.at(nil, 1, 0), nil, "A missing buffer must not raise")
	eq(Pep508.at(nil), nil, "A missing requirement must not raise")

	--------------------------------------------------------------------------------
	-- ROBUSTNESS
	--------------------------------------------------------------------------------

	local hostile = {
		"[[[[",
		"]]]]",
		"requests[[[,,,",
		"====>>>>",
		"requests>=<=!=~=",
		"((((requests",
		"\0\255requests>=\0",
		"\\\n\\\n\\\nrequests\\",
		"requests[%d+(.-)%s*",
		string.rep("a,", 500) .. "[",
		";;;;@@@@",
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
