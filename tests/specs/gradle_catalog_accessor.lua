local GradleCatalogAccessor = require("blink_deps.gradle_catalog_accessor")

return function(test)
	local eq = test.eq
	local ok = test.ok

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
end
