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
end
