local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Maven = require("blink_deps.maven")
local Gradle = require("blink_deps.gradle")
local GradleKts = require("blink_deps.gradle_kts")

local total = 0

local function fail(message)
	error(message, 2)
end

local function ok(condition, message)
	total = total + 1
	if not condition then
		fail("FAILED: " .. message)
	end
end

local function eq(actual, expected, message)
	total = total + 1
	if not vim.deep_equal(actual, expected) then
		fail(string.format(
			"FAILED: %s\nexpected: %s\nactual:   %s",
			message,
			vim.inspect(expected),
			vim.inspect(actual)
		))
	end
end

local function contains(values, expected)
	for _, value in ipairs(values) do
		if value == expected then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- MAVEN
--------------------------------------------------------------------------------

local maven_source = Maven.new({})
eq(maven_source.opts.jdtls.enabled, false, "JDTLS must be disabled by default")

local maven_self_test = Maven.self_test()
eq(maven_self_test.jdtls_default, false, "self-test must report JDTLS disabled by default")
eq(maven_self_test.central_url, Central.URL, "Maven source must use the shared Central backend URL")
ok(maven_self_test.kafka, "Spring Kafka cold-start group must exist")
ok(maven_self_test.apache_kafka, "Apache Kafka cold-start group must exist")
ok(maven_self_test.google_guava, "Google Guava cold-start group must exist")

local maven_qualified = Maven.debug_group_plan("org.springframework.ka")
ok(
	contains(maven_qualified.central, "g:org.springframework.ka*"),
	"qualified Maven group search must use an unquoted Maven Central query"
)

local maven_broad = Maven.debug_group_plan("spring")
ok(#maven_broad.central > 0, "plain Maven group search must produce at least one Central query")

local maven_seeds = Maven.debug_seed_groups("org.springframework.ka")
ok(
	contains(maven_seeds, "org.springframework.kafka"),
	"qualified Maven cold-start filtering must keep Spring Kafka"
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

eq(
	maven_artifact.target,
	"g:org.springframework.kafka AND a:*spri*",
	"Maven targeted artifact query must remain unquoted"
)

eq(
	maven_artifact.version_query,
	"g:org.springframework.kafka AND a:spring-kafka",
	"Maven version query must remain unquoted"
)

--------------------------------------------------------------------------------
-- GRADLE
--------------------------------------------------------------------------------

local gradle_source = Gradle.new({})
ok(type(gradle_source) == "table", "Gradle source must be constructible")

local gradle_self_test = Gradle.self_test()
eq(gradle_self_test.central_url, Central.URL, "Gradle source must use the shared Central backend URL")
ok(gradle_self_test.spring_kafka, "Gradle Spring Kafka cold-start group must exist")
ok(gradle_self_test.apache_kafka, "Gradle Apache Kafka cold-start group must exist")
ok(gradle_self_test.google_guava, "Gradle Google Guava cold-start group must exist")

local gradle_qualified = Gradle.debug_group_plan("org.springframework.ka")
ok(
	contains(gradle_qualified.central, "g:org.springframework.ka*"),
	"qualified Gradle group search must use an unquoted Maven Central query"
)

local gradle_broad = Gradle.debug_group_plan("spring")
ok(#gradle_broad.central > 0, "plain Gradle group search must produce at least one Central query")

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

eq(
	gradle_artifact.target,
	"g:org.springframework.kafka AND a:*spri*",
	"Gradle targeted artifact query must remain unquoted"
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
-- GRADLE KOTLIN DSL
--------------------------------------------------------------------------------

local gradle_kts_source = GradleKts.new({})
ok(type(gradle_kts_source) == "table", "Gradle Kotlin DSL source must be constructible")

local gradle_kts_self_test = GradleKts.self_test()
eq(
	gradle_kts_self_test.central_url,
	Central.URL,
	"Gradle Kotlin DSL source must use the shared Central backend URL"
)
ok(gradle_kts_self_test.spring_kafka, "Gradle Kotlin DSL Spring Kafka cold-start group must exist")
ok(gradle_kts_self_test.apache_kafka, "Gradle Kotlin DSL Apache Kafka cold-start group must exist")
ok(gradle_kts_self_test.google_guava, "Gradle Kotlin DSL Google Guava cold-start group must exist")

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
-- SHARED RESULT HELPERS
--------------------------------------------------------------------------------

local docs = Util.dedupe_docs({
	{ g = "org.example", a = "demo", latestVersion = "1.0.0" },
	{ g = "org.example", a = "demo", latestVersion = "1.0.0" },
	{ g = "org.example", a = "other", latestVersion = "2.0.0" },
})

eq(#docs, 2, "duplicate Central/JDTLS documents must be removed")

local artifacts = Util.extract_artifacts(docs, "org.example")
eq(#artifacts, 2, "artifact extraction must preserve distinct artifacts")
eq(artifacts[1].artifact, "demo", "artifacts must be sorted by artifactId")
eq(artifacts[2].artifact, "other", "artifacts must be sorted by artifactId")

print(string.format("blink-cmp-deps: %d tests passed", total))
