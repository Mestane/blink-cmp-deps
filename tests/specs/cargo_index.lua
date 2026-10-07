local CargoIndex = require("blink_deps.cargo_index")

return function(test)
	local eq = test.eq

	-- Paths and entry parsing are specified in tests/specs/crates_io.lua,
	-- where they were first written; these names are the same functions.
	eq(CargoIndex.path("serde"), "se/rd/serde", "The index path must be available here")
	eq(CargoIndex.path("../x"), nil, "Something that is not a crate name has no path")

	eq(
		CargoIndex.parse('{"name":"Demo","vers":"1.0.0","yanked":true}'),
		{ { name = "Demo", value = "1.0.0", yanked = true, features = {} } },
		"An entry must keep the name as the crate spells it"
	)

	--------------------------------------------------------------------------------
	-- CURRENT RELEASE
	--------------------------------------------------------------------------------

	local function release(entries)
		local found = CargoIndex.current_release(entries)

		return found and found.value or nil
	end

	eq(
		release({
			{ value = "1.0.0" },
			{ value = "1.10.0" },
			{ value = "1.2.0" },
		}),
		"1.10.0",
		"The current release is the highest version, not the last listed"
	)

	eq(
		release({
			{ value = "1.0.0" },
			{ value = "2.0.0-rc.1" },
			{ value = "1.5.0", yanked = true },
		}),
		"1.0.0",
		"A prerelease or a yanked release is not what a new dependency gets"
	)

	eq(
		release({
			{ value = "0.1.0-alpha.1" },
			{ value = "0.1.0-alpha.2" },
			{ value = "0.1.0-beta.1", yanked = true },
		}),
		"0.1.0-alpha.2",
		"With no release at all, the newest prerelease that is not yanked"
	)

	eq(
		release({
			{ value = "1.0.0", yanked = true },
			{ value = "1.1.0", yanked = true },
		}),
		"1.1.0",
		"With everything yanked, the newest of all"
	)

	eq(release({}), nil, "A crate without entries has no current release")
end
