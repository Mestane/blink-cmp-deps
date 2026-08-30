local Central = require("blink_deps.central")
local GradleKts = require("blink_deps.gradle_kts")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- GRADLE KOTLIN DSL
	--------------------------------------------------------------------------------

	local gradle_kts_source = GradleKts.new({})

	ok(
		type(gradle_kts_source) == "table",
		"Gradle Kotlin DSL source must be constructible"
	)

	local gradle_kts_self_test = GradleKts.self_test()

	eq(
		gradle_kts_self_test.central_url,
		Central.URL,
		"Gradle Kotlin DSL source must use the shared Central backend URL"
	)




	local gradle_kts_group = assert(
		GradleKts.debug_parse(
			'implementation("org.springframework.ka'
		),
		"Gradle Kotlin DSL group parser returned nil"
	)

	eq(
		{
			kind = gradle_kts_group.kind,
			value = gradle_kts_group.value,
			notation = gradle_kts_group.notation,
		},
		{
			kind = "group",
			value = "org.springframework.ka",
			notation = "kotlin",
		},
		"Gradle Kotlin DSL must parse group completion context"
	)

	local gradle_kts_artifact = assert(
		GradleKts.debug_parse(
			'implementation("org.springframework.kafka:spring-'
		),
		"Gradle Kotlin DSL artifact parser returned nil"
	)

	eq(
		{
			kind = gradle_kts_artifact.kind,
			group_id = gradle_kts_artifact.group_id,
			value = gradle_kts_artifact.value,
		},
		{
			kind = "artifact",
			group_id = "org.springframework.kafka",
			value = "spring-",
		},
		"Gradle Kotlin DSL must parse artifact completion context"
	)

	local gradle_kts_version = assert(
		GradleKts.debug_parse(
			'implementation("org.springframework.kafka:spring-kafka:'
		),
		"Gradle Kotlin DSL version parser returned nil"
	)

	eq(
		{
			kind = gradle_kts_version.kind,
			group_id = gradle_kts_version.group_id,
			artifact_id = gradle_kts_version.artifact_id,
			value = gradle_kts_version.value,
		},
		{
			kind = "version",
			group_id = "org.springframework.kafka",
			artifact_id = "spring-kafka",
			value = "",
		},
		"Gradle Kotlin DSL must parse version completion context"
	)

	local gradle_kts_multiline = assert(
		GradleKts.debug_parse(table.concat({
			"implementation(",
			'    "org.springframework.kafka:spring-kafka:',
		}, "\n")),
		"Gradle Kotlin DSL multiline parser returned nil"
	)

	eq(
		{
			kind = gradle_kts_multiline.kind,
			group_id = gradle_kts_multiline.group_id,
			artifact_id = gradle_kts_multiline.artifact_id,
		},
		{
			kind = "version",
			group_id = "org.springframework.kafka",
			artifact_id = "spring-kafka",
		},
		"Gradle Kotlin DSL must parse multiline dependency coordinates"
	)

	local gradle_kts_platform_multiline = assert(
		GradleKts.debug_parse(table.concat({
			"implementation(",
			"    platform(",
			'        "org.springframework.boot:spring-boot-dependencies:',
		}, "\n")),
		"Gradle Kotlin DSL multiline platform parser returned nil"
	)

	eq(
		{
			kind = gradle_kts_platform_multiline.kind,
			group_id = gradle_kts_platform_multiline.group_id,
			artifact_id = gradle_kts_platform_multiline.artifact_id,
		},
		{
			kind = "version",
			group_id = "org.springframework.boot",
			artifact_id = "spring-boot-dependencies",
		},
		"Gradle Kotlin DSL must parse multiline platform dependency coordinates"
	)

	--------------------------------------------------------------------------------
end
