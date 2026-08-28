local Source = require("blink_deps")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- UNIFIED SOURCE CONSTRUCTION
	--------------------------------------------------------------------------------

	local repositories = {
		{
			name = "Company Nexus",
			type = "nexus",
			url = "https://nexus.company.test",
			repository = "maven-releases",
		},
	}

	local source = Source.new({
		debug = true,
		repositories = repositories,
	})

	ok(
		type(source) == "table",
		"Unified dependency source must be constructible"
	)

	eq(
		{
			debug = source.opts.debug,
			repositories = source.opts.repositories,
		},
		{
			debug = true,
			repositories = repositories,
		},
		"Unified dependency source must preserve provider options"
	)

	--------------------------------------------------------------------------------
	-- FILE ROUTING
	--------------------------------------------------------------------------------

	eq(
		Source.debug_delegate_ids("/project/pom.xml"),
		{ "maven" },
		"pom.xml must route to the Maven delegate"
	)

	eq(
		Source.debug_delegate_ids("/project/build.gradle"),
		{ "gradle" },
		"build.gradle must route to the Gradle delegate"
	)

	eq(
		Source.debug_delegate_ids("/project/build.gradle.kts"),
		{
			"gradle_kts",
			"gradle_catalog_accessor",
		},
		"build.gradle.kts must route to coordinate and catalog accessor delegates"
	)

	eq(
		Source.debug_delegate_ids("/project/gradle/libs.versions.toml"),
		{ "catalog" },
		"Gradle version catalogs must route to the catalog delegate"
	)

	eq(
		Source.debug_delegate_ids("/project/dependencies.versions.toml"),
		{ "catalog" },
		"Custom *.versions.toml files must preserve catalog routing"
	)

	eq(
		Source.debug_delegate_ids("/project/src/main/java/App.java"),
		{},
		"Unsupported files must not activate dependency delegates"
	)

	--------------------------------------------------------------------------------
	-- ENABLED SOURCES
	--------------------------------------------------------------------------------

	local maven_only = { "maven" }

	eq(
		Source.debug_delegate_ids("/project/pom.xml", maven_only),
		{ "maven" },
		"Maven-only configuration must keep pom.xml completion enabled"
	)

	eq(
		Source.debug_delegate_ids("/project/build.gradle", maven_only),
		{},
		"Maven-only configuration must disable Gradle completion"
	)

	eq(
		Source.debug_delegate_ids("/project/build.gradle.kts", maven_only),
		{},
		"Maven-only configuration must disable Gradle Kotlin DSL completion"
	)

	eq(
		Source.debug_delegate_ids(
			"/project/gradle/libs.versions.toml",
			maven_only
		),
		{},
		"Maven-only configuration must disable version catalog completion"
	)

	eq(
		Source.debug_delegate_ids(
			"/project/build.gradle.kts",
			{ "gradle_kts" }
		),
		{
			"gradle_kts",
			"gradle_catalog_accessor",
		},
		"gradle_kts must include coordinate and version catalog accessor completion"
	)

	eq(
		Source.debug_delegate_ids(
			"/project/gradle/libs.versions.toml",
			{ "version_catalog" }
		),
		{ "catalog" },
		"version_catalog must enable *.versions.toml completion"
	)

	eq(
		Source.debug_delegate_ids("/project/pom.xml", {}),
		{},
		"An empty enabled_sources list must disable all dependency sources"
	)

	local invalid_type_ok = pcall(function()
		Source.new({
			enabled_sources = "maven",
		})
	end)

	ok(
		not invalid_type_ok,
		"enabled_sources must reject non-list values"
	)

	local invalid_name_ok = pcall(function()
		Source.new({
			enabled_sources = {
				"maven",
				"unknown",
			},
		})
	end)

	ok(
		not invalid_name_ok,
		"enabled_sources must reject unknown source names"
	)

	--------------------------------------------------------------------------------
	-- MULTI-DELEGATE SOURCE
	--------------------------------------------------------------------------------

	vim.api.nvim_buf_set_name(
		0,
		"/tmp/blink-cmp-deps-unified/build.gradle.kts"
	)

	local cancelled = 0
	local completion_source = Source.new({})

	completion_source.delegates.gradle_kts = {
		get_trigger_characters = function()
			return { ".", ":", "-", '"' }
		end,

		get_completions = function(_, _, callback)
			callback({
				items = {
					{
						label = "org.example:demo",
						data = {
							gradle_kts = {
								kind = "artifact",
							},
						},
					},
				},
				is_incomplete_forward = true,
				is_incomplete_backward = true,
			})

			return function()
				cancelled = cancelled + 1
			end
		end,

		resolve = function(_, item, callback)
			local resolved = vim.deepcopy(item)
			resolved.detail = "resolved by gradle_kts"
			callback(resolved)
		end,
	}

	completion_source.delegates.gradle_catalog_accessor = {
		get_trigger_characters = function()
			return { "." }
		end,

		get_completions = function(_, _, callback)
			callback({
				items = {
					{
						label = "spring.kafka",
					},
				},
				is_incomplete_forward = false,
				is_incomplete_backward = false,
			})

			return function()
				cancelled = cancelled + 1
			end
		end,
	}

	ok(
		completion_source:enabled(),
		"Unified source must enable itself for build.gradle.kts"
	)

	eq(
		completion_source:get_trigger_characters(),
		{ ".", ":", "-", '"' },
		"Unified source must merge and deduplicate delegate trigger characters"
	)

	local responses = {}

	local cancel = completion_source:get_completions(
		{},
		function(result)
			table.insert(responses, result)
		end
	)

	eq(
		#responses,
		2,
		"build.gradle.kts must stream responses from both delegates"
	)

	eq(
		{
			responses[1].items[1].label,
			responses[2].items[1].label,
		},
		{
			"org.example:demo",
			"spring.kafka",
		},
		"Unified source must preserve delegate completion results"
	)

	ok(
		type(cancel) == "function",
		"Unified source must return a cancellation function when delegates are cancellable"
	)

	cancel()

	eq(
		cancelled,
		2,
		"Unified source cancellation must cancel every active delegate request"
	)

	--------------------------------------------------------------------------------
	-- RESOLVE ROUTING
	--------------------------------------------------------------------------------

	eq(
		Source.debug_resolve_delegate({
			data = {
				maven = {},
			},
		}),
		"maven",
		"Maven completion data must route resolve to the Maven delegate"
	)

	eq(
		Source.debug_resolve_delegate({
			data = {
				gradle_kts = {},
			},
		}),
		"gradle_kts",
		"Gradle Kotlin DSL completion data must route resolve to its delegate"
	)

	local resolved_item

	completion_source:resolve(
		{
			label = "org.example:demo",
			data = {
				gradle_kts = {
					kind = "artifact",
				},
			},
		},
		function(item)
			resolved_item = item
		end
	)

	eq(
		resolved_item.detail,
		"resolved by gradle_kts",
		"Unified source must call the originating delegate resolve implementation"
	)

	local passthrough

	completion_source:resolve(
		{
			label = "spring.kafka",
		},
		function(item)
			passthrough = item
		end
	)

	eq(
		passthrough.label,
		"spring.kafka",
		"Items without delegate resolve data must pass through unchanged"
	)
end
