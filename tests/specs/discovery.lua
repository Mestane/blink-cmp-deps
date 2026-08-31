local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
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

	replace_central_search(
		discovery_original_central_search
	)
end
