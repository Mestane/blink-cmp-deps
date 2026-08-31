local Central = require("blink_deps.central")
local Gradle = require("blink_deps.gradle")

return function(test)
	local eq = test.eq
	local ok = test.ok
	local contains = test.contains

	--------------------------------------------------------------------------------
	-- GRADLE
	--------------------------------------------------------------------------------

	local gradle_source = Gradle.new({})

	ok(
		type(gradle_source) == "table",
		"Gradle source must be constructible"
	)

	local gradle_self_test = Gradle.self_test()

	eq(
		gradle_self_test.central_url,
		Central.URL,
		"Gradle source must use the shared Central backend URL"
	)




	local gradle_qualified = Gradle.debug_group_plan("org.springframework.ka")

	ok(
		contains(gradle_qualified.central, "g:org.springframework.ka*"),
		"qualified Gradle group search must use an unquoted Maven Central query"
	)

	local gradle_broad = Gradle.debug_group_plan("spring")

	ok(
		#gradle_broad.central > 0,
		"plain Gradle group search must produce at least one Central query"
	)

	local gradle_artifact = Gradle.debug_artifact_queries(
		"org.springframework.kafka",
		"spri",
		"spring-kafka"
	)

	eq(
		gradle_artifact.group_catalog,
		"g:org.springframework.kafka",
		"Gradle artifact catalog query must remain unquoted"
	)

	-- A leading wildcard on the a field is rejected or times out, and the
	-- catalog query already returns the whole group.
	eq(
		gradle_artifact.target,
		nil,
		"Gradle artifact completion must not plan a leading wildcard query"
	)

	eq(
		gradle_artifact.version_query,
		"g:org.springframework.kafka AND a:spring-kafka",
		"Gradle version query must remain unquoted"
	)

	--------------------------------------------------------------------------------
	-- GRADLE STRING NOTATION PARSER
	--------------------------------------------------------------------------------

	local gradle_single = assert(
		Gradle.debug_parse(
			"implementation 'org.springframework.kafka:spring-kafka:"
		),
		"Gradle single-line dependency parser returned nil"
	)

	eq(
		{
			kind = gradle_single.kind,
			group_id = gradle_single.group_id,
			artifact_id = gradle_single.artifact_id,
		},
		{
			kind = "version",
			group_id = "org.springframework.kafka",
			artifact_id = "spring-kafka",
		},
		"Gradle single-line string notation must parse dependency coordinates"
	)

	local gradle_function = assert(
		Gradle.debug_parse(
			'implementation("org.springframework.kafka:spring-kafka:'
		),
		"Gradle function notation parser returned nil"
	)

	eq(
		{
			kind = gradle_function.kind,
			group_id = gradle_function.group_id,
			artifact_id = gradle_function.artifact_id,
		},
		{
			kind = "version",
			group_id = "org.springframework.kafka",
			artifact_id = "spring-kafka",
		},
		"Gradle function notation must parse dependency coordinates"
	)

	local gradle_multiline = assert(
		Gradle.debug_parse(table.concat({
			"implementation(",
			'    "org.springframework.kafka:spring-kafka:',
		}, "\n")),
		"Gradle multiline dependency parser returned nil"
	)

	eq(
		{
			kind = gradle_multiline.kind,
			group_id = gradle_multiline.group_id,
			artifact_id = gradle_multiline.artifact_id,
		},
		{
			kind = "version",
			group_id = "org.springframework.kafka",
			artifact_id = "spring-kafka",
		},
		"Gradle multiline dependency notation must parse dependency coordinates"
	)

	local gradle_platform_multiline = assert(
		Gradle.debug_parse(table.concat({
			"implementation(",
			"    platform(",
			'        "org.springframework.boot:spring-boot-dependencies:',
		}, "\n")),
		"Gradle multiline platform parser returned nil"
	)

	eq(
		{
			kind = gradle_platform_multiline.kind,
			group_id = gradle_platform_multiline.group_id,
			artifact_id = gradle_platform_multiline.artifact_id,
		},
		{
			kind = "version",
			group_id = "org.springframework.boot",
			artifact_id = "spring-boot-dependencies",
		},
		"Gradle multiline platform notation must parse dependency coordinates"
	)

	--------------------------------------------------------------------------------
	-- GRADLE MAP NOTATION PARSER
	--------------------------------------------------------------------------------

	local gradle_map_group = assert(
		Gradle.debug_parse(
			"implementation group: 'org.springframework.ka"
		),
		"Gradle map group parser returned nil"
	)

	eq(
		{
			kind = gradle_map_group.kind,
			value = gradle_map_group.value,
			notation = gradle_map_group.notation,
		},
		{
			kind = "group",
			value = "org.springframework.ka",
			notation = "map",
		},
		"Gradle single-line map notation must parse group completion context"
	)

	local gradle_map_artifact = assert(
		Gradle.debug_parse(
			"implementation group: 'org.springframework.kafka', name: 'spring-"
		),
		"Gradle map artifact parser returned nil"
	)

	eq(
		{
			kind = gradle_map_artifact.kind,
			group_id = gradle_map_artifact.group_id,
			value = gradle_map_artifact.value,
		},
		{
			kind = "artifact",
			group_id = "org.springframework.kafka",
			value = "spring-",
		},
		"Gradle single-line map notation must parse artifact completion context"
	)

	local gradle_map_version = assert(
		Gradle.debug_parse(
			"implementation group: 'org.springframework.kafka', name: 'spring-kafka', version: '"
		),
		"Gradle map version parser returned nil"
	)

	eq(
		{
			kind = gradle_map_version.kind,
			group_id = gradle_map_version.group_id,
			artifact_id = gradle_map_version.artifact_id,
			value = gradle_map_version.value,
		},
		{
			kind = "version",
			group_id = "org.springframework.kafka",
			artifact_id = "spring-kafka",
			value = "",
		},
		"Gradle single-line map notation must parse version completion context"
	)

	local gradle_map_multiline_group = assert(
		Gradle.debug_parse(table.concat({
			"implementation(",
			'    group: "org.springframework.ka',
		}, "\n")),
		"Gradle multiline map group parser returned nil"
	)

	eq(
		{
			kind = gradle_map_multiline_group.kind,
			value = gradle_map_multiline_group.value,
		},
		{
			kind = "group",
			value = "org.springframework.ka",
		},
		"Gradle multiline map notation must parse group completion context"
	)

	local gradle_map_multiline_artifact = assert(
		Gradle.debug_parse(table.concat({
			"implementation(",
			'    group: "org.springframework.kafka",',
			'    name: "spring-',
		}, "\n")),
		"Gradle multiline map artifact parser returned nil"
	)

	eq(
		{
			kind = gradle_map_multiline_artifact.kind,
			group_id = gradle_map_multiline_artifact.group_id,
			value = gradle_map_multiline_artifact.value,
		},
		{
			kind = "artifact",
			group_id = "org.springframework.kafka",
			value = "spring-",
		},
		"Gradle multiline map notation must parse artifact completion context"
	)

	local gradle_map_multiline_version = assert(
		Gradle.debug_parse(table.concat({
			"implementation(",
			'    group: "org.springframework.kafka",',
			'    name: "spring-kafka",',
			'    version: "',
		}, "\n")),
		"Gradle multiline map version parser returned nil"
	)

	eq(
		{
			kind = gradle_map_multiline_version.kind,
			group_id = gradle_map_multiline_version.group_id,
			artifact_id = gradle_map_multiline_version.artifact_id,
			value = gradle_map_multiline_version.value,
		},
		{
			kind = "version",
			group_id = "org.springframework.kafka",
			artifact_id = "spring-kafka",
			value = "",
		},
		"Gradle multiline map notation must parse version completion context"
	)

	local gradle_map_parenthesized_single_line = assert(
		Gradle.debug_parse(
			'implementation(group: "org.springframework.kafka", name: "spring-kafka", version: "'
		),
		"Gradle parenthesized map parser returned nil"
	)

	eq(
		{
			kind = gradle_map_parenthesized_single_line.kind,
			group_id = gradle_map_parenthesized_single_line.group_id,
			artifact_id = gradle_map_parenthesized_single_line.artifact_id,
			notation = gradle_map_parenthesized_single_line.notation,
		},
		{
			kind = "version",
			group_id = "org.springframework.kafka",
			artifact_id = "spring-kafka",
			notation = "map",
		},
		"Gradle parenthesized map notation must parse dependency coordinates"
	)

	--------------------------------------------------------------------------------
end
