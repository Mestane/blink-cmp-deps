local Pep440 = require("blink_deps.pep440")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- PARSE
	--------------------------------------------------------------------------------

	eq(
		Pep440.parse("1.2.3"),
		{ epoch = 0, release = { 1, 2, 3 } },
		"A plain release must parse into its numbers"
	)

	eq(
		Pep440.parse("2!1.0rc2.post3.dev4+ubuntu.1"),
		{
			epoch = 2,
			release = { 1, 0 },
			pre = { 3, 2 },
			post = 3,
			dev = 4,
			local_version = "ubuntu.1",
		},
		"Every part of a version must be recognised"
	)

	eq(Pep440.parse("2024.10"), { epoch = 0, release = { 2024, 10 } }, "A calendar version is a release")
	eq(Pep440.parse("1").release, { 1 }, "A single number is a release")
	eq(Pep440.parse("  1.0  ").release, { 1, 0 }, "Surrounding whitespace is not part of a version")

	-- Implicit numbers.
	eq(Pep440.parse("1.0a").pre, { 1, 0 }, "A prerelease without a number is number zero")
	eq(Pep440.parse("1.0.post").post, 0, "A post release without a number is number zero")
	eq(Pep440.parse("1.0.dev").dev, 0, "A development release without a number is number zero")
	eq(Pep440.parse("1.0-1").post, 1, "A bare number after a hyphen is a post release")

	for _, text in ipairs({
		"",
		"abc",
		"latest",
		"1.0.x",
		"1..0",
		"1.0+",
		"1.0+a..b",
		"1.0+a b",
		"1.0a1b2",
		"1.0.post1.post2",
		"!1.0",
		"1.0 2.0",
		"1.0-",
		".1",
		"1.0.dev1.rc1",
	}) do
		eq(Pep440.parse(text), nil, "'" .. text .. "' is not a version")
	end

	eq(Pep440.parse(nil), nil, "A missing value is not a version")
	eq(Pep440.parse(1.0), nil, "A number is not a version string")

	--------------------------------------------------------------------------------
	-- ORDER
	--
	-- The chain given in the specification.
	--------------------------------------------------------------------------------

	local ascending = {
		"1.dev0",
		"1.0.dev456",
		"1.0a1",
		"1.0a2.dev456",
		"1.0a12.dev456",
		"1.0a12",
		"1.0b1.dev456",
		"1.0b2",
		"1.0b2.post345.dev456",
		"1.0b2.post345",
		"1.0rc1.dev456",
		"1.0rc1",
		"1.0",
		"1.0+abc.5",
		"1.0+abc.7",
		"1.0+5",
		"1.0.post456.dev34",
		"1.0.post456",
		"1.1.dev1",
		"1.1",
		"1.10",
		"2.0",
		"2024.1",
		"1!0.1",
	}

	for index = 1, #ascending - 1 do
		local lower = ascending[index]
		local higher = ascending[index + 1]

		eq(Pep440.compare(lower, higher), -1, lower .. " must be lower than " .. higher)
		eq(Pep440.compare(higher, lower), 1, higher .. " must be higher than " .. lower)
	end

	eq(Pep440.compare("9.0", "10.0"), -1, "Release numbers compare as numbers, not as text")
	eq(Pep440.compare("1.0a2", "1.0a12"), -1, "Prerelease numbers compare as numbers, not as text")
	eq(Pep440.compare("1!1.0", "2.0"), 1, "A higher epoch outranks any release of a lower one")

	--------------------------------------------------------------------------------
	-- SPELLINGS OF THE SAME VERSION
	--------------------------------------------------------------------------------

	for _, group in ipairs({
		{ "1.0", "1.0.0", "1", "v1.0", "V1.0", "0!1.0", " 1.0 " },
		{ "1.0a1", "1.0alpha1", "1.0-a.1", "1.0_a_1", "1.0.A1", "1.0a.1" },
		{ "1.0b2", "1.0beta2", "1.0-beta-2" },
		{ "1.0rc1", "1.0c1", "1.0pre1", "1.0preview1", "1.0-rc.1", "1.0RC1" },
		{ "1.0.post1", "1.0-1", "1.0post1", "1.0.rev1", "1.0-r1", "1.0.post.1" },
		{ "1.0.dev3", "1.0dev3", "1.0-dev-3", "1.0.DEV3" },
		{ "1.0a", "1.0a0", "1.0a." },
		{ "1.0+ubuntu.1", "1.0+ubuntu-1", "1.0+ubuntu_1", "1.0+UBUNTU.1" },
	}) do
		for _, spelling in ipairs(group) do
			eq(
				Pep440.compare(group[1], spelling),
				0,
				"'" .. spelling .. "' must be the same version as " .. group[1]
			)
		end
	end

	--------------------------------------------------------------------------------
	-- LOCAL VERSIONS
	--------------------------------------------------------------------------------

	eq(Pep440.compare("1.0+abc", "1.0"), 1, "A local version is higher than the version it extends")
	eq(Pep440.compare("1.0+5", "1.0+abc"), 1, "A numeric segment is higher than a textual one")
	eq(Pep440.compare("1.0+2", "1.0+10"), -1, "Numeric segments compare as numbers")
	eq(Pep440.compare("1.0+abc.1", "1.0+abc"), 1, "A longer local version is higher than its own beginning")
	eq(Pep440.compare("1.0+abc", "1.0.post1"), -1, "A local version does not outrank a post release")

	--------------------------------------------------------------------------------
	-- PRERELEASE
	--------------------------------------------------------------------------------

	for _, text in ipairs({ "1.0a1", "1.0b2", "1.0rc1", "1.0.dev1", "1.0a1.post1", "1.0.post1.dev2" }) do
		ok(Pep440.is_prerelease(text), text .. " is a prerelease")
	end

	for _, text in ipairs({ "1.0", "1.0.post1", "1.0+local", "2!1.0", "not a version" }) do
		ok(not Pep440.is_prerelease(text), text .. " is not a prerelease")
	end

	--------------------------------------------------------------------------------
	-- NOT A VERSION
	--------------------------------------------------------------------------------

	eq(Pep440.compare("1.0", "garbage"), 1, "A version outranks something that is not one")
	eq(Pep440.compare("garbage", "0.0.1.dev0"), -1, "Something that is not a version ranks below any version")
	eq(Pep440.compare("apple", "banana"), -1, "Two non versions compare as text")
	eq(Pep440.compare(nil, "1.0"), -1, "A missing value ranks below a version")

	--------------------------------------------------------------------------------
	-- SORT
	--------------------------------------------------------------------------------

	eq(
		Pep440.sort({ "1.0", "1.10", "garbage", "1.2", "2.0rc1", "1.0.post1", "1.0.dev1" }),
		{ "2.0rc1", "1.10", "1.2", "1.0.post1", "1.0", "1.0.dev1", "garbage" },
		"Sorting must put the highest version first and non versions last"
	)

	eq(
		Pep440.sort({
			{ value = "0.9", yanked = true },
			{ value = "1.1" },
			{ value = "1.0" },
		}),
		{
			{ value = "1.1" },
			{ value = "1.0" },
			{ value = "0.9", yanked = true },
		},
		"Entries in the registries' shape must sort by value and keep their fields"
	)

	for _, input in ipairs({
		{ "1.0.0", "1.0", "v1.0" },
		{ "v1.0", "1.0.0", "1.0" },
		{ "1.0", "v1.0", "1.0.0" },
	}) do
		eq(
			Pep440.sort(input),
			{ "v1.0", "1.0.0", "1.0" },
			"Spellings of one version must sort the same whatever their input order"
		)
	end

	--------------------------------------------------------------------------------
	-- PROPERTIES
	--
	-- Over every pair and triple of a mixed set, including several spellings
	-- of the same version: the order is consistent.
	--------------------------------------------------------------------------------

	local pool = {
		"1.dev0",
		"1.0.dev456",
		"1.0a1",
		"1.0alpha1",
		"1.0a2.dev456",
		"1.0b2.post345",
		"1.0rc1",
		"1.0",
		"1.0.0",
		"v1.0",
		"1.0+abc.5",
		"1.0+5",
		"1.0.post456.dev34",
		"1.0.post456",
		"1.0-456",
		"1.1",
		"1!0.1",
		"2024.10.1",
		"latest",
		"",
	}

	local violations = {}

	for _, a in ipairs(pool) do
		if Pep440.compare(a, a) ~= 0 then
			table.insert(violations, "not reflexive: " .. a)
		end

		for _, b in ipairs(pool) do
			if Pep440.compare(a, b) ~= -Pep440.compare(b, a) then
				table.insert(violations, "not antisymmetric: " .. a .. " / " .. b)
			end

			for _, c in ipairs(pool) do
				if Pep440.compare(a, b) >= 0
					and Pep440.compare(b, c) >= 0
					and Pep440.compare(a, c) < 0
				then
					table.insert(violations, "not transitive: " .. a .. " / " .. b .. " / " .. c)
				end
			end
		end
	end

	eq(violations, {}, "The order must be reflexive, antisymmetric and transitive")

	local sorted = Pep440.sort(vim.deepcopy(pool))
	local descending = true

	for index = 1, #sorted - 1 do
		if Pep440.compare(sorted[index], sorted[index + 1]) < 0 then
			descending = false
		end
	end

	ok(descending, "A sorted list must never rise from one entry to the next")

	local raised

	for _, text in ipairs({
		"\0",
		"....",
		"!!!",
		"1.0" .. string.rep(".post1", 300),
		string.rep("9", 400),
		"1.0+" .. string.rep("a.", 300) .. "a",
		"%d+%.%d+",
		"1.0a" .. string.rep("-", 200),
	}) do
		if not pcall(Pep440.compare, text, "1.0") or not pcall(Pep440.is_prerelease, text) then
			raised = text
		end
	end

	eq(raised, nil, "No input may raise")
end
