local Context = require("blink_deps.cargo_context")

return function(test)
	local eq = test.eq

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A fixture is a Cargo.toml fragment with | where the cursor is.
	--------------------------------------------------------------------------------

	local function at(fixture)
		local lines = vim.split(fixture, "\n", { plain = true })

		for row, line in ipairs(lines) do
			local column = line:find("|", 1, true)

			if column then
				lines[row] = line:sub(1, column - 1) .. line:sub(column + 1)

				return Context.at(lines, row, column - 1)
			end
		end

		error("fixture has no cursor")
	end

	-- A context without its position, which every fixture would otherwise
	-- have to spell out.
	local function summary(fixture)
		local ctx = at(fixture)

		if not ctx then
			return nil
		end

		ctx.row = nil
		ctx.col = nil

		return ctx
	end

	local function dependencies(fields)
		return vim.tbl_extend("force", {
			section = "dependencies",
			workspace = false,
		}, fields)
	end

	--------------------------------------------------------------------------------
	-- CRATE NAMES
	--------------------------------------------------------------------------------

	eq(
		summary("[dependencies]\nser|"),
		dependencies({ kind = "name", value = "ser" }),
		"A key being typed in a dependency table is a crate name"
	)

	eq(
		summary("[dependencies]\ntokio = \"1\"\n|"),
		dependencies({ kind = "name", value = "" }),
		"An empty line in a dependency table is where a crate name goes"
	)

	eq(
		summary("[dependencies]\n  serde_j|"),
		dependencies({ kind = "name", value = "serde_j" }),
		"Indentation must not matter"
	)

	eq(
		summary("[dependencies.ser|"),
		dependencies({ kind = "name", value = "ser" }),
		"A crate name can be typed in a table header"
	)

	eq(
		summary("[dependencies.|"),
		dependencies({ kind = "name", value = "" }),
		"A header waiting for its crate name is a name context"
	)

	eq(
		summary('[dependencies]\njson = { package = "serde_j|" }'),
		dependencies({ kind = "name", value = "serde_j", alias = "json" }),
		"The target of a package rename is a crate name"
	)

	eq(summary("[dependencies]\nserde.|"), nil, "A dotted key is past the crate name")
	eq(summary("[dependencies]\nserde |"), nil, "After the key there is no name to complete")
	eq(summary("[depend|"), nil, "A header that is not a dependency table yet is not a name")
	eq(summary("[package]\nna|"), nil, "A key outside dependency tables is not a crate name")
	eq(summary("ser|"), nil, "A key before any table is not a crate name")

	--------------------------------------------------------------------------------
	-- VERSIONS, IN EVERY SPELLING
	--------------------------------------------------------------------------------

	local serde_version = dependencies({
		kind = "version",
		value = "1.",
		requirement = "1.",
		crate = "serde",
		alias = "serde",
	})

	eq(
		summary('[dependencies]\nserde = "1.|"'),
		serde_version,
		"The short form must be a version context"
	)

	eq(
		summary('[dependencies]\nserde = { version = "1.|", features = ["derive"] }'),
		serde_version,
		"An inline table must be a version context"
	)

	eq(
		summary('[dependencies]\nserde = { features = ["derive"], version = "1.|" }'),
		serde_version,
		"The order of keys in an inline table must not matter"
	)

	eq(
		summary('[dependencies]\nserde.version = "1.|"'),
		serde_version,
		"A dotted key must be a version context"
	)

	eq(
		summary('[dependencies.serde]\nversion = "1.|"'),
		serde_version,
		"A dependency written as its own table must be a version context"
	)

	eq(
		summary("[dependencies]\nserde = '1.|'"),
		serde_version,
		"A literal string must work like a basic one"
	)

	eq(
		summary('[dependencies]\nserde = "|"').value,
		"",
		"An empty requirement is a version context with nothing typed"
	)

	eq(
		summary('[dependencies]\ntokio = "1"\nserde = "1.|"\nrand = "0.8"'),
		serde_version,
		"Neighbouring dependencies must not interfere"
	)

	--------------------------------------------------------------------------------
	-- REQUIREMENT OPERATORS
	--------------------------------------------------------------------------------

	local function typed(requirement)
		local ctx = summary('[dependencies]\nserde = "' .. requirement .. '|"')

		return { ctx.value, ctx.requirement }
	end

	eq(typed("^1.2"), { "1.2", "^1.2" }, "A caret is not part of the version being typed")
	eq(typed("~1."), { "1.", "~1." }, "A tilde is not part of the version being typed")
	eq(typed("= 1.0.4"), { "1.0.4", "= 1.0.4" }, "An exact requirement completes its version")
	eq(typed(">=1.2, <2"), { "2", ">=1.2, <2" }, "Only the last comparator is being typed")
	eq(typed(">=1.2, <"), { "", ">=1.2, <" }, "A comparator with no version yet has nothing typed")
	eq(typed("1.0.0-rc."), { "1.0.0-rc.", "1.0.0-rc." }, "A prerelease is one version")

	--------------------------------------------------------------------------------
	-- FEATURES
	--------------------------------------------------------------------------------

	local serde_feature = dependencies({
		kind = "feature",
		value = "der",
		crate = "serde",
		alias = "serde",
	})

	eq(
		summary('[dependencies]\nserde = { version = "1", features = ["der|"] }'),
		serde_feature,
		"A string in an inline features array is a feature"
	)

	eq(
		summary('[dependencies]\nserde = { version = "1", features = ["std", "der|"] }'),
		serde_feature,
		"A later element of the array is a feature too"
	)

	eq(
		summary('[dependencies.serde]\nversion = "1"\nfeatures = ["der|"]'),
		serde_feature,
		"A features array in a dependency table is a feature"
	)

	eq(
		summary('[dependencies.serde]\nfeatures = [\n    "std",\n    "der|",\n]'),
		serde_feature,
		"A features array may span lines"
	)

	eq(
		summary('[dependencies]\nserde.features = ["der|"]'),
		serde_feature,
		"A dotted features key is a feature"
	)

	eq(
		summary('[dependencies]\nserde = { features = "der|" }'),
		nil,
		"A features value that is not an array is not a feature"
	)

	eq(
		summary('[features]\ndefault = ["der|"]'),
		nil,
		"The package's own features table is not a dependency's features"
	)

	--------------------------------------------------------------------------------
	-- WHERE DEPENDENCY TABLES LIVE
	--------------------------------------------------------------------------------

	eq(
		summary('[dev-dependencies]\ncriterion = "|"').section,
		"dev-dependencies",
		"dev-dependencies must be recognised"
	)

	eq(
		summary('[build-dependencies]\ncc = "|"').section,
		"build-dependencies",
		"build-dependencies must be recognised"
	)

	eq(
		summary('[workspace.dependencies]\nserde = "1.|"'),
		{
			kind = "version",
			value = "1.",
			requirement = "1.",
			crate = "serde",
			alias = "serde",
			section = "dependencies",
			workspace = true,
		},
		"Workspace dependencies must be recognised and marked"
	)

	eq(
		summary("[target.'cfg(target_os = \"linux\")'.dependencies]\nnix = \"0.|\""),
		{
			kind = "version",
			value = "0.",
			requirement = "0.",
			crate = "nix",
			alias = "nix",
			section = "dependencies",
			workspace = false,
			target = 'cfg(target_os = "linux")',
		},
		"A target table with a quoted cfg expression must be recognised"
	)

	eq(
		summary('[target.x86_64-pc-windows-gnu.dev-dependencies]\nwinapi = "|"').target,
		"x86_64-pc-windows-gnu",
		"A target table named by a triple must be recognised"
	)

	eq(
		summary('[target.wasm32-unknown-unknown.dependencies.web-sys]\nversion = "0.|"').crate,
		"web-sys",
		"A dependency as its own table under a target must be recognised"
	)

	--------------------------------------------------------------------------------
	-- RENAMED PACKAGES
	--------------------------------------------------------------------------------

	eq(
		summary('[dependencies]\njson = { package = "serde_json", version = "1.|" }'),
		dependencies({
			kind = "version",
			value = "1.",
			requirement = "1.",
			crate = "serde_json",
			alias = "json",
		}),
		"A version belongs to the renamed package, not to the local name"
	)

	eq(
		summary('[dependencies]\njson = { version = "1.|", package = "serde_json" }').crate,
		"serde_json",
		"A rename written after the cursor must be found"
	)

	eq(
		summary('[dependencies.json]\nversion = "1.|"\npackage = "serde_json"').crate,
		"serde_json",
		"A rename in a dependency table must be found"
	)

	eq(
		summary('[dependencies.json]\nversion = "1.|"\n\n[dependencies.other]\npackage = "elsewhere"').crate,
		"json",
		"A rename in the next table must not be taken"
	)

	eq(
		summary('[dependencies]\nother = { package = "elsewhere" }\njson = { version = "1.|" }').crate,
		"json",
		"A rename on another line must not be taken"
	)

	eq(
		summary('[dependencies]\njson = { package = "serde_json", features = ["raw|"] }').crate,
		"serde_json",
		"Features belong to the renamed package too"
	)

	--------------------------------------------------------------------------------
	-- NOT A DEPENDENCY CONTEXT
	--------------------------------------------------------------------------------

	eq(summary('[package]\nname = "my-cr|"'), nil, "The package table is not a dependency")
	eq(summary('[package]\nversion = "0.1.|"'), nil, "The package's own version is not a dependency version")
	eq(summary('[[bin]]\nname = "to|"'), nil, "An array of tables is not a dependency table")
	eq(summary('[dependencies]\nserde = { git = "https://|" }'), nil, "A git source is not completed")
	eq(summary('[dependencies]\nserde = { path = "../|" }'), nil, "A path source is not completed")
	eq(summary('[dependencies]\nserde = |'), nil, "Outside a string there is no value to complete")
	eq(summary('[dependencies]\nserde = "1"|'), nil, "After a closed string there is nothing to complete")
	eq(summary('[dependencies]\nserde = { workspace = tr| }'), nil, "A boolean is not completed")
	eq(summary('[dependencies]\nserde = { "ver|" = "1" }'), nil, "A quoted key is not a value")
	eq(summary('[profile.release]\nopt-level = "|"'), nil, "A profile setting is not a dependency")

	--------------------------------------------------------------------------------
	-- COMMENTS
	--------------------------------------------------------------------------------

	eq(summary('[dependencies]\n# serde = "1.|"'), nil, "A commented out dependency is not completed")
	eq(summary('[dependencies]\nserde = "1" # pinned to "1.|"'), nil, "A trailing comment is not completed")

	eq(
		summary('# [package]\n[dependencies]\nserde = "1.|"').crate,
		"serde",
		"A commented out header must not become the current table"
	)

	eq(
		summary('[dependencies]\n# [package]\nserde = "1.|"').crate,
		"serde",
		"A commented out header must not replace the current table"
	)

	eq(
		summary('[dependencies]\nhash = { version = "1.|", registry = "a#b" }').crate,
		"hash",
		"A # inside a string is not a comment"
	)

	eq(
		summary('[dependencies.serde]\nfeatures = [\n    "std", # always\n    "der|",\n]').kind,
		"feature",
		"A comment inside a multi line array must not end it"
	)

	--------------------------------------------------------------------------------
	-- MALFORMED INPUT
	--------------------------------------------------------------------------------

	eq(
		summary('[dependencies]\nbroken = { version = "1\nserde = "1.|"').crate,
		"serde",
		"An inline table left open on an earlier line must not swallow the next one"
	)

	eq(
		summary('[dependencies]\nbroken = "1\nserde = "1.|"').crate,
		"serde",
		"A string left open on an earlier line must not swallow the next one"
	)

	eq(
		summary('[dependencies\nserde = "1.|"'),
		nil,
		"A header that was never closed leaves the table unknown"
	)

	eq(
		summary('[dependencies]\nserde = "a \\" quote 1.|"').kind,
		"version",
		"An escaped quote must not end the string"
	)

	eq(
		summary('[package]\ndescription = """\n[dependencies]\nserde = "1.|"\n"""'),
		nil,
		"A table header inside a multi line string is text"
	)

	eq(
		summary('[package]\ndescription = """\ntext\n"""\n\n[dependencies]\nserde = "1.|"').crate,
		"serde",
		"A multi line string must end where it ends"
	)

	--------------------------------------------------------------------------------
	-- POSITION
	--------------------------------------------------------------------------------

	local positioned = at('[dependencies]\nserde = { version = "1.|" }')

	eq(
		{ positioned.row, positioned.col, #positioned.value },
		{ 2, #'serde = { version = "1.', 2 },
		"The position and the typed value must give the range to replace"
	)

	eq(Context.at({ "[dependencies]" }, 9, 0), nil, "A cursor beyond the buffer must not raise")
	eq(Context.at(nil, 1, 0), nil, "A missing buffer must not raise")

	--------------------------------------------------------------------------------
	-- ROBUSTNESS
	--
	-- Whatever is in the buffer, asking about any position must not raise.
	--------------------------------------------------------------------------------

	local hostile = {
		"[[[[]]]]",
		'[dependencies]\nx = { { { [ [ "',
		"[dependencies]\n= = = \"",
		"[dependencies.\"un.closed]\nversion = '",
		'[target.]\n"""',
		"[dependencies]\nx = }}}]]]",
		"\0[dependencies]\n\255 = \"\0\"",
		"[.dependencies.]\n.. = \"\"",
		string.rep("[dependencies]\nx = { a = [", 50),
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
