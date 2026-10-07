local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local LocalRepository =
	require("blink_deps.local_repository")
local Coordinates = require("blink_deps.coordinates")

return function(test)
	local eq = test.eq
	local ok = test.ok

	-- Discovery debounces its Central work. These specs drive the callbacks
	-- synchronously, so the timer has to run inline.
	rawset(Util, "defer", function(_, fn)
		fn()
	end)

	local function replace_central_search(fn)
		rawset(Central, "search", fn)
	end

	-- Scanning a real ~/.m2 in a test would be slow and machine dependent.
	local function replace_local_catalog(entries)
		rawset(
			LocalRepository,
			"catalog",
			function(_, callback)
				callback(entries)
			end
		)
	end

	local local_repository_original_catalog =
		LocalRepository.catalog

	replace_local_catalog({})

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

	--------------------------------------------------------------------------------
	-- DISCOVERY QUERY PLANNING
	--------------------------------------------------------------------------------

	eq(
		Coordinates.debug_discovery_query(
			"jackson-databind"
		).central,
		'a:"jackson-databind"',
		"A typed artifact id must become an exact Central term"
	)

	eq(
		Coordinates.debug_discovery_query(
			"spring data jpa"
		).central,
		"spring AND data AND jpa",
		"A multi word search must join its tokens"
	)

	eq(
		Coordinates.debug_discovery_query(
			"  kafka  "
		).central,
		'a:"kafka"',
		"Discovery must trim the typed value"
	)

	eq(
		Coordinates.debug_discovery_query(
			'js"on'
		).central,
		'a:"json"',
		"Discovery must not let a quote break out of the Solr term"
	)

	--------------------------------------------------------------------------------
	-- DISCOVERY ROUTING
	--
	-- A reverse domain value is a coordinate being typed and belongs to group
	-- completion, which owns namespace depth ranking.
	--------------------------------------------------------------------------------

	eq(
		Coordinates.debug_discovery_query(
			"org.springframework."
		).central,
		nil,
		"A qualified namespace must stay with group completion"
	)

	eq(
		Coordinates.debug_discovery_query(
			"org.springframework.boot"
		).central,
		nil,
		"A qualified coordinate must stay with group completion"
	)

	eq(
		Coordinates.debug_discovery_query(
			"ka"
		).central,
		nil,
		"Discovery must not search on a very short value"
	)

	--------------------------------------------------------------------------------
	-- DISCOVERY DEBOUNCE
	--
	-- A partly typed search term is never a useful query, and local matches are
	-- emitted immediately, so discovery can afford to wait longer than
	-- coordinate completion.
	--------------------------------------------------------------------------------

	local discovery_debounce_source =
		Coordinates.new_state()

	discovery_debounce_source.opts = {}

	ok(
		Coordinates.discovery_debounce_ms(
			discovery_debounce_source
		)
			> Coordinates.debounce_ms(
				discovery_debounce_source
			),
		"Discovery must wait longer than coordinate completion by default"
	)

	discovery_debounce_source.opts = {
		debounce_ms = 150,
	}

	eq(
		Coordinates.discovery_debounce_ms(
			discovery_debounce_source
		),
		150,
		"debounce_ms must lower the discovery delay too"
	)

	discovery_debounce_source.opts = {
		debounce_ms = 150,
		discovery_debounce_ms = 800,
	}

	eq(
		{
			Coordinates.debounce_ms(
				discovery_debounce_source
			),
			Coordinates.discovery_debounce_ms(
				discovery_debounce_source
			),
		},
		{ 150, 800 },
		"discovery_debounce_ms must override only the discovery delay"
	)

	--------------------------------------------------------------------------------
	-- DISCOVERY COMPLETION
	--------------------------------------------------------------------------------

	local discovery_original_central_search =
		Central.search

	local discovery_calls = {}

	replace_central_search(function(
		_,
		key,
		args,
		callback
	)
		table.insert(
			discovery_calls,
			{
				key = key,
				q = args.q,
				callback = callback,
			}
		)
	end)

	local discovery_source =
		Coordinates.new_state()

	discovery_source.opts = {}

	local discovery_responses = {}

	Coordinates.complete_discovery(
		discovery_source,
		test_context(),
		{
			value = "jackson-databind",
		},
		function(result)
			table.insert(
				discovery_responses,
				result
			)
		end,
		{
			data_key = "gradle_kts",
		}
	)

	eq(
		#discovery_calls,
		1,
		"Discovery must issue exactly one Central query"
	)

	eq(
		discovery_calls[1].q,
		'a:"jackson-databind"',
		"Discovery must send the planned query"
	)

	discovery_calls[1].callback(
		{
			{
				g = "io.github.behnazh-w.demo",
				a = "jackson-databind",
				latestVersion = "1.0",
			},
			{
				g = "com.fasterxml.jackson.core",
				a = "jackson-databind",
				latestVersion = "2.20",
			},
			{
				g = "com.fasterxml.jackson.core",
				a = "jackson-databind",
				latestVersion = "2.20",
			},
		},
		nil
	)

	local discovery_items =
		discovery_responses[
			#discovery_responses
		].items or {}

	eq(
		#discovery_items,
		2,
		"Discovery must collapse duplicate coordinates"
	)

	local discovery_labels = {}

	for _, item in ipairs(
		discovery_items
	) do
		discovery_labels[item.label] =
			item
	end

	local discovery_expected =
		discovery_labels[
			"com.fasterxml.jackson.core:jackson-databind"
		]

	ok(
		discovery_expected ~= nil,
		"Discovery items must be labelled with the full coordinate"
	)

	eq(
		discovery_expected.textEdit.newText,
		"com.fasterxml.jackson.core:jackson-databind:",
		"Discovery must insert a coordinate ready for version completion"
	)

	eq(
		discovery_expected.labelDetails.description,
		"2.20",
		"Discovery must show the latest version alongside the coordinate"
	)

	eq(
		discovery_expected.data.gradle_kts.kind,
		"artifact",
		"Discovery resolve data must use the calling source's key"
	)

	local discovery_incidental =
		discovery_labels[
			"io.github.behnazh-w.demo:jackson-databind"
		]

	ok(
		discovery_expected.score_offset
			> discovery_incidental.score_offset,
		"Discovery must rank a stronger group match ahead of an incidental one"
	)

	--------------------------------------------------------------------------------
	-- CANCELLED DISCOVERY
	--------------------------------------------------------------------------------

	discovery_calls = {}

	local cancelled_responses = {}

	local discovery_cancel =
		Coordinates.complete_discovery(
			Coordinates.new_state(),
			test_context(),
			{
				value = "spring data jpa",
			},
			function(result)
				table.insert(
					cancelled_responses,
					result
				)
			end,
			{}
		)

	eq(
		discovery_calls[1]
			and discovery_calls[1].q,
		"spring AND data AND jpa",
		"A multi word search must reach Central as a joined query"
	)

	local before_cancel =
		#cancelled_responses

	discovery_cancel()

	discovery_calls[1].callback(
		{
			{
				g = "org.springframework.boot",
				a = "spring-boot-starter-data-jpa",
				latestVersion = "3.5.0",
			},
		},
		nil
	)

	eq(
		#cancelled_responses,
		before_cancel,
		"A cancelled discovery must not send stale results to the UI"
	)

	--------------------------------------------------------------------------------
	-- DISCOVERY EDIT HOOK
	--
	-- Gradle replaces one string with the whole coordinate. Maven splits it
	-- across two XML elements and supplies its own edit, so the hook has to
	-- reach build_item.
	--------------------------------------------------------------------------------

	discovery_calls = {}

	local hooked_items = {}

	Coordinates.complete_discovery(
		Coordinates.new_state(),
		test_context(),
		{
			value = "jackson-databind",
		},
		function(result)
			for _, item in ipairs(
				result.items or {}
			) do
				table.insert(
					hooked_items,
					item
				)
			end
		end,
		{
			edit = function(
				_,
				_,
				group,
				artifact
			)
				return {
					range = {
						start = {
							line = 7,
							character = 21,
						},
						["end"] = {
							line = 8,
							character = 24,
						},
					},
					newText =
						group
						.. "|"
						.. artifact,
				}
			end,
		}
	)

	discovery_calls[1].callback(
		{
			{
				g = "com.fasterxml.jackson.core",
				a = "jackson-databind",
				latestVersion = "2.20",
			},
		},
		nil
	)

	eq(
		hooked_items[1].textEdit.newText,
		"com.fasterxml.jackson.core|jackson-databind",
		"opts.edit must decide the inserted text"
	)

	eq(
		hooked_items[1].textEdit.range["end"].line,
		8,
		"opts.edit must decide the replaced range, across lines if needed"
	)

	--------------------------------------------------------------------------------
	-- LOCAL REPOSITORY PATH PARSING
	--------------------------------------------------------------------------------

	eq(
		LocalRepository.parse_relative_path(
			"org/apache/kafka/kafka-clients/3.8.1/kafka-clients-3.8.1.pom"
		),
		{
			g = "org.apache.kafka",
			a = "kafka-clients",
			latestVersion = "3.8.1",
		},
		"A local repository path must yield its coordinate without reading the POM"
	)

	eq(
		LocalRepository.parse_relative_path(
			"junit/junit/4.13.2/junit-4.13.2.pom"
		),
		{
			g = "junit",
			a = "junit",
			latestVersion = "4.13.2",
		},
		"A single segment group must parse correctly"
	)

	eq(
		LocalRepository.parse_relative_path(
			"broken/path.pom"
		),
		nil,
		"A path too short to hold a coordinate must be ignored"
	)

	--------------------------------------------------------------------------------
	-- LOCAL REPOSITORY RESULTS
	--
	-- A coordinate already on disk is one the user has pulled into a project,
	-- which the search API has no way of knowing.
	--------------------------------------------------------------------------------

	replace_local_catalog({
		{
			g = "org.springframework.boot",
			a = "spring-boot-starter-web",
			latestVersion = "3.5.0",
		},
		{
			g = "org.springframework",
			a = "spring-web",
			latestVersion = "6.2.0",
		},
	})

	discovery_calls = {}

	local local_responses = {}

	Coordinates.complete_discovery(
		Coordinates.new_state(),
		test_context(),
		{
			value = "springframework",
		},
		function(result)
			table.insert(
				local_responses,
				result
			)
		end,
		{}
	)

	local local_items = {}

	for _, result in ipairs(
		local_responses
	) do
		for _, item in ipairs(
			result.items or {}
		) do
			table.insert(
				local_items,
				item
			)
		end
	end

	eq(
		#local_items,
		2,
		"Local repository matches must be emitted without waiting for Central"
	)

	local local_first =
		local_items[1].score_offset

	discovery_calls[1].callback(
		{
			{
				g = "org.bitbucket.risu8",
				a = "springframework",
				latestVersion = "1.0",
			},
			{
				g = "org.springframework",
				a = "spring-web",
				latestVersion = "6.2.0",
			},
		},
		nil
	)

	local merged = {}

	for _, result in ipairs(
		local_responses
	) do
		for _, item in ipairs(
			result.items or {}
		) do
			table.insert(merged, item)
		end
	end

	eq(
		#merged,
		3,
		"A coordinate already sent from disk must not be repeated from Central"
	)

	local central_only

	for _, item in ipairs(merged) do
		if item.label
			== "org.bitbucket.risu8:springframework"
		then
			central_only = item
		end
	end

	ok(
		central_only ~= nil
			and local_first
				> central_only.score_offset,
		"A local coordinate must outrank an incidental Central hit"
	)

	replace_local_catalog({})

	rawset(
		LocalRepository,
		"catalog",
		local_repository_original_catalog
	)

	replace_central_search(
		discovery_original_central_search
	)

	--------------------------------------------------------------------------------
	-- DISCOVERY THROUGH THE REGISTRY CONTRACT
	--
	-- Discovery asks whatever registries the source has. These use hand
	-- written registries, so nothing here depends on Maven Central or on the
	-- local repository existing.
	--------------------------------------------------------------------------------

	do
		local current_defer = Util.defer
		local deferred = {}
		local delays = {}

		rawset(Util, "defer", function(ms, fn)
			table.insert(delays, ms)
			table.insert(deferred, fn)
		end)

		local function registry(id, fields)
			local entry = vim.tbl_extend("force", {
				id = id,
				name = "Registry " .. id,
				kind = "test",
				capabilities = { search = true },
				calls = {},
			}, fields or {})

			entry.search = function(self, _, text, callback)
				table.insert(self.calls, {
					text = text,
					callback = callback,
				})
			end

			return entry
		end

		local function new_source(registries)
			local source = Coordinates.new_state()

			source.opts = {}
			source.registry_list = registries

			return source
		end

		local function complete(source, value, opts)
			local responses = {}

			local cancel = Coordinates.complete_discovery(
				source,
				test_context(),
				{ value = value },
				function(result)
					table.insert(responses, result)
				end,
				opts
			)

			return responses, cancel
		end

		local function labels(result)
			local list = {}

			for _, item in ipairs(result.items) do
				table.insert(list, item.label)
			end

			table.sort(list)

			return list
		end

		local disk = registry("disk", { offline = true })
		local public = registry("public", { public = true })
		local private = registry("private")
		local versions_only = registry("versions-only", {
			capabilities = { versions = true },
		})

		local source = new_source({ public, disk, versions_only, private })

		local responses = complete(source, '  Jackson-"Databind"  ')

		eq(#disk.calls, 1, "A registry answering from disk must be searched at once")

		eq(
			disk.calls[1].text,
			"jackson-databind",
			"Registries must receive the text lowercased, trimmed and without quotes"
		)

		eq(
			{ #public.calls, #private.calls },
			{ 0, 0 },
			"Remote registries must wait for the debounce"
		)

		eq(
			delays,
			{ 400 },
			"Discovery must use the longer discovery debounce"
		)

		disk.calls[1].callback({
			{
				namespace = "com.fasterxml.jackson.core",
				name = "jackson-databind",
				latest_version = "2.17.0",
			},
		}, nil)

		eq(
			labels(responses[1]),
			{ "com.fasterxml.jackson.core:jackson-databind" },
			"Results on disk must be offered before the network is asked"
		)

		deferred[1]()

		eq(
			{ #public.calls, #private.calls, #versions_only.calls },
			{ 1, 1, 0 },
			"Every registry that can search, and only those, must be asked"
		)

		public.calls[1].callback({
			{
				namespace = "com.fasterxml.jackson.core",
				name = "jackson-databind",
				latest_version = "2.20.0",
			},
			{
				namespace = "tools.jackson.core",
				name = "jackson-databind",
				latest_version = "3.0.0",
			},
			{ namespace = "", name = "broken" },
			{ namespace = "no.name" },
		}, nil)

		eq(
			labels(responses[2]),
			{ "tools.jackson.core:jackson-databind" },
			"A coordinate already offered must not be repeated, and invalid entries are dropped"
		)

		-- A configured registry takes part in discovery like any other.
		private.calls[1].callback({
			{
				namespace = "com.company",
				name = "jackson-databind-extras",
				latest_version = "1.0.0",
			},
		}, nil)

		eq(
			labels(responses[3]),
			{ "com.company:jackson-databind-extras" },
			"A configured registry must contribute to discovery"
		)

		local on_disk = responses[1].items[1]
		local remote = responses[2].items[1]

		ok(
			on_disk.score_offset - remote.score_offset
				== 1000,
			"A coordinate found on disk must carry the local relevance bonus"
		)

		eq(
			{
				on_disk.labelDetails.description,
				on_disk.textEdit.newText,
				on_disk.data.deps,
			},
			{
				"2.17.0",
				"com.fasterxml.jackson.core:jackson-databind:",
				{
					kind = "artifact",
					groupId = "com.fasterxml.jackson.core",
					artifactId = "jackson-databind",
					latestVersion = "2.17.0",
				},
			},
			"A discovery item must show the version, insert the coordinate and carry resolve data"
		)

		-- A failing registry is silent and leaves the others alone.
		disk = registry("disk", { offline = true })
		public = registry("public", { public = true })

		source = new_source({ disk, public })
		deferred = {}

		responses = complete(source, "jackson")

		deferred[1]()

		public.calls[1].callback({}, "timeout")

		eq(#responses, 0, "A failed search must not emit a response by itself")

		disk.calls[1].callback({
			{ namespace = "org.example", name = "jackson-thing" },
		}, nil)

		eq(
			labels(responses[1]),
			{ "org.example:jackson-thing" },
			"A failing registry must not discard what the others returned"
		)

		-- An answer with no matches still opens the menu exactly once.
		disk = registry("disk", { offline = true })
		public = registry("public", { public = true })

		source = new_source({ disk, public })
		deferred = {}

		responses = complete(source, "jackson")

		disk.calls[1].callback({}, nil)

		deferred[1]()

		public.calls[1].callback({}, nil)

		eq(
			{ #responses, #responses[1].items },
			{ 1, 0 },
			"Empty answers must produce a single empty response"
		)

		-- Not a search: nothing is asked.
		disk = registry("disk", { offline = true })

		source = new_source({ disk })
		deferred = {}

		responses = complete(source, "ab")

		eq(
			{ #disk.calls, #deferred, #responses },
			{ 0, 0, 1 },
			"A value too short to be a search must not reach any registry"
		)

		responses = complete(source, "org.springframework")

		eq(
			#disk.calls,
			0,
			"A coordinate being typed must not be treated as a search"
		)

		-- Cancelled during the debounce: the network is never asked.
		public = registry("public", { public = true })

		source = new_source({ public })
		deferred = {}

		local cancel

		responses, cancel = complete(source, "jackson")

		cancel()
		deferred[1]()

		eq(#public.calls, 0, "A superseded search must not reach a remote registry")

		-- The caller decides what accepting a result edits.
		disk = registry("disk", { offline = true })

		source = new_source({ disk })

		responses = complete(source, "jackson", {
			data_key = "maven",
			edit = function(_, _, group, artifact)
				return {
					newText = group .. "|" .. artifact,
				}
			end,
		})

		disk.calls[1].callback({
			{ namespace = "org.example", name = "jackson-thing" },
		}, nil)

		eq(
			{
				responses[1].items[1].textEdit.newText,
				responses[1].items[1].data.maven.latestVersion,
			},
			{ "org.example|jackson-thing", "unknown" },
			"A custom edit and data key must be honoured"
		)

		rawset(Util, "defer", current_defer)
	end

	--------------------------------------------------------------------------------
	-- MAVEN CENTRAL SEARCH PHRASING
	--------------------------------------------------------------------------------

	eq(
		Central.search_query("jackson-databind"),
		'a:"jackson-databind"',
		"A single term must be an exact artifact match"
	)

	eq(
		Central.search_query("spring  data-jpa"),
		"spring AND data AND jpa",
		"Several words must all be required"
	)

	eq(
		Central.search_query('jack"son'),
		'a:"jackson"',
		"A quote must not be able to break out of the term"
	)

	eq(Central.search_query(""), nil, "An empty text is not a query")
	eq(Central.search_query("- -"), nil, "Punctuation between spaces is not a query")
end
