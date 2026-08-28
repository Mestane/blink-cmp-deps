local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local DiskCache = require("blink_deps.disk_cache")
local Maven = require("blink_deps.maven")
local Gradle = require("blink_deps.gradle")
local GradleKts = require("blink_deps.gradle_kts")
local Catalog = require("blink_deps.catalog")
local GradleCatalogAccessor = require("blink_deps.gradle_catalog_accessor")
local Repository = require("blink_deps.repository")
local Coordinates = require("blink_deps.coordinates")
local VersionRank = require("blink_deps.version_rank")

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

local function replace_central_search(fn)
	rawset(Central, "search", fn)
end

local function replace_repository_versions(fn)
	rawset(Repository, "versions", fn)
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

ok(
	#maven_broad.central > 0,
	"plain Maven group search must produce at least one Central query"
)

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

ok(
	gradle_self_test.spring_kafka,
	"Gradle Spring Kafka cold-start group must exist"
)

ok(
	gradle_self_test.apache_kafka,
	"Gradle Apache Kafka cold-start group must exist"
)

ok(
	gradle_self_test.google_guava,
	"Gradle Google Guava cold-start group must exist"
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

ok(
	gradle_kts_self_test.spring_kafka,
	"Gradle Kotlin DSL Spring Kafka cold-start group must exist"
)

ok(
	gradle_kts_self_test.apache_kafka,
	"Gradle Kotlin DSL Apache Kafka cold-start group must exist"
)

ok(
	gradle_kts_self_test.google_guava,
	"Gradle Kotlin DSL Google Guava cold-start group must exist"
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
-- GRADLE VERSION CATALOG
--------------------------------------------------------------------------------

local catalog_source = Catalog.new({})

ok(
	type(catalog_source) == "table",
	"Version Catalog source must be constructible"
)

local catalog_self_test = Catalog.self_test()

eq(
	catalog_self_test.central_url,
	Central.URL,
	"Version Catalog source must use the shared Central backend URL"
)

ok(
	catalog_self_test.spring_kafka,
	"Version Catalog Spring Kafka cold-start group must exist"
)

ok(
	catalog_self_test.apache_kafka,
	"Version Catalog Apache Kafka cold-start group must exist"
)

ok(
	catalog_self_test.google_guava,
	"Version Catalog Google Guava cold-start group must exist"
)

local catalog_shorthand_group = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka = "org.springframework.ka',
	}, "\n")),
	"Version Catalog shorthand group parser returned nil"
)

eq(
	{
		kind = catalog_shorthand_group.kind,
		value = catalog_shorthand_group.value,
		notation = catalog_shorthand_group.notation,
	},
	{
		kind = "group",
		value = "org.springframework.ka",
		notation = "shorthand",
	},
	"Version Catalog shorthand must parse group completion context"
)

local catalog_shorthand_artifact = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka = "org.springframework.kafka:spring-',
	}, "\n")),
	"Version Catalog shorthand artifact parser returned nil"
)

eq(
	{
		kind = catalog_shorthand_artifact.kind,
		group_id = catalog_shorthand_artifact.group_id,
		value = catalog_shorthand_artifact.value,
	},
	{
		kind = "artifact",
		group_id = "org.springframework.kafka",
		value = "spring-",
	},
	"Version Catalog shorthand must parse artifact completion context"
)

local catalog_shorthand_version = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka = "org.springframework.kafka:spring-kafka:',
	}, "\n")),
	"Version Catalog shorthand version parser returned nil"
)

eq(
	{
		kind = catalog_shorthand_version.kind,
		group_id = catalog_shorthand_version.group_id,
		artifact_id = catalog_shorthand_version.artifact_id,
		value = catalog_shorthand_version.value,
	},
	{
		kind = "version",
		group_id = "org.springframework.kafka",
		artifact_id = "spring-kafka",
		value = "",
	},
	"Version Catalog shorthand must parse version completion context"
)

local catalog_module_group = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka = { module = "org.springframework.ka',
	}, "\n")),
	"Version Catalog module group parser returned nil"
)

eq(
	{
		kind = catalog_module_group.kind,
		value = catalog_module_group.value,
		notation = catalog_module_group.notation,
	},
	{
		kind = "group",
		value = "org.springframework.ka",
		notation = "module",
	},
	"Version Catalog module field must parse group completion context"
)

local catalog_module_artifact = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka = { module = "org.springframework.kafka:spring-',
	}, "\n")),
	"Version Catalog module artifact parser returned nil"
)

eq(
	{
		kind = catalog_module_artifact.kind,
		group_id = catalog_module_artifact.group_id,
		value = catalog_module_artifact.value,
	},
	{
		kind = "artifact",
		group_id = "org.springframework.kafka",
		value = "spring-",
	},
	"Version Catalog module field must parse artifact completion context"
)

local catalog_field_group = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka = { group = "org.springframework.ka',
	}, "\n")),
	"Version Catalog group field parser returned nil"
)

eq(
	{
		kind = catalog_field_group.kind,
		value = catalog_field_group.value,
	},
	{
		kind = "group",
		value = "org.springframework.ka",
	},
	"Version Catalog group field must parse group completion context"
)

local catalog_field_artifact = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka = { group = "org.springframework.kafka", name = "spring-',
	}, "\n")),
	"Version Catalog name field parser returned nil"
)

eq(
	{
		kind = catalog_field_artifact.kind,
		group_id = catalog_field_artifact.group_id,
		value = catalog_field_artifact.value,
	},
	{
		kind = "artifact",
		group_id = "org.springframework.kafka",
		value = "spring-",
	},
	"Version Catalog name field must use the completed group"
)

local catalog_field_version = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka = { group = "org.springframework.kafka", name = "spring-kafka", version = "',
	}, "\n")),
	"Version Catalog version field parser returned nil"
)

eq(
	{
		kind = catalog_field_version.kind,
		group_id = catalog_field_version.group_id,
		artifact_id = catalog_field_version.artifact_id,
		value = catalog_field_version.value,
	},
	{
		kind = "version",
		group_id = "org.springframework.kafka",
		artifact_id = "spring-kafka",
		value = "",
	},
	"Version Catalog version field must use group and name"
)

local catalog_module_version = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka = { module = "org.springframework.kafka:spring-kafka", version = "',
	}, "\n")),
	"Version Catalog module/version parser returned nil"
)

eq(
	{
		kind = catalog_module_version.kind,
		group_id = catalog_module_version.group_id,
		artifact_id = catalog_module_version.artifact_id,
	},
	{
		kind = "version",
		group_id = "org.springframework.kafka",
		artifact_id = "spring-kafka",
	},
	"Version Catalog version field must derive coordinates from module"
)

local catalog_version_ref = assert(
	Catalog.debug_parse(table.concat({
		"[versions]",
		'spring-kafka = "3.3.0"',
		"",
		"[libraries]",
		'spring-kafka = { module = "org.springframework.kafka:spring-kafka", version.ref = "spring-',
	}, "\n")),
	"Version Catalog version.ref parser returned nil"
)

eq(
	{
		kind = catalog_version_ref.kind,
		value = catalog_version_ref.value,
		field = catalog_version_ref.field,
	},
	{
		kind = "version_ref",
		value = "spring-",
		field = "version.ref",
	},
	"Version Catalog must parse version.ref completion context"
)

eq(
	Catalog.debug_parse(table.concat({
		"[versions]",
		'spring-kafka = "3.',
	}, "\n")),
	nil,
	"Version Catalog source must not treat [versions] values as dependency coordinates"
)

local catalog_dotted_module = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka.module = "org.springframework.kafka:spring-',
	}, "\n")),
	"Version Catalog dotted module parser returned nil"
)

eq(
	{
		kind = catalog_dotted_module.kind,
		group_id = catalog_dotted_module.group_id,
		value = catalog_dotted_module.value,
		notation = catalog_dotted_module.notation,
	},
	{
		kind = "artifact",
		group_id = "org.springframework.kafka",
		value = "spring-",
		notation = "dotted",
	},
	"Version Catalog dotted module declarations must be supported"
)

local catalog_dotted_version = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka.module = "org.springframework.kafka:spring-kafka"',
		'spring-kafka.version = "',
	}, "\n")),
	"Version Catalog dotted version parser returned nil"
)

eq(
	{
		kind = catalog_dotted_version.kind,
		group_id = catalog_dotted_version.group_id,
		artifact_id = catalog_dotted_version.artifact_id,
		value = catalog_dotted_version.value,
		notation = catalog_dotted_version.notation,
	},
	{
		kind = "version",
		group_id = "org.springframework.kafka",
		artifact_id = "spring-kafka",
		value = "",
		notation = "dotted",
	},
	"Version Catalog dotted version must derive coordinates from dotted module"
)

local catalog_dotted_fields_version = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka.group = "org.springframework.kafka"',
		'spring-kafka.name = "spring-kafka"',
		'spring-kafka.version = "',
	}, "\n")),
	"Version Catalog dotted group/name/version parser returned nil"
)

eq(
	{
		kind = catalog_dotted_fields_version.kind,
		group_id = catalog_dotted_fields_version.group_id,
		artifact_id = catalog_dotted_fields_version.artifact_id,
	},
	{
		kind = "version",
		group_id = "org.springframework.kafka",
		artifact_id = "spring-kafka",
	},
	"Version Catalog dotted version must derive coordinates from dotted group/name"
)

local catalog_dotted_version_ref = assert(
	Catalog.debug_parse(table.concat({
		"[versions]",
		'spring-kafka = "3.3.0"',
		"",
		"[libraries]",
		'spring-kafka.module = "org.springframework.kafka:spring-kafka"',
		'spring-kafka.version.ref = "spring-',
	}, "\n")),
	"Version Catalog dotted version.ref parser returned nil"
)

eq(
	{
		kind = catalog_dotted_version_ref.kind,
		value = catalog_dotted_version_ref.value,
		field = catalog_dotted_version_ref.field,
		notation = catalog_dotted_version_ref.notation,
	},
	{
		kind = "version_ref",
		value = "spring-",
		field = "version.ref",
		notation = "dotted",
	},
	"Version Catalog dotted version.ref must complete [versions] aliases"
)

eq(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka.module = "org.springframework.kafka:spring-kafka:',
	}, "\n")),
	nil,
	"Version Catalog module field must reject group:artifact:version coordinates"
)

local catalog_hyphen_shorthand = assert(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka-deneme = "org.springframework.kafka:spring-kafka:',
	}, "\n")),
	"Version Catalog hyphenated shorthand alias parser returned nil"
)

eq(
	{
		kind = catalog_hyphen_shorthand.kind,
		alias = catalog_hyphen_shorthand.alias,
		group_id = catalog_hyphen_shorthand.group_id,
		artifact_id = catalog_hyphen_shorthand.artifact_id,
	},
	{
		kind = "version",
		alias = "spring-kafka-deneme",
		group_id = "org.springframework.kafka",
		artifact_id = "spring-kafka",
	},
	"Hyphenated aliases must remain valid shorthand dependency declarations"
)

eq(
	Catalog.debug_parse(table.concat({
		"[libraries]",
		'spring-kafka.afdaf = "org.springframework.kafka:spring-kafka:',
	}, "\n")),
	nil,
	"Unknown dotted catalog fields must not fall back to shorthand parsing"
)

eq(
	Catalog.debug_group_insert_text(
		"module",
		"org.springframework.kafka"
	),
	"org.springframework.kafka:",
	"Module group completion must insert a trailing colon"
)

eq(
	Catalog.debug_group_insert_text(
		nil,
		"org.springframework.kafka"
	),
	"org.springframework.kafka",
	"Shorthand group completion must not insert a trailing colon"
)

eq(
	Catalog.debug_version_aliases(table.concat({
		"[versions]",
		'spring-kafka = "3.3.0"',
		'junit = "5.12.0"',
		"",
		"[libraries]",
		'spring-kafka = { module = "org.springframework.kafka:spring-kafka", version.ref = "spring-kafka" }',
	}, "\n")),
	{
		"junit",
		"spring-kafka",
	},
	"Version Catalog version.ref completion must discover [versions] aliases"
)

--------------------------------------------------------------------------------
-- GRADLE VERSION CATALOG ACCESSORS
--------------------------------------------------------------------------------

local accessor_source = GradleCatalogAccessor.new({})

ok(
	type(accessor_source) == "table",
	"Gradle Catalog Accessor source must be constructible"
)

--------------------------------------------------------------------------------
-- ROOT ACCESSOR
--------------------------------------------------------------------------------

local accessor_root = assert(
	GradleCatalogAccessor.debug_parse(
		"implementation(li"
	),
	"Gradle Catalog Accessor root parser returned nil"
)

eq(
	{
		kind = accessor_root.kind,
		value = accessor_root.value,
	},
	{
		kind = "root",
		value = "li",
	},
	"Gradle Catalog Accessor must parse partial libs root"
)

local accessor_root_complete = assert(
	GradleCatalogAccessor.debug_parse(
		"implementation(libs"
	),
	"Gradle Catalog Accessor complete root parser returned nil"
)

eq(
	{
		kind = accessor_root_complete.kind,
		value = accessor_root_complete.value,
	},
	{
		kind = "root",
		value = "libs",
	},
	"Gradle Catalog Accessor must parse complete libs root"
)

--------------------------------------------------------------------------------
-- LIBRARY ACCESSOR CONTEXT
--------------------------------------------------------------------------------

local accessor_first = assert(
	GradleCatalogAccessor.debug_parse(
		"implementation(libs."
	),
	"Gradle Catalog Accessor first segment parser returned nil"
)

eq(
	{
		kind = accessor_first.kind,
		prefix = accessor_first.prefix,
		value = accessor_first.value,
	},
	{
		kind = "accessor",
		prefix = "",
		value = "",
	},
	"Gradle Catalog Accessor must parse libs root namespace"
)

local accessor_spring = assert(
	GradleCatalogAccessor.debug_parse(
		"implementation(libs.spring."
	),
	"Gradle Catalog Accessor spring segment parser returned nil"
)

eq(
	{
		kind = accessor_spring.kind,
		prefix = accessor_spring.prefix,
		value = accessor_spring.value,
	},
	{
		kind = "accessor",
		prefix = "spring.",
		value = "",
	},
	"Gradle Catalog Accessor must parse nested accessor namespace"
)

local accessor_kafka = assert(
	GradleCatalogAccessor.debug_parse(
		"implementation(libs.spring.kafka."
	),
	"Gradle Catalog Accessor kafka segment parser returned nil"
)

eq(
	{
		kind = accessor_kafka.kind,
		prefix = accessor_kafka.prefix,
		value = accessor_kafka.value,
	},
	{
		kind = "accessor",
		prefix = "spring.kafka.",
		value = "",
	},
	"Gradle Catalog Accessor must parse deeply nested accessor namespace"
)

--------------------------------------------------------------------------------
-- CONFIGURATION ISOLATION
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_parse(
		"println(li"
	),
	nil,
	"Gradle Catalog Accessor must not activate in arbitrary Kotlin calls"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"something(libs."
	),
	nil,
	"Gradle Catalog Accessor must only activate in dependency configurations"
)

--------------------------------------------------------------------------------
-- LIBRARY ALIAS EXTRACTION
--------------------------------------------------------------------------------

local accessor_aliases = GradleCatalogAccessor.debug_extract_aliases(
	table.concat({
		"[versions]",
		'spring = "1.0.0"',
		"",
		"[libraries]",
		'spring-kafka-module = "org.springframework.kafka:spring-kafka:1.0.0"',
		'spring-kafka-version = "org.springframework.kafka:spring-kafka:1.0.0"',
		'spring-kafka-deneme = "org.springframework.kafka:spring-kafka:1.0.0"',
		'spring-kafka-alakasiz = "org.springframework.kafka:spring-kafka-bom:1.0.0"',
	}, "\n")
)

eq(
	accessor_aliases,
	{
		"spring.kafka.alakasiz",
		"spring.kafka.deneme",
		"spring.kafka.module",
		"spring.kafka.version",
	},
	"Gradle Catalog Accessor must convert library aliases to Gradle accessor paths"
)

--------------------------------------------------------------------------------
-- ACCESSOR SEGMENT COMPLETION
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_candidates(
		accessor_aliases,
		{
			prefix = "",
			value = "",
		}
	),
	{
		"spring",
	},
	"libs. must expose the first accessor segment"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		accessor_aliases,
		{
			prefix = "spring.",
			value = "",
		}
	),
	{
		"kafka",
	},
	"libs.spring. must expose the next accessor segment"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		accessor_aliases,
		{
			prefix = "spring.kafka.",
			value = "",
		}
	),
	{
		"alakasiz",
		"deneme",
		"module",
		"version",
	},
	"libs.spring.kafka. must expose leaf accessor segments"
)

--------------------------------------------------------------------------------
-- PARTIAL ACCESSOR FILTERING
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_candidates(
		accessor_aliases,
		{
			prefix = "",
			value = "spr",
		}
	),
	{
		"spring",
	},
	"Gradle Catalog Accessor must filter partial first segments"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		accessor_aliases,
		{
			prefix = "spring.kafka.",
			value = "de",
		}
	),
	{
		"deneme",
	},
	"Gradle Catalog Accessor must filter partial leaf segments"
)

--------------------------------------------------------------------------------
-- VERSION ACCESSORS
--------------------------------------------------------------------------------

local version_accessor_aliases =
	GradleCatalogAccessor.debug_extract_version_aliases(
		table.concat({
			"[versions]",
			'spring-boot = "4.0.0"',
			'spring-kafka = "4.0.0"',
			'junit = "6.0.0"',
			"",
			"[libraries]",
			'spring-kafka = "org.springframework.kafka:spring-kafka:4.0.0"',
		}, "\n")
	)

eq(
	version_accessor_aliases,
	{
		"junit",
		"spring.boot",
		"spring.kafka",
	},
	"Gradle Catalog Accessor must extract [versions] aliases"
)

local version_accessor_root = assert(
	GradleCatalogAccessor.debug_parse(
		"val version = libs.versions."
	),
	"Gradle version accessor root parser returned nil"
)

eq(
	{
		kind = version_accessor_root.kind,
		prefix = version_accessor_root.prefix,
		value = version_accessor_root.value,
	},
	{
		kind = "version_accessor",
		prefix = "",
		value = "",
	},
	"libs.versions. must parse version accessor root"
)

local version_accessor_nested = assert(
	GradleCatalogAccessor.debug_parse(
		"val version = libs.versions.spring."
	),
	"Gradle nested version accessor parser returned nil"
)

eq(
	{
		kind = version_accessor_nested.kind,
		prefix = version_accessor_nested.prefix,
		value = version_accessor_nested.value,
	},
	{
		kind = "version_accessor",
		prefix = "spring.",
		value = "",
	},
	"libs.versions.spring. must parse nested version accessor"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		version_accessor_aliases,
		{
			prefix = "",
			value = "",
		}
	),
	{
		"junit",
		"spring",
	},
	"libs.versions. must expose first version accessor segments"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		version_accessor_aliases,
		{
			prefix = "spring.",
			value = "",
		}
	),
	{
		"boot",
		"kafka",
	},
	"libs.versions.spring. must expose nested version aliases"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		version_accessor_aliases,
		{
			prefix = "spring.",
			value = "ka",
		}
	),
	{
		"kafka",
	},
	"Gradle version accessor must support partial filtering"
)

--------------------------------------------------------------------------------
-- CATALOG NAMESPACE
--------------------------------------------------------------------------------

local version_namespace_root = assert(
	GradleCatalogAccessor.debug_parse(
		"val testVersion = libs."
	),
	"Gradle catalog namespace root parser returned nil"
)

eq(
	{
		kind = version_namespace_root.kind,
		value = version_namespace_root.value,
	},
	{
		kind = "namespace",
		value = "",
	},
	"libs. must expose catalog namespaces outside dependency configurations"
)

local version_namespace_partial = assert(
	GradleCatalogAccessor.debug_parse(
		"val testVersion = libs.ver"
	),
	"Gradle catalog namespace partial parser returned nil"
)

eq(
	{
		kind = version_namespace_partial.kind,
		value = version_namespace_partial.value,
	},
	{
		kind = "namespace",
		value = "ver",
	},
	"libs.ver must parse partial versions namespace"
)

eq(
	GradleCatalogAccessor.debug_completion_candidates(
		{},
		version_accessor_aliases,
        {},
		{
			kind = "namespace",
			prefix = "",
			value = "",
		}
	),
	{
		"versions",
	},
	"libs. must suggest the versions namespace"
)

-- Important:
-- [versions] aliases are not dependency notation.
eq(
	GradleCatalogAccessor.debug_completion_candidates(
		accessor_aliases,
		version_accessor_aliases,
        {},
		{
			kind = "accessor",
			prefix = "",
			value = "",
		}
	),
	{
		"spring",
	},
	"dependency libs. completion must expose only library aliases"
)

--------------------------------------------------------------------------------
-- ASSIGNMENT ROOT COMPLETION
--------------------------------------------------------------------------------

local assignment_root_empty = assert(
	GradleCatalogAccessor.debug_parse(
		"val testVersion = "
	),
	"Gradle Catalog Accessor assignment root parser returned nil"
)

eq(
	{
		kind = assignment_root_empty.kind,
		value = assignment_root_empty.value,
	},
	{
		kind = "root",
		value = "",
	},
	"Gradle Catalog Accessor must suggest libs after a val assignment"
)

local assignment_root_partial = assert(
	GradleCatalogAccessor.debug_parse(
		"val testVersion = li"
	),
	"Gradle Catalog Accessor partial assignment root parser returned nil"
)

eq(
	{
		kind = assignment_root_partial.kind,
		value = assignment_root_partial.value,
	},
	{
		kind = "root",
		value = "li",
	},
	"Gradle Catalog Accessor must complete partial libs in a val assignment"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"val testVersion = something"
	),
	nil,
	"Gradle Catalog Accessor must not hijack unrelated assignment values"
)

--------------------------------------------------------------------------------
-- ACCESSOR SAFETY / REGRESSION
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_parse(
		"val testVersion = mylibs."
	),
	nil,
	"Gradle Catalog Accessor must not match mylibs as libs"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"val testVersion = mylibs.versions."
	),
	nil,
	"Gradle Catalog Accessor must not match mylibs.versions"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"implementation(libs.versions."
	),
	nil,
	"Version accessors must not be suggested as dependency notation"
)

eq(
	GradleCatalogAccessor.debug_extract_version_aliases(
		table.concat({
			"[versions]",
			'spring_boot = "4.0.0"',
			'kotlin-jvm = "2.3.21"',
		}, "\n")
	),
	{
		"kotlin.jvm",
		"spring.boot",
	},
	"Version aliases must normalize underscores and hyphens"
)

--------------------------------------------------------------------------------
-- BUNDLE ACCESSORS
--------------------------------------------------------------------------------

local bundle_accessor_aliases =
	GradleCatalogAccessor.debug_extract_bundle_aliases(
		table.concat({
			"[bundles]",
			'spring-stack = ["spring-web", "spring-data"]',
			'test_utils = ["junit", "mockito"]',
			"",
			"[versions]",
			'spring = "4.0.0"',
		}, "\n")
	)

eq(
	bundle_accessor_aliases,
	{
		"spring.stack",
		"test.utils",
	},
	"Gradle Catalog Accessor must extract and normalize [bundles] aliases"
)

local bundle_accessor_root = assert(
	GradleCatalogAccessor.debug_parse(
		"implementation(libs.bundles."
	),
	"Gradle bundle accessor root parser returned nil"
)

eq(
	{
		kind = bundle_accessor_root.kind,
		prefix = bundle_accessor_root.prefix,
		value = bundle_accessor_root.value,
	},
	{
		kind = "bundle_accessor",
		prefix = "",
		value = "",
	},
	"libs.bundles. must parse inside dependency configurations"
)

local bundle_accessor_nested = assert(
	GradleCatalogAccessor.debug_parse(
		"implementation(libs.bundles.spring."
	),
	"Gradle nested bundle accessor parser returned nil"
)

eq(
	{
		kind = bundle_accessor_nested.kind,
		prefix = bundle_accessor_nested.prefix,
		value = bundle_accessor_nested.value,
	},
	{
		kind = "bundle_accessor",
		prefix = "spring.",
		value = "",
	},
	"libs.bundles.spring. must parse nested bundle accessors"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		bundle_accessor_aliases,
		{
			prefix = "",
			value = "",
		}
	),
	{
		"spring",
		"test",
	},
	"libs.bundles. must expose first bundle accessor segments"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		bundle_accessor_aliases,
		{
			prefix = "spring.",
			value = "",
		}
	),
	{
		"stack",
	},
	"libs.bundles.spring. must expose nested bundle aliases"
)

eq(
	GradleCatalogAccessor.debug_completion_candidates(
		accessor_aliases,
		version_accessor_aliases,
		bundle_accessor_aliases,
		{
			kind = "accessor",
			prefix = "",
			value = "",
		}
	),
	{
		"bundles",
		"spring",
	},
	"dependency libs. completion must expose libraries and bundles"
)

eq(
	GradleCatalogAccessor.debug_completion_candidates(
		{},
		version_accessor_aliases,
		bundle_accessor_aliases,
		{
			kind = "namespace",
			prefix = "",
			value = "",
		}
	),
	{
		"bundles",
		"versions",
	},
	"generic libs. completion must expose bundles and versions namespaces"
)

--------------------------------------------------------------------------------
-- BUNDLE ACCESSOR REGRESSION
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_completion_candidates(
		accessor_aliases,
		version_accessor_aliases,
		bundle_accessor_aliases,
		{
			kind = "accessor",
			prefix = "",
			value = "bu",
		}
	),
	{
		"bundles",
	},
	"dependency libs.bu must complete the bundles namespace"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		bundle_accessor_aliases,
		{
			prefix = "spring.",
			value = "st",
		}
	),
	{
		"stack",
	},
	"Gradle bundle accessor must support partial nested filtering"
)

eq(
	GradleCatalogAccessor.debug_completion_candidates(
		accessor_aliases,
		version_accessor_aliases,
		{},
		{
			kind = "accessor",
			prefix = "",
			value = "",
		}
	),
	{
		"spring",
	},
	"dependency libs. must not expose bundles when [bundles] is empty"
)

eq(
	GradleCatalogAccessor.debug_completion_candidates(
		{},
		version_accessor_aliases,
		{},
		{
			kind = "namespace",
			prefix = "",
			value = "",
		}
	),
	{
		"versions",
	},
	"generic libs. must not expose bundles when [bundles] is empty"
)

--------------------------------------------------------------------------------
-- PLUGIN ACCESSORS
--------------------------------------------------------------------------------

local plugin_accessor_aliases =
	GradleCatalogAccessor.debug_extract_plugin_aliases(
		table.concat({
			"[plugins]",
			'spring-boot = { id = "org.springframework.boot", version = "4.1.1" }',
			'kotlin_jvm = { id = "org.jetbrains.kotlin.jvm", version = "2.3.21" }',
			"",
			"[libraries]",
			'spring-web = "org.springframework:spring-web:7.0.0"',
		}, "\n")
	)

eq(
	plugin_accessor_aliases,
	{
		"kotlin.jvm",
		"spring.boot",
	},
	"Gradle Catalog Accessor must extract and normalize [plugins] aliases"
)

--------------------------------------------------------------------------------
-- DOTTED PLUGIN DECLARATIONS
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_extract_plugin_aliases(
		table.concat({
			"[plugins]",
			'spring-boot.id = "org.springframework.boot"',
			'spring-boot.version = "4.1.1"',
			'kotlin-jvm.id = "org.jetbrains.kotlin.jvm"',
			'kotlin-jvm.version.ref = "kotlin"',
		}, "\n")
	),
	{
		"kotlin.jvm",
		"spring.boot",
	},
	"Gradle Catalog Accessor must deduplicate dotted plugin declarations"
)

eq(
	GradleCatalogAccessor.debug_extract_plugin_aliases(
		table.concat({
			"[plugins]",
			'spring-boot.foo = "invalid"',
		}, "\n")
	),
	{},
	"Unknown dotted plugin fields must not become plugin aliases"
)

--------------------------------------------------------------------------------
-- ALIAS ROOT
--------------------------------------------------------------------------------

local plugin_alias_root = assert(
	GradleCatalogAccessor.debug_parse(
		"alias(li"
	),
	"Gradle plugin alias root parser returned nil"
)

eq(
	{
		kind = plugin_alias_root.kind,
		value = plugin_alias_root.value,
	},
	{
		kind = "root",
		value = "li",
	},
	"alias(li must complete the libs root"
)

--------------------------------------------------------------------------------
-- PLUGIN NAMESPACE
--------------------------------------------------------------------------------

local plugin_namespace = assert(
	GradleCatalogAccessor.debug_parse(
		"alias(libs."
	),
	"Gradle plugin namespace parser returned nil"
)

eq(
	{
		kind = plugin_namespace.kind,
		prefix = plugin_namespace.prefix,
		value = plugin_namespace.value,
	},
	{
		kind = "plugin_namespace",
		prefix = "",
		value = "",
	},
	"alias(libs. must enter the plugin namespace"
)

eq(
	GradleCatalogAccessor.debug_completion_candidates(
		accessor_aliases,
		version_accessor_aliases,
		bundle_accessor_aliases,
		plugin_accessor_aliases,
		{
			kind = "plugin_namespace",
			prefix = "",
			value = "",
		}
	),
	{
		"plugins",
	},
	"alias(libs. must expose only the plugins namespace"
)

--------------------------------------------------------------------------------
-- PLUGIN ACCESSOR CONTEXT
--------------------------------------------------------------------------------

local plugin_accessor_root = assert(
	GradleCatalogAccessor.debug_parse(
		"alias(libs.plugins."
	),
	"Gradle plugin accessor root parser returned nil"
)

eq(
	{
		kind = plugin_accessor_root.kind,
		prefix = plugin_accessor_root.prefix,
		value = plugin_accessor_root.value,
	},
	{
		kind = "plugin_accessor",
		prefix = "",
		value = "",
	},
	"libs.plugins. must parse inside alias()"
)

local plugin_accessor_nested = assert(
	GradleCatalogAccessor.debug_parse(
		"alias(libs.plugins.spring."
	),
	"Gradle nested plugin accessor parser returned nil"
)

eq(
	{
		kind = plugin_accessor_nested.kind,
		prefix = plugin_accessor_nested.prefix,
		value = plugin_accessor_nested.value,
	},
	{
		kind = "plugin_accessor",
		prefix = "spring.",
		value = "",
	},
	"libs.plugins.spring. must parse nested plugin accessors"
)

--------------------------------------------------------------------------------
-- PLUGIN CANDIDATES
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_candidates(
		plugin_accessor_aliases,
		{
			prefix = "",
			value = "",
		}
	),
	{
		"kotlin",
		"spring",
	},
	"libs.plugins. must expose first plugin accessor segments"
)

eq(
	GradleCatalogAccessor.debug_candidates(
		plugin_accessor_aliases,
		{
			prefix = "spring.",
			value = "",
		}
	),
	{
		"boot",
	},
	"libs.plugins.spring. must expose nested plugin aliases"
)

--------------------------------------------------------------------------------
-- PLUGIN CONTEXT ISOLATION
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_parse(
		"alias(libs.bundles."
	),
	nil,
	"alias() must not expose bundle accessors"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"alias(libs.versions."
	),
	nil,
	"alias() must not expose version accessors"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"implementation(libs.plugins."
	),
	nil,
	"Plugin accessors must not be suggested as dependency notation"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"something(libs.plugins."
	),
	nil,
	"Arbitrary function calls must not activate plugin accessors"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"notalias(libs.plugins."
	),
	nil,
	"Functions ending in alias must not activate plugin alias completion"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"something(libs.bundles."
	),
	nil,
	"Arbitrary function calls must not activate bundle accessors"
)

eq(
	GradleCatalogAccessor.debug_parse(
		"something(libs.versions."
	),
	nil,
	"Arbitrary function calls must not activate version accessors"
)

--------------------------------------------------------------------------------
-- GENERIC NAMESPACE
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_completion_candidates(
		{},
		version_accessor_aliases,
		bundle_accessor_aliases,
		plugin_accessor_aliases,
		{
			kind = "namespace",
			prefix = "",
			value = "",
		}
	),
	{
		"bundles",
		"plugins",
		"versions",
	},
	"generic libs. completion must expose all available catalog namespaces"
)

--------------------------------------------------------------------------------
-- DEPENDENCY ISOLATION
--------------------------------------------------------------------------------

eq(
	GradleCatalogAccessor.debug_completion_candidates(
		accessor_aliases,
		version_accessor_aliases,
		bundle_accessor_aliases,
		plugin_accessor_aliases,
		{
			kind = "accessor",
			prefix = "",
			value = "",
		}
	),
	{
		"bundles",
		"spring",
	},
	"dependency libs. completion must not expose plugins or versions"
)

--------------------------------------------------------------------------------
-- PERSISTENT CACHE
--------------------------------------------------------------------------------

local cache_test_root = vim.fn.tempname() .. "-blink-cmp-deps"

local cache_opts = {
	dir = cache_test_root,
	ttl = 86400,
}

local cache_docs = {
	{
		g = "org.springframework.kafka",
		a = "spring-kafka",
		latestVersion = "4.0.0",
	},
}

--------------------------------------------------------------------------------
-- DEFAULTS
--------------------------------------------------------------------------------

eq(
	DiskCache.DEFAULT_TTL,
	86400,
	"Persistent cache default TTL must be 24 hours"
)

--------------------------------------------------------------------------------
-- WRITE / READ
--------------------------------------------------------------------------------

local cache_written, cache_write_err =
	DiskCache.set(
		cache_opts,
		"central",
		"basic",
		cache_docs
	)

ok(
	cache_written and cache_write_err == nil,
	"Persistent cache must write valid data"
)

local cached_docs, cache_status =
	DiskCache.get(
		cache_opts,
		"central",
		"basic"
	)

eq(
	cache_status,
	"hit",
	"Persistent cache must report a cache hit"
)

eq(
	cached_docs,
	cache_docs,
	"Persistent cache must restore written data"
)

--------------------------------------------------------------------------------
-- OVERWRITE
--------------------------------------------------------------------------------

local replacement_docs = {
	{
		g = "org.springframework.kafka",
		a = "spring-kafka",
		latestVersion = "4.1.0",
	},
}

local overwrite_written, overwrite_err =
	DiskCache.set(
		cache_opts,
		"central",
		"basic",
		replacement_docs
	)

ok(
	overwrite_written and overwrite_err == nil,
	"Persistent cache must overwrite an existing entry"
)

local overwritten_docs =
	DiskCache.get(
		cache_opts,
		"central",
		"basic"
	)

eq(
	overwritten_docs,
	replacement_docs,
	"Persistent cache overwrite must expose the newest data"
)

--------------------------------------------------------------------------------
-- DISABLED CACHE
--------------------------------------------------------------------------------

local disabled_written, disabled_write_status =
	DiskCache.set(
		{
			dir = cache_test_root,
			enabled = false,
		},
		"central",
		"disabled",
		cache_docs
	)

ok(
	disabled_written == false
		and disabled_write_status == "disabled",
	"Disabled persistent cache must not write entries"
)

local disabled_data, disabled_read_status =
	DiskCache.get(
		{
			dir = cache_test_root,
			enabled = false,
		},
		"central",
		"disabled"
	)

ok(
	disabled_data == nil
		and disabled_read_status == "disabled",
	"Disabled persistent cache must not read entries"
)

--------------------------------------------------------------------------------
-- CORRUPTED CACHE
--------------------------------------------------------------------------------

local corrupt_path =
	DiskCache.debug_path(
		cache_opts,
		"central",
		"corrupt"
	)

vim.fn.mkdir(vim.fs.dirname(corrupt_path), "p")

vim.fn.writefile(
	{
		"{ definitely-not-valid-json",
	},
	corrupt_path
)

local corrupt_data, corrupt_status =
	DiskCache.get(
		cache_opts,
		"central",
		"corrupt"
	)

ok(
	corrupt_data == nil
		and corrupt_status == "invalid",
	"Corrupted persistent cache entries must be treated as misses"
)

eq(
	vim.fn.filereadable(corrupt_path),
	0,
	"Corrupted persistent cache entries must be removed"
)

--------------------------------------------------------------------------------
-- STALE CACHE
--------------------------------------------------------------------------------

local stale_path =
	DiskCache.debug_path(
		cache_opts,
		"central",
		"stale"
	)

vim.fn.mkdir(vim.fs.dirname(stale_path), "p")

vim.fn.writefile(
	{
		vim.json.encode({
			schema = DiskCache.SCHEMA_VERSION,
			created_at = os.time() - 10,
			data = cache_docs,
		}),
	},
	stale_path
)

local stale_data, stale_status =
	DiskCache.get(
		{
			dir = cache_test_root,
			ttl = 1,
		},
		"central",
		"stale"
	)

ok(
	stale_data == nil
		and stale_status == "stale",
	"Expired persistent cache entries must be treated as stale"
)

eq(
	vim.fn.filereadable(stale_path),
	0,
	"Expired persistent cache entries must be removed"
)

--------------------------------------------------------------------------------
-- REQUEST FINGERPRINT
--------------------------------------------------------------------------------

local fingerprint_source = {
	opts = {},
}

local fingerprint_one =
	Central.debug_request_fingerprint(
		fingerprint_source,
		{
			q = "g:org.springframework.kafka",
			rows = "200",
			wt = "json",
		}
	)

local fingerprint_two =
	Central.debug_request_fingerprint(
		fingerprint_source,
		{
			wt = "json",
			q = "g:org.springframework.kafka",
			rows = "200",
		}
	)

eq(
	fingerprint_one,
	fingerprint_two,
	"Central request fingerprint must not depend on Lua table iteration order"
)

local fingerprint_different_args =
	Central.debug_request_fingerprint(
		fingerprint_source,
		{
			q = "g:org.springframework.kafka",
			rows = "100",
			wt = "json",
		}
	)

ok(
	fingerprint_one ~= fingerprint_different_args,
	"Central request fingerprint must change when request arguments change"
)

local fingerprint_different_url =
	Central.debug_request_fingerprint(
		{
			opts = {
				central_url = "https://example.invalid/search",
			},
		},
		{
			q = "g:org.springframework.kafka",
			rows = "200",
			wt = "json",
		}
	)

ok(
	fingerprint_one ~= fingerprint_different_url,
	"Central request fingerprint must include the Central URL"
)

--------------------------------------------------------------------------------
-- CENTRAL.SEARCH DISK CACHE INTEGRATION
--------------------------------------------------------------------------------

local integration_source = {
	opts = {
		debug = false,

		cache = {
			dir = cache_test_root,
			ttl = 86400,
		},
	},

	central_cache = {},
	central_inflight = {},
}

local integration_args = {
	q = "g:org.example",
	rows = "200",
	wt = "json",
}

local integration_fingerprint =
	Central.debug_request_fingerprint(
		integration_source,
		integration_args
	)

local integration_docs = {
	{
		g = "org.example",
		a = "example-core",
		latestVersion = "1.0.0",
	},
}

local integration_written, integration_write_err =
	DiskCache.set(
		integration_source.opts.cache,
		"central",
		integration_fingerprint,
		integration_docs
	)

ok(
	integration_written
		and integration_write_err == nil,
	"Central integration test cache entry must be writable"
)

local integration_called = false
local integration_result
local integration_error

Central.search(
	integration_source,
	"integration:key",
	integration_args,
	function(docs, err)
		integration_called = true
		integration_result = docs
		integration_error = err
	end
)

ok(
	integration_called,
	"Central.search must resolve synchronously from persistent cache"
)

eq(
	integration_result,
	integration_docs,
	"Central.search must return data from persistent cache"
)

eq(
	integration_error,
	nil,
	"Central.search persistent cache hit must not return an error"
)

eq(
	integration_source.central_cache["integration:key"],
	integration_docs,
	"Central.search must promote persistent data into session memory cache"
)


--------------------------------------------------------------------------------
-- FILESYSTEM FAILURE
--------------------------------------------------------------------------------

local blocked_cache_root =
	vim.fn.tempname() .. "-blink-cmp-deps-blocked"

vim.fn.writefile(
	{
		"this is a file, not a directory",
	},
	blocked_cache_root
)

local blocked_written, blocked_error =
	DiskCache.set(
		{
			dir = blocked_cache_root,
			ttl = 86400,
		},
		"central",
		"blocked",
		cache_docs
	)

ok(
	blocked_written == false
		and blocked_error == "mkdir failed",
	"Persistent cache filesystem failures must be non-fatal"
)

vim.fn.delete(blocked_cache_root)

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

vim.fn.delete(cache_test_root, "rf")

--------------------------------------------------------------------------------
-- CUSTOM MAVEN REPOSITORIES
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- METADATA URL
--------------------------------------------------------------------------------

eq(
	Repository.debug_metadata_url(
		{
			url = "https://repo.company.com/maven/releases",
		},
		"com.company.payment",
		"payment-client"
	),
	"https://repo.company.com/maven/releases/com/company/payment/payment-client/maven-metadata.xml",
	"Custom repository metadata URL must follow the Maven repository layout"
)

eq(
	Repository.debug_metadata_url(
		{
			url = "https://repo.company.com/maven/releases/",
		},
		"com.company.payment",
		"payment-client"
	),
	"https://repo.company.com/maven/releases/com/company/payment/payment-client/maven-metadata.xml",
	"Custom repository metadata URL must ignore trailing repository slashes"
)

--------------------------------------------------------------------------------
-- METADATA VERSION PARSING
--------------------------------------------------------------------------------

eq(
	Repository.debug_extract_versions([[
<metadata>
	<groupId>com.company.payment</groupId>
	<artifactId>payment-client</artifactId>

	<versioning>
		<versions>
			<version>1.0.0</version>
			<version>1.1.0</version>
			<version>1.1.0</version>
			<version>2.0.0</version>
		</versions>
	</versioning>
</metadata>
	]]),
	{
		"1.0.0",
		"1.1.0",
		"2.0.0",
	},
	"Custom repository metadata must extract and deduplicate versions"
)

eq(
	Repository.debug_extract_versions([[
<metadata>
	<versioning>
		<versions>
			<version>
				1.0.0&amp;build
			</version>
		</versions>
	</versioning>
</metadata>
	]]),
	{
		"1.0.0&build",
	},
	"Custom repository metadata must trim values and decode XML entities"
)

eq(
	Repository.debug_extract_versions([[
<metadata>
	<versioning>
		<versions>
		</versions>
	</versioning>
</metadata>
	]]),
	{},
	"Custom repository metadata without versions must return an empty list"
)

--------------------------------------------------------------------------------
-- REPOSITORY NAME
--------------------------------------------------------------------------------

eq(
	Repository.debug_name({
		name = "Company Releases",
		url = "https://repo.company.com/releases",
	}),
	"Company Releases",
	"Custom repository must prefer its configured display name"
)

eq(
	Repository.debug_name({
		url = "https://repo.company.com/releases",
	}),
	"https://repo.company.com/releases",
	"Custom repository must fall back to its URL as the display name"
)

--------------------------------------------------------------------------------
-- CACHE IDENTITY
--------------------------------------------------------------------------------

local repository_cache_key =
	Repository.debug_cache_key(
		{
			url = "https://repo.company.com/maven/releases",
		},
		"com.company.payment",
		"payment-client"
	)

local repository_cache_key_with_slash =
	Repository.debug_cache_key(
		{
			url = "https://repo.company.com/maven/releases/",
		},
		"com.company.payment",
		"payment-client"
	)

eq(
	repository_cache_key,
	repository_cache_key_with_slash,
	"Custom repository cache key must normalize trailing repository slashes"
)

local different_repository_cache_key =
	Repository.debug_cache_key(
		{
			url = "https://repo.example.com/maven/releases",
		},
		"com.company.payment",
		"payment-client"
	)

ok(
	repository_cache_key ~= different_repository_cache_key,
	"Custom repository cache key must include the repository URL"
)

local different_artifact_cache_key =
	Repository.debug_cache_key(
		{
			url = "https://repo.company.com/maven/releases",
		},
		"com.company.payment",
		"other-client"
	)

ok(
	repository_cache_key ~= different_artifact_cache_key,
	"Custom repository cache key must include Maven coordinates"
)

--------------------------------------------------------------------------------
-- INVALID REPOSITORY
--------------------------------------------------------------------------------

local invalid_repository_called = false
local invalid_repository_versions
local invalid_repository_error

Repository.versions(
	{
		opts = {
			cache = {
				enabled = false,
			},
		},
	},
	{},
	"com.company",
	"demo",
	function(versions, err)
		invalid_repository_called = true
		invalid_repository_versions = versions
		invalid_repository_error = err
	end
)

ok(
	invalid_repository_called,
	"Invalid custom repositories must resolve without starting a request"
)

eq(
	invalid_repository_versions,
	{},
	"Invalid custom repositories must return no versions"
)

eq(
	invalid_repository_error,
	"invalid repository",
	"Invalid custom repositories must return an explicit error"
)

--------------------------------------------------------------------------------
-- CUSTOM REPOSITORY VERSION AGGREGATION
--------------------------------------------------------------------------------

local function test_context()
	return {
		get_pos = function()
			return {
				row = 0,
				col = 0,
			}
		end,
	}
end

local function sorted_response_labels(result)
	local labels = {}

	for _, item in ipairs((result and result.items) or {}) do
		table.insert(labels, item.label)
	end

	table.sort(labels)
	return labels
end

local function sorted_cached_versions(entries)
	local versions = {}

	for _, entry in ipairs(entries or {}) do
		table.insert(versions, entry.value)
	end

	table.sort(versions)
	return versions
end

--------------------------------------------------------------------------------
-- VERSION RANKING INTEGRATION
--------------------------------------------------------------------------------

local ranking_central_search =
	Central.search

local ranking_repository_versions =
	Repository.versions

local ranking_central_callback
local ranking_repository_callback

replace_central_search(function(_, _, _, callback)
	ranking_central_callback = callback
end)

replace_repository_versions(function(_, _, _, _, callback)
	ranking_repository_callback = callback
end)

local ranking_source =
	Coordinates.new_state()

ranking_source.opts = {
	repositories = {
		{
			name = "Company Releases",
			url = "https://repo.company.test/releases",
		},
	},
}

local ranking_responses = {}

Coordinates.complete_version(
	ranking_source,
	test_context(),
	{
		value = "",
	},
	"com.company",
	"ranked-library",
	function(result)
		table.insert(
			ranking_responses,
			result
		)
	end
)

--------------------------------------------------------------------------
-- Maven Central deliberately has very large timestamps.
--
-- These timestamps must NOT make older versions outrank newer versions
-- coming from a custom Maven repository.
--------------------------------------------------------------------------

ranking_central_callback(
	{
		{
			v = "4.9.9",
			timestamp = 999999999999,
		},
		{
			v = "3.0.0-RC1",
			timestamp = 999999999999,
		},
		{
			v = "2.9.0",
			timestamp = 999999999999,
		},
	},
	nil
)

eq(
	sorted_response_labels(
		ranking_responses[
			#ranking_responses
		]
	),
	{
		"2.9.0",
		"3.0.0-RC1",
		"4.9.9",
	},
	"Partial Central results must still contain all versions"
)

ranking_repository_callback(
	{
		"5.0.0-internal",
		"3.0.0",
		"2.10.0",
	},
	nil
)

local ranked_completion_labels = {}

for _, item in ipairs(
	ranking_responses[
		#ranking_responses
	].items or {}
) do
	table.insert(
		ranked_completion_labels,
		item.label
	)
end

eq(
	ranked_completion_labels,
	{
		"5.0.0-internal",
		"4.9.9",
		"3.0.0",
		"3.0.0-RC1",
		"2.10.0",
		"2.9.0",
	},
	"Version completion must use semantic ranking instead of backend timestamps"
)

local ranked_sort_texts = {}

for _, item in ipairs(
	ranking_responses[
		#ranking_responses
	].items or {}
) do
	table.insert(
		ranked_sort_texts,
		item.sortText
	)
end

eq(
	ranked_sort_texts,
	{
		"000001",
		"000002",
		"000003",
		"000004",
		"000005",
		"000006",
	},
	"Version completion must expose semantic ranking through sortText"
)

local ranked_items =
	ranking_responses[
		#ranking_responses
	].items or {}

local semantic_score_order = true

for index = 2, #ranked_items do
	local previous =
		ranked_items[index - 1].score_offset

	local current =
		ranked_items[index].score_offset

	if type(previous) ~= "number"
		or type(current) ~= "number"
		or previous <= current
	then
		semantic_score_order = false
		break
	end
end

ok(
	semantic_score_order,
	"Version completion must expose semantic ranking through score_offset"
)

local query_ranking_source =
	Coordinates.new_state()

query_ranking_source.opts = {}

query_ranking_source.version_catalog[
	"org.springframework.kafka:spring-kafka"
] = {
	{
		value = "4.0.0",
		timestamp = 0,
	},
	{
		value = "2.5.16.RELEASE",
		timestamp = 0,
	},
	{
		value = "2.5.11.RELEASE",
		timestamp = 0,
	},
	{
		value = "2.5.10.RELEASE",
		timestamp = 0,
	},
	{
		value = "1.0.0.RELEASE",
		timestamp = 0,
	},
}

local release_query_response

Coordinates.complete_version(
	query_ranking_source,
	test_context(),
	{
		value = "release",
	},
	"org.springframework.kafka",
	"spring-kafka",
	function(result)
		release_query_response = result
	end
)

local release_offsets = {}

for _, item in ipairs(
	(release_query_response and release_query_response.items)
		or {}
) do
	release_offsets[item.label] =
		item.score_offset
end

ok(
	release_offsets["2.5.16.RELEASE"]
		> release_offsets["2.5.11.RELEASE"]
		and release_offsets["2.5.11.RELEASE"]
			> release_offsets["2.5.10.RELEASE"]
		and release_offsets["2.5.10.RELEASE"]
			> release_offsets["1.0.0.RELEASE"],
	"Matching version queries must preserve semantic ranking through score_offset"
)

eq(
	release_offsets["4.0.0"],
	0,
	"Non-matching versions must not receive a query ranking score_offset"
)

local ranked_cached_values = {}

for _, entry in ipairs(
	ranking_source.version_catalog[
		"com.company:ranked-library"
	] or {}
) do
	table.insert(
		ranked_cached_values,
		entry.value
	)
end

eq(
	ranked_cached_values,
	{
		"5.0.0-internal",
		"4.9.9",
		"3.0.0",
		"3.0.0-RC1",
		"2.10.0",
		"2.9.0",
	},
	"Version catalog must preserve semantic ranking after aggregation"
)

local cached_ranking_response

Coordinates.complete_version(
	ranking_source,
	test_context(),
	{
		value = "",
	},
	"com.company",
	"ranked-library",
	function(result)
		cached_ranking_response = result
	end
)

local cached_sort_texts = {}

for _, item in ipairs(
	(cached_ranking_response and cached_ranking_response.items)
		or {}
) do
	table.insert(
		cached_sort_texts,
		item.sortText
	)
end

eq(
	cached_sort_texts,
	{
		"000001",
		"000002",
		"000003",
		"000004",
		"000005",
		"000006",
	},
	"Cached version completion must preserve semantic sortText ordering"
)

replace_central_search(ranking_central_search)

replace_repository_versions(ranking_repository_versions)

--------------------------------------------------------------------------------
-- CENTRAL + CUSTOM REPOSITORY MERGE
--------------------------------------------------------------------------------

local original_central_search = Central.search
local original_repository_versions = Repository.versions

local central_callback
local repository_callback

replace_central_search(function(_, _, _, callback)
	central_callback = callback
end)

replace_repository_versions(function(_, _, _, _, callback)
	repository_callback = callback
end)

local aggregate_source = Coordinates.new_state()

aggregate_source.opts = {
	repositories = {
		{
			name = "Company Releases",
			url = "https://repo.company.test/releases",
		},
	},
}

local aggregate_responses = {}

Coordinates.complete_version(
	aggregate_source,
	test_context(),
	{
		value = "",
	},
	"com.company",
	"payment-client",
	function(result)
		table.insert(aggregate_responses, result)
	end
)

ok(
	type(central_callback) == "function",
	"Version aggregation must start the Maven Central backend"
)

ok(
	type(repository_callback) == "function",
	"Version aggregation must start configured custom repositories"
)

central_callback(
	{
		{
			v = "1.0.0",
			timestamp = 100,
		},
		{
			v = "2.0.0",
			timestamp = 200,
		},
	},
	nil
)

eq(
	aggregate_source.version_catalog["com.company:payment-client"],
	nil,
	"Partial version results must not be stored as a complete version catalog"
)

eq(
	sorted_response_labels(
		aggregate_responses[#aggregate_responses]
	),
	{
		"1.0.0",
		"2.0.0",
	},
	"Central versions must be emitted while custom repositories are still pending"
)

repository_callback(
	{
		"2.0.0",
		"3.0.0-company",
	},
	nil
)

eq(
	sorted_response_labels(
		aggregate_responses[#aggregate_responses]
	),
	{
		"1.0.0",
		"2.0.0",
		"3.0.0-company",
	},
	"Central and custom repository versions must be merged and deduplicated"
)

eq(
	sorted_cached_versions(
		aggregate_source.version_catalog[
			"com.company:payment-client"
		]
	),
	{
		"1.0.0",
		"2.0.0",
		"3.0.0-company",
	},
	"Complete aggregated versions must be stored in the version catalog"
)

--------------------------------------------------------------------------------
-- CUSTOM REPOSITORY FAILURE
--------------------------------------------------------------------------------

local repository_failure_central_callback
local repository_failure_repository_callback

replace_central_search(function(_, _, _, callback)
	repository_failure_central_callback = callback
end)

replace_repository_versions(function(_, _, _, _, callback)
	repository_failure_repository_callback = callback
end)

local repository_failure_source =
	Coordinates.new_state()

repository_failure_source.opts = {
	repositories = {
		{
			url = "https://repo.company.test/releases",
		},
	},
}

Coordinates.complete_version(
	repository_failure_source,
	test_context(),
	{ value = "" },
	"org.example",
	"central-only",
	function() end
)

repository_failure_central_callback(
	{
		{
			v = "1.0.0",
			timestamp = 100,
		},
	},
	nil
)

repository_failure_repository_callback(
	{},
	"repository unavailable"
)

eq(
	sorted_cached_versions(
		repository_failure_source.version_catalog[
			"org.example:central-only"
		]
	),
	{
		"1.0.0",
	},
	"Custom repository failure must not discard Maven Central versions"
)

--------------------------------------------------------------------------------
-- MAVEN CENTRAL FAILURE
--------------------------------------------------------------------------------

local central_failure_central_callback
local central_failure_repository_callback

replace_central_search(function(_, _, _, callback)
	central_failure_central_callback = callback
end)

replace_repository_versions(function(_, _, _, _, callback)
	central_failure_repository_callback = callback
end)

local central_failure_source =
	Coordinates.new_state()

central_failure_source.opts = {
	repositories = {
		{
			url = "https://repo.company.test/releases",
		},
	},
}

Coordinates.complete_version(
	central_failure_source,
	test_context(),
	{ value = "" },
	"com.company",
	"private-only",
	function() end
)

central_failure_central_callback(
	{},
	"Maven Central unavailable"
)

central_failure_repository_callback(
	{
		"5.0.0-internal",
	},
	nil
)

eq(
	sorted_cached_versions(
		central_failure_source.version_catalog[
			"com.company:private-only"
		]
	),
	{
		"5.0.0-internal",
	},
	"Maven Central failure must not discard custom repository versions"
)

--------------------------------------------------------------------------------
-- CENTRAL-ONLY BEHAVIOUR
--------------------------------------------------------------------------------

local central_only_repository_calls = 0

replace_central_search(function(_, _, _, callback)
	callback(
		{
			{
				v = "7.0.0",
				timestamp = 700,
			},
		},
		nil
	)
end)

replace_repository_versions(function()
	central_only_repository_calls =
		central_only_repository_calls + 1
end)

local central_only_source =
	Coordinates.new_state()

central_only_source.opts = {}

Coordinates.complete_version(
	central_only_source,
	test_context(),
	{ value = "" },
	"org.example",
	"normal-library",
	function() end
)

eq(
	central_only_repository_calls,
	0,
	"Version completion must not query custom repositories when none are configured"
)

eq(
	sorted_cached_versions(
		central_only_source.version_catalog[
			"org.example:normal-library"
		]
	),
	{
		"7.0.0",
	},
	"Central-only version completion must preserve existing behaviour"
)

--------------------------------------------------------------------------------
-- RESTORE BACKENDS
--------------------------------------------------------------------------------

replace_central_search(original_central_search)
replace_repository_versions(original_repository_versions)


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
-- SHARED RESULT HELPERS
--------------------------------------------------------------------------------

local docs = Util.dedupe_docs({
	{
		g = "org.example",
		a = "demo",
		latestVersion = "1.0.0",
	},
	{
		g = "org.example",
		a = "demo",
		latestVersion = "1.0.0",
	},
	{
		g = "org.example",
		a = "other",
		latestVersion = "2.0.0",
	},
})

eq(
	#docs,
	2,
	"duplicate Central/JDTLS documents must be removed"
)

local artifacts = Util.extract_artifacts(
	docs,
	"org.example"
)

eq(
	#artifacts,
	2,
	"artifact extraction must preserve distinct artifacts"
)

eq(
	artifacts[1].artifact,
	"demo",
	"artifacts must be sorted by artifactId"
)

eq(
	artifacts[2].artifact,
	"other",
	"artifacts must be sorted by artifactId"
)

print(string.format(
	"blink-cmp-deps: %d tests passed",
	total
))
