local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Maven = require("blink_deps.maven")
local Gradle = require("blink_deps.gradle")

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
-- GRADLE PARSER
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
	Gradle.debug_parse([[
implementation(
    "org.springframework.kafka:spring-kafka:
]]),
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
	Gradle.debug_parse([[
implementation(
    platform(
        "org.springframework.boot:spring-boot-dependencies:
]]),
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
