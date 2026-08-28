local VersionRank = require("blink_deps.version_rank")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- VERSION RANKING
	--------------------------------------------------------------------------------

	ok(
		VersionRank.compare_values(
			"2.10.0",
			"2.9.0"
		) > 0,
		"Version ranking must compare numeric segments numerically"
	)

	ok(
		VersionRank.compare_values(
			"10.0.0",
			"9.99.99"
		) > 0,
		"Version ranking must compare major versions numerically"
	)

	ok(
		VersionRank.compare_values(
			"2.9.0",
			"2.9.0-RC1"
		) > 0,
		"Stable versions must rank above release candidates"
	)

	ok(
		VersionRank.compare_values(
			"2.9.0-RC1",
			"2.9.0-M9"
		) > 0,
		"Release candidates must rank above milestones"
	)

	ok(
		VersionRank.compare_values(
			"2.9.0-M1",
			"2.9.0-beta9"
		) > 0,
		"Milestones must rank above beta versions"
	)

	ok(
		VersionRank.compare_values(
			"2.9.0-beta1",
			"2.9.0-alpha9"
		) > 0,
		"Beta versions must rank above alpha versions"
	)

	ok(
		VersionRank.compare_values(
			"2.9.0-SNAPSHOT",
			"2.9.0-RC1"
		) > 0,
		"Snapshots must rank above release candidates"
	)

	ok(
		VersionRank.compare_values(
			"2.9.0-RC10",
			"2.9.0-RC2"
		) > 0,
		"Numeric qualifier suffixes must be compared numerically"
	)

	eq(
		VersionRank.compare_values(
			"1.0.0.Final",
			"1.0.0"
		),
		0,
		"Final must be treated as a stable release alias"
	)

	eq(
		VersionRank.compare_values(
			"1.0.0.RELEASE",
			"1.0.0"
		),
		0,
		"Release must be treated as a stable release alias"
	)

	eq(
		VersionRank.compare_values(
			"1.0.0-CR1",
			"1.0.0-RC1"
		),
		0,
		"CR must be treated as an RC alias"
	)

	eq(
		VersionRank.compare_values(
			"1.0.0-GA",
			"1.0.0"
		),
		0,
		"GA must be treated as a stable release alias"
	)

	eq(
		VersionRank.compare_values(
			"1.0.0-M1",
			"1.0.0-milestone1"
		),
		0,
		"M must be treated as a milestone alias"
	)

	ok(
		VersionRank.compare_values(
			"1.0.0-SP1",
			"1.0.0"
		) > 0,
		"Service-pack versions must rank above the base release"
	)

	eq(
		VersionRank.compare_values(
			"1.0.0-RC1",
			"1.0.0-rc1"
		),
		0,
		"Version qualifiers must be compared case-insensitively"
	)

	eq(
		VersionRank.is_prerelease(
			"1.0.0-SNAPSHOT"
		),
		true,
		"Snapshots must be classified as prereleases"
	)

	eq(
		VersionRank.is_prerelease(
			"1.0.0-GA"
		),
		false,
		"GA releases must not be classified as prereleases"
	)

	eq(
		VersionRank.is_prerelease(
			"1.0.0-internal"
		),
		true,
		"Unknown custom qualifiers must be classified as prereleases"
	)

	ok(
		VersionRank.compare_values(
			"5.0.0-RC1",
			"4.9.9"
		) > 0,
		"A higher numeric prerelease must outrank an older stable version"
	)

	ok(
		VersionRank.compare_values(
			"5.0.0-internal",
			"4.0.0"
		) > 0,
		"Custom repository qualifiers must preserve numeric version ordering"
	)

	ok(
		VersionRank.compare_values(
			"5.0.0",
			"5.0.0-internal"
		) > 0,
		"A stable release must outrank an unknown qualifier with the same numeric core"
	)

	eq(
		VersionRank.is_prerelease(
			"1.0.0-RC1"
		),
		true,
		"Release candidates must be classified as prereleases"
	)

	eq(
		VersionRank.is_prerelease(
			"1.0.0"
		),
		false,
		"Stable versions must not be classified as prereleases"
	)

	local ranked_versions = {
		{ value = "2.9.0-SNAPSHOT", timestamp = 999999 },
		{ value = "2.9.0", timestamp = 100 },
		{ value = "2.10.0", timestamp = 0 },
		{ value = "2.9.0-beta1", timestamp = 0 },
		{ value = "2.9.0-RC1", timestamp = 0 },
		{ value = "2.9.1", timestamp = 0 },
	}

	VersionRank.sort(ranked_versions)

	local ranked_values = {}

	for _, entry in ipairs(ranked_versions) do
		table.insert(
			ranked_values,
			entry.value
		)
	end

	eq(
		ranked_values,
		{
			"2.10.0",
			"2.9.1",
			"2.9.0",
			"2.9.0-SNAPSHOT",
			"2.9.0-RC1",
			"2.9.0-beta1",
		},
		"Version sorting must prioritize semantic version order over timestamps"
	)

	--------------------------------------------------------------------------------
end
