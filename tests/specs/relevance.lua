local Relevance = require("blink_deps.relevance")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- COORDINATE OR SEARCH
	--------------------------------------------------------------------------------

	for _, value in ipairs({
		"org.",
		"org.springframework",
		"COM.Fasterxml",
		"io.micrometer",
		"dev.x",
	}) do
		ok(
			Relevance.is_reverse_domain_qualified(value),
			value .. " must be recognised as the start of a coordinate"
		)
	end

	for _, value in ipairs({
		"",
		"org",
		"spring",
		"jackson-databind",
		"organization.x",
		"spring.org.",
	}) do
		ok(
			not Relevance.is_reverse_domain_qualified(value),
			"'" .. value .. "' must be treated as a search, not a coordinate"
		)
	end

	eq(
		Relevance.is_reverse_domain_qualified(nil),
		false,
		"A missing value is not a coordinate"
	)

	--------------------------------------------------------------------------------
	-- PACKAGE SCORE
	--------------------------------------------------------------------------------

	local function score(namespace, name, text)
		return Relevance.package_score(namespace, name, text)
	end

	eq(score("org.example", "demo", ""), 0, "Empty text must score nothing")
	eq(score("org.example", "demo", "   "), 0, "Blank text must score nothing")

	eq(
		score("org.example", "demo", "zzz"),
		1,
		"A package offered as a match must score at least one"
	)

	eq(score(nil, nil, "demo"), 1, "Missing fields must not raise")

	ok(
		score("org.example", "demo", "demo")
			> score("org.example", "demo-extras", "demo"),
		"An exact artifact match must outrank a prefix match"
	)

	ok(
		score("org.example", "demo-extras", "demo")
			> score("org.example", "my-demo", "demo"),
		"A prefix match must outrank a match in the middle"
	)

	ok(
		score("org.example", "my-demo", "demo")
			> score("org.example", "other", "demo"),
		"A match in the middle must outrank no match"
	)

	ok(
		score("org.example", "demo", "DEMO") == score("org.example", "demo", "demo"),
		"Scoring must ignore case"
	)

	ok(
		score("org.springframework.data", "spring-data-jpa", "spring data jpa")
			> score("org.springframework.data", "spring-data-redis", "spring data jpa"),
		"Every matching word must add to the score"
	)

	ok(
		score("org.springframework", "core", "spring")
			> score("org.other", "core", "spring"),
		"A match in the namespace must count"
	)

	eq(
		score("org.example", "demo", "demo"),
		score("org.example", "demo", "demo"),
		"Scoring must be deterministic"
	)
end
