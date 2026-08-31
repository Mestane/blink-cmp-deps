local Central = require("blink_deps.central")
local Maven = require("blink_deps.maven")

return function(test)
	local eq = test.eq
	local ok = test.ok
	local contains = test.contains

	--------------------------------------------------------------------------------
	-- MAVEN
	--------------------------------------------------------------------------------

	local maven_source = Maven.new({})
	eq(maven_source.opts.jdtls.enabled, false, "JDTLS must be disabled by default")

	local maven_self_test = Maven.self_test()

	eq(maven_self_test.jdtls_default, false, "self-test must report JDTLS disabled by default")
	eq(maven_self_test.central_url, Central.URL, "Maven source must use the shared Central backend URL")

	local maven_qualified = Maven.debug_group_plan("org.springframework.ka")

	ok(
		contains(maven_qualified.central, "g:org.springframework.ka*"),
		"qualified Maven group search must use an unquoted Maven Central query"
	)

	local maven_broad = Maven.debug_group_plan("spring")

	ok(
		#maven_broad.central > 0,
		"plain Maven group search must produce at least one Central query"
	)


	local maven_artifact = Maven.debug_artifact_queries(
		"org.springframework.kafka",
		"spri",
		"spring-kafka"
	)

	eq(
		maven_artifact.group_catalog,
		"g:org.springframework.kafka",
		"Maven artifact catalog query must remain unquoted"
	)

	-- A leading wildcard on the a field is rejected or times out, and the
	-- catalog query already returns the whole group.
	eq(
		maven_artifact.target,
		nil,
		"Maven artifact completion must not plan a leading wildcard query"
	)

	eq(
		maven_artifact.version_query,
		"g:org.springframework.kafka AND a:spring-kafka",
		"Maven version query must remain unquoted"
	)

	--------------------------------------------------------------------------------
end
