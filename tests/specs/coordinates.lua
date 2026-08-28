local Central = require("blink_deps.central")
local Repository = require("blink_deps.repository")
local Coordinates = require("blink_deps.coordinates")

return function(test)
	local eq = test.eq
	local ok = test.ok

	local function replace_central_search(fn)
		rawset(Central, "search", fn)
	end

	local function replace_repository_versions(fn)
		rawset(Repository, "versions", fn)
	end

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
end
