local Semver = require("blink_deps.semver")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- PARSE
	--------------------------------------------------------------------------------

	eq(
		Semver.parse("1.2.3"),
		{ major = 1, minor = 2, patch = 3, prerelease = {}, build = "" },
		"A release must parse into its three parts"
	)

	eq(
		Semver.parse("1.0.0-rc.1"),
		{ major = 1, minor = 0, patch = 0, prerelease = { "rc", 1 }, build = "" },
		"Prerelease identifiers must be split, numeric ones as numbers"
	)

	eq(
		Semver.parse("1.0.0-alpha-1.x-y+build.5-a"),
		{
			major = 1,
			minor = 0,
			patch = 0,
			prerelease = { "alpha-1", "x-y" },
			build = "build.5-a",
		},
		"Hyphens inside identifiers and build metadata must be kept"
	)

	eq(
		Semver.parse("0.0.0+20240101").build,
		"20240101",
		"Build metadata without a prerelease must parse"
	)

	eq(
		Semver.parse("10.20.30").minor,
		20,
		"Multi digit parts must parse as numbers"
	)

	for _, text in ipairs({
		"",
		"1",
		"1.2",
		"1.2.3.4",
		"v1.2.3",
		"1.2.x",
		"1.2.3-",
		"1.2.3+",
		"1.2.3-a..b",
		"1.2.3-a_b",
		"1.2.3 ",
		" 1.2.3",
		"latest",
		"1.2.-3",
	}) do
		eq(
			Semver.parse(text),
			nil,
			"'" .. text .. "' is not a semantic version"
		)
	end

	eq(Semver.parse(nil), nil, "A missing value is not a version")
	eq(Semver.parse(123), nil, "A number is not a version string")

	--------------------------------------------------------------------------------
	-- PRECEDENCE
	--------------------------------------------------------------------------------

	-- The chain given in the specification, plus the numeric parts.
	local ascending = {
		"0.0.1",
		"0.1.0",
		"0.9.9",
		"1.0.0-0",
		"1.0.0-1",
		"1.0.0-alpha",
		"1.0.0-alpha.1",
		"1.0.0-alpha.beta",
		"1.0.0-beta",
		"1.0.0-beta.2",
		"1.0.0-beta.11",
		"1.0.0-rc.1",
		"1.0.0",
		"1.0.1",
		"1.2.0",
		"1.10.0",
		"2.0.0-alpha",
		"2.0.0",
		"10.0.0",
	}

	for index = 1, #ascending - 1 do
		local lower = ascending[index]
		local higher = ascending[index + 1]

		eq(Semver.compare(lower, higher), -1, lower .. " must be lower than " .. higher)
		eq(Semver.compare(higher, lower), 1, higher .. " must be higher than " .. lower)
	end

	eq(Semver.compare("1.2.3", "1.2.3"), 0, "A version equals itself")
	eq(Semver.compare("9.0.0", "10.0.0"), -1, "Parts compare as numbers, not as text")

	eq(
		Semver.compare("1.0.0-beta.2", "1.0.0-beta.11"),
		-1,
		"Numeric prerelease identifiers compare as numbers, not as text"
	)

	eq(
		Semver.compare("1.0.0+build.1", "1.0.0+build.2"),
		0,
		"Build metadata must not affect precedence"
	)

	eq(
		Semver.compare("1.0.0-rc.1+a", "1.0.0-rc.1+b"),
		0,
		"Build metadata on a prerelease must not affect precedence"
	)

	--------------------------------------------------------------------------------
	-- NOT A VERSION
	--------------------------------------------------------------------------------

	eq(Semver.compare("1.0.0", "garbage"), 1, "A version outranks something that is not one")
	eq(Semver.compare("garbage", "0.0.1"), -1, "Something that is not a version ranks below any version")
	eq(Semver.compare("apple", "banana"), -1, "Two non versions compare as text")
	eq(Semver.compare("same", "same"), 0, "A non version equals itself")
	eq(Semver.compare(nil, "1.0.0"), -1, "A missing value ranks below a version")

	--------------------------------------------------------------------------------
	-- PRERELEASE
	--------------------------------------------------------------------------------

	ok(Semver.is_prerelease("1.0.0-rc.1"), "A version with a prerelease part is a prerelease")
	ok(Semver.is_prerelease("0.1.0-alpha"), "A 0.x prerelease is a prerelease")
	ok(not Semver.is_prerelease("1.0.0"), "A release is not a prerelease")
	ok(not Semver.is_prerelease("0.1.0"), "A 0.x release is not a prerelease")
	ok(not Semver.is_prerelease("1.0.0+build"), "Build metadata does not make a prerelease")
	ok(not Semver.is_prerelease("garbage"), "Something that is not a version is not a prerelease")

	--------------------------------------------------------------------------------
	-- SORT
	--------------------------------------------------------------------------------

	eq(
		Semver.sort({ "1.0.0", "1.10.0", "garbage", "1.2.0", "2.0.0-rc.1", "1.0.0-beta" }),
		{ "2.0.0-rc.1", "1.10.0", "1.2.0", "1.0.0", "1.0.0-beta", "garbage" },
		"Sorting must put the highest version first and non versions last"
	)

	eq(
		Semver.sort({
			{ value = "0.9.0", yanked = true },
			{ value = "1.1.0" },
			{ value = "1.0.0" },
		}),
		{
			{ value = "1.1.0" },
			{ value = "1.0.0" },
			{ value = "0.9.0", yanked = true },
		},
		"Entries in the registries' shape must sort by value and keep their fields"
	)

	eq(Semver.sort({}), {}, "Sorting nothing must yield nothing")

	eq(
		Semver.sort({ { value = "1.0.0" }, {}, { value = 7 }, "2.0.0", { value = "junk" } })[1],
		"2.0.0",
		"Entries without a usable version must sort last without raising"
	)

	-- The result must not depend on the order the entries arrived in.
	local shuffled = {
		{ "1.0.0+b", "1.0.0", "1.0.0+a" },
		{ "1.0.0+a", "1.0.0+b", "1.0.0" },
		{ "1.0.0", "1.0.0+a", "1.0.0+b" },
	}

	for _, input in ipairs(shuffled) do
		eq(
			Semver.sort(input),
			{ "1.0.0+b", "1.0.0+a", "1.0.0" },
			"Versions of equal precedence must sort the same whatever their input order"
		)
	end

	--------------------------------------------------------------------------------
	-- PROPERTIES
	--
	-- Over every pair and triple of a mixed set: the order is consistent, and
	-- sorting agrees with it. A comparator that breaks these makes table.sort
	-- misbehave or raise, so they are checked exhaustively, not by example.
	--------------------------------------------------------------------------------

	local pool = {
		"0.0.0",
		"0.0.1",
		"0.1.0",
		"1.0.0-0",
		"1.0.0-alpha",
		"1.0.0-alpha.1",
		"1.0.0-alpha.beta",
		"1.0.0-rc.1",
		"1.0.0-rc.1+build",
		"1.0.0",
		"1.0.0+build",
		"1.2.3",
		"2.0.0",
		"10.0.0",
		"1.0",
		"latest",
		"",
	}

	local violations = {}

	for _, a in ipairs(pool) do
		if Semver.compare(a, a) ~= 0 then
			table.insert(violations, "not reflexive: " .. a)
		end

		for _, b in ipairs(pool) do
			if Semver.compare(a, b) ~= -Semver.compare(b, a) then
				table.insert(violations, "not antisymmetric: " .. a .. " / " .. b)
			end

			for _, c in ipairs(pool) do
				if Semver.compare(a, b) >= 0
					and Semver.compare(b, c) >= 0
					and Semver.compare(a, c) < 0
				then
					table.insert(
						violations,
						"not transitive: " .. a .. " / " .. b .. " / " .. c
					)
				end
			end
		end
	end

	eq(violations, {}, "The order must be reflexive, antisymmetric and transitive")

	local sorted = Semver.sort(vim.deepcopy(pool))
	local descending = true

	for index = 1, #sorted - 1 do
		if Semver.compare(sorted[index], sorted[index + 1]) < 0 then
			descending = false
		end
	end

	ok(descending, "A sorted list must never rise from one entry to the next")

	-- Whatever the text, nothing raises.
	local raised

	for _, text in ipairs({
		"\0",
		"....",
		"-+-+",
		"1.2.3-" .. string.rep("a.", 500) .. "a",
		string.rep("9", 400) .. ".0.0",
		"1.2.3+" .. string.rep("+", 50),
		"%d+%.%d+",
	}) do
		if not pcall(Semver.compare, text, "1.0.0") or not pcall(Semver.is_prerelease, text) then
			raised = text
		end
	end

	eq(raised, nil, "No input may raise")
end
