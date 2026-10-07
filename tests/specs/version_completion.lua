local Semver = require("blink_deps.semver")
local Util = require("blink_deps.util")
local VersionCompletion = require("blink_deps.version_completion")
local VersionRank = require("blink_deps.version_rank")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- The registry is hand written and answers at once, so each case is one
	-- call. Streaming, caching rules and cancellation are covered where they
	-- were first specified, in tests/specs/coordinates.lua.
	--------------------------------------------------------------------------------

	rawset(Util, "defer", function(_, fn)
		fn()
	end)

	local function test_context()
		return {
			get_pos = function()
				return {
					row = 3,
					col = 20,
				}
			end,
		}
	end

	local function new_source(versions)
		local asked = {}

		local source = {
			opts = {},
			asked = asked,
			registry_list = {
				{
					id = "test",
					name = "Test",
					kind = "test",
					capabilities = { versions = true },
					versions = function(_, _, package, callback)
						table.insert(asked, vim.deepcopy(package))
						callback(versions, nil)
					end,
				},
			},
		}

		return source
	end

	local function complete(source, typed, opts)
		local last

		VersionCompletion.complete(
			source,
			test_context(),
			{ value = typed or "" },
			function(result)
				last = result
			end,
			vim.tbl_extend("force", {
				package = { name = "demo" },
				key = "demo",
				catalog = {},
				sort = Semver.sort,
			}, opts or {})
		)

		return last
	end

	local function labels(result)
		local list = {}

		for _, item in ipairs(result.items) do
			table.insert(list, item.label)
		end

		return list
	end

	--------------------------------------------------------------------------------
	-- THE ORDER IS THE CALLER'S
	--------------------------------------------------------------------------------

	local mixed = {
		{ value = "1.0.0", timestamp = 0 },
		{ value = "1.0.0-rc.1", timestamp = 0 },
		{ value = "1.10.0", timestamp = 0 },
		{ value = "1.2.0", timestamp = 0 },
	}

	eq(
		labels(complete(new_source(mixed))),
		{ "1.10.0", "1.2.0", "1.0.0", "1.0.0-rc.1" },
		"Versions must be offered in the order the given sort produces"
	)

	-- The same entries under a different rule: Maven reads these qualifiers
	-- its own way.
	local qualified = {
		{ value = "1.0.0.Final", timestamp = 0 },
		{ value = "1.0.0-SNAPSHOT", timestamp = 0 },
		{ value = "1.0.1", timestamp = 0 },
	}

	eq(
		labels(complete(new_source(qualified), "", { sort = VersionRank.sort })),
		{ "1.0.1", "1.0.0.Final", "1.0.0-SNAPSHOT" },
		"A different sort must give a different, equally respected order"
	)

	local ordered = complete(new_source(mixed))

	ok(
		ordered.items[1].score_offset > ordered.items[2].score_offset
			and ordered.items[2].score_offset > ordered.items[3].score_offset,
		"Scores must follow the order so the menu keeps it"
	)

	eq(
		{ ordered.items[1].sortText, ordered.items[4].sortText },
		{ "000001", "000004" },
		"Sort text must follow the order too"
	)

	--------------------------------------------------------------------------------
	-- WHAT WAS TYPED
	--------------------------------------------------------------------------------

	local typed = complete(new_source(mixed), "1.2")

	local scores = {}

	for _, item in ipairs(typed.items) do
		scores[item.label] = item.score_offset
	end

	ok(
		scores["1.2.0"] > 0 and scores["1.10.0"] == 0,
		"A version not containing what was typed must get no score"
	)

	eq(
		typed.items[1].textEdit,
		{
			newText = "1.10.0",
			range = {
				start = { line = 3, character = 17 },
				["end"] = { line = 3, character = 20 },
			},
		},
		"Accepting a version must replace exactly what was typed"
	)

	--------------------------------------------------------------------------------
	-- THE PACKAGE AND ITS LABEL
	--------------------------------------------------------------------------------

	local source = new_source(mixed)

	local described = complete(source, "", {
		package = { namespace = "org.example", name = "demo" },
		key = "org.example:demo",
	})

	eq(
		source.asked,
		{ { namespace = "org.example", name = "demo" } },
		"Registries must receive the package exactly as given"
	)

	eq(
		described.items[1].labelDetails.description,
		"org.example:demo",
		"The key is shown next to each version by default"
	)

	eq(described.items[1].kind, Util.KIND.Constant, "A version is a constant")

	--------------------------------------------------------------------------------
	-- ACCEPT AND DESCRIBE
	--------------------------------------------------------------------------------

	local withdrawn = {
		{ value = "1.0.0", timestamp = 0 },
		{ value = "1.1.0", timestamp = 0, yanked = true },
		{ value = "2.0.0-beta.1", timestamp = 0 },
	}

	eq(
		labels(complete(new_source(withdrawn), "", {
			accept = function(version)
				return not version.yanked
			end,
		})),
		{ "2.0.0-beta.1", "1.0.0" },
		"A version the caller does not accept must not be offered"
	)

	local catalog = {}

	local labelled = complete(new_source(withdrawn), "", {
		catalog = catalog,
		describe = function(version)
			if version.yanked then
				return "yanked"
			end

			if Semver.is_prerelease(version.value) then
				return "prerelease"
			end

			return nil
		end,
	})

	local descriptions = {}

	for _, item in ipairs(labelled.items) do
		descriptions[item.label] = item.labelDetails.description
	end

	eq(
		descriptions,
		{
			["2.0.0-beta.1"] = "prerelease",
			["1.1.0"] = "yanked",
			["1.0.0"] = "demo",
		},
		"describe must see every field a registry reported, and fall back to the key"
	)

	--------------------------------------------------------------------------------
	-- THE CATALOG
	--------------------------------------------------------------------------------

	eq(
		catalog.demo,
		{
			{ value = "2.0.0-beta.1", timestamp = 0 },
			{ value = "1.1.0", timestamp = 0, yanked = true },
			{ value = "1.0.0", timestamp = 0 },
		},
		"The complete result must be cached in order, with its extra fields"
	)

	local again = new_source({})

	eq(
		labels(complete(again, "", { catalog = catalog })),
		{ "2.0.0-beta.1", "1.1.0", "1.0.0" },
		"A cached result must be served without asking a registry"
	)

	eq(#again.asked, 0, "A cached result must not reach the registries")

	-- What a registry handed over is its own; sorting and caching here
	-- must leave it as it was.
	local owned = {
		{ value = "1.0.0" },
		{ value = "2.0.0" },
	}

	complete(new_source(owned))

	eq(
		owned,
		{
			{ value = "1.0.0" },
			{ value = "2.0.0" },
		},
		"A registry's own list must not be reordered or altered"
	)

	--------------------------------------------------------------------------------
	-- UNUSABLE ENTRIES
	--------------------------------------------------------------------------------

	eq(
		labels(complete(new_source({
			{ value = "1.0.0" },
			{ value = "" },
			{ timestamp = 5 },
			{ value = "1.0.0", timestamp = 9 },
		}))),
		{ "1.0.0" },
		"Entries without a version are dropped and duplicates merged"
	)
end
