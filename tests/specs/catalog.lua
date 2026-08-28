local Central = require("blink_deps.central")
local Catalog = require("blink_deps.catalog")

return function(test)
	local eq = test.eq
	local ok = test.ok

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
end
