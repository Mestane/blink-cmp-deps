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

	--------------------------------------------------------------------------------
	-- SHARED STATE
	--
	-- One unified source serves every build file in a session. What it learns
	-- while one of them is open must be there when another is opened.
	--------------------------------------------------------------------------------

	local Coordinates = require("blink_deps.coordinates")

	local shared_source = Source.new({})

	eq(
		shared_source.shared_state,
		nil,
		"The coordinate state must not be built before a delegate needs it"
	)

	eq(
		shared_source:pipeline_stats(),
		{},
		"A source that has done nothing must report no pipelines"
	)

	local function delegate_for(path, id)
		vim.api.nvim_buf_set_name(0, path)

		-- Any call that reaches the delegates creates the ones this file needs.
		shared_source:get_trigger_characters()

		return shared_source.delegates[id]
	end

	local maven = delegate_for("/tmp/blink-cmp-deps-shared/pom.xml", "maven")
	local gradle = delegate_for("/tmp/blink-cmp-deps-shared/build.gradle", "gradle")

	local gradle_kts = delegate_for(
		"/tmp/blink-cmp-deps-shared/build.gradle.kts",
		"gradle_kts"
	)

	local catalog = delegate_for(
		"/tmp/blink-cmp-deps-shared/gradle/libs.versions.toml",
		"catalog"
	)

	ok(
		maven ~= nil and gradle ~= nil and gradle_kts ~= nil and catalog ~= nil,
		"Every coordinate delegate must be created on demand"
	)

	ok(
		maven ~= gradle and gradle ~= gradle_kts and gradle_kts ~= catalog,
		"Delegates must remain separate objects"
	)

	local shared_fields = {
		"group_memory",
		"artifact_catalog",
		"version_catalog",
		"notified",
		"central_cache",
		"central_inflight",
		"central_pipeline",
		"repository_cache",
		"repository_inflight",
		"repository_pipeline",
		"nexus_artifact_cache",
		"nexus_artifact_inflight",
		"nexus_artifact_pipeline",
		"nexus_group_cache",
		"nexus_group_inflight",
		"nexus_group_pipeline",
		"local_repository_pipeline",
	}

	for _, field in ipairs(shared_fields) do
		ok(
			type(maven[field]) == "table",
			"Shared state must provide " .. field
		)

		ok(
			maven[field] == gradle[field]
				and maven[field] == gradle_kts[field]
				and maven[field] == catalog[field]
				and maven[field] == shared_source.shared_state[field],
			"Every delegate must hold the same " .. field
		)
	end

	-- What one delegate learns, the others already know.
	maven.version_catalog["org.example:demo"] = {
		{ value = "1.0.0", timestamp = 0 },
	}

	eq(
		gradle_kts.version_catalog["org.example:demo"],
		{ { value = "1.0.0", timestamp = 0 } },
		"A version list learned in pom.xml must be visible in build.gradle.kts"
	)

	local Central = require("blink_deps.central")

	gradle.central_cache["artifact:group:org.example"] = {
		{ g = "org.example", a = "demo", latestVersion = "1.0.0" },
	}

	local shared_docs

	Central.search(
		catalog,
		"artifact:group:org.example",
		{ q = "g:org.example" },
		function(docs)
			shared_docs = docs
		end
	)

	eq(
		shared_docs,
		{ { g = "org.example", a = "demo", latestVersion = "1.0.0" } },
		"A Central result cached by one delegate must answer another without a request"
	)

	local pipeline_names = {}

	for _, stats in ipairs(shared_source:pipeline_stats()) do
		table.insert(pipeline_names, stats.name)
	end

	eq(
		pipeline_names,
		{
			"central",
			"repository",
			"nexus-artifact",
			"nexus-group",
			"local-repository",
		},
		"The unified source must report one pipeline per backend"
	)

	eq(
		shared_source:pipeline_stats()[1].memory,
		1,
		"Lookups from every delegate must be counted on the same pipeline"
	)

	-- Per delegate fields stay per delegate.
	ok(
		maven.opts ~= gradle.opts,
		"Each delegate must keep its own options table"
	)

	ok(
		maven.jdtls_cache ~= nil and gradle.jdtls_cache == nil,
		"Maven only state must not leak into other delegates"
	)

	-- Two unified sources do not share anything.
	local other_source = Source.new({})

	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-shared/pom.xml")
	other_source:get_trigger_characters()

	ok(
		other_source.delegates.maven.central_cache ~= maven.central_cache,
		"Separate unified sources must not share state"
	)

	-- A delegate used directly as a provider stays self-contained.
	local standalone_a = require("blink_deps.maven").new({})
	local standalone_b = require("blink_deps.gradle").new({})

	ok(
		standalone_a.central_cache ~= standalone_b.central_cache,
		"Standalone sources must not share state implicitly"
	)

	for _, field in ipairs(shared_fields) do
		ok(
			type(standalone_a[field]) == "table",
			"A standalone source must build its own " .. field
		)
	end

	eq(
		standalone_a.central_pipeline.memory,
		standalone_a.central_cache,
		"A pipeline must operate on the cache table of its own state"
	)

	-- new_state with an argument shares; without one it does not.
	local base = Coordinates.new_state()
	local view = Coordinates.new_state(base)

	ok(view ~= base, "A shared state must be a distinct object")

	ok(
		view.group_memory == base.group_memory,
		"A shared state must reference the same tables"
	)

	view.opts = { marker = true }

	eq(base.opts, nil, "Fields set on one holder must not appear on another")
end
