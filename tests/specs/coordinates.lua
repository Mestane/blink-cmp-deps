local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Repository = require("blink_deps.repository")
local Nexus = require("blink_deps.nexus")
local Coordinates = require("blink_deps.coordinates")

return function(test)
	local eq = test.eq
	local ok = test.ok

	-- Group completion debounces its Central work. These specs drive the
	-- callbacks synchronously, so the timer has to run inline.
	rawset(Util, "defer", function(_, fn)
		fn()
	end)

	local function replace_central_search(fn)
		rawset(Central, "search", fn)
	end

	local function replace_repository_versions(fn)
		rawset(Repository, "versions", fn)
	end

	local function replace_nexus_artifacts(fn)
		rawset(Nexus, "artifacts", fn)
	end

	local function replace_nexus_groups(fn)
		rawset(Nexus, "groups", fn)
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
	-- GROUP QUERY PLANNING
	--------------------------------------------------------------------------------

	local plain_group_plan =
		Coordinates.debug_group_plan(
			"springframework"
		)

	local qualified_root_plan_probe =
		Coordinates.debug_group_plan(
			"org.springframework."
		)

	eq(
		plain_group_plan.central,
		{
			"springframework",
		},
		"Plain group search must use the full typed value"
	)

	local multi_token_group_plan =
		Coordinates.debug_group_plan(
			"spring data jpa"
		)

	eq(
		multi_token_group_plan.central,
		{
			"spring AND data AND jpa",
		},
		"Plain group search must join tokens so Solr does not scan every OR match"
	)

	for _, planned in ipairs({
		plain_group_plan,
		multi_token_group_plan,
		qualified_root_plan_probe,
	}) do
		for _, query in ipairs(planned.central) do
			ok(
				not query:find("g:*", 1, true),
				"Group search must never plan a leading wildcard: " .. query
			)
		end
	end

	local qualified_root_plan =
		Coordinates.debug_group_plan(
			"org.springframework."
		)

	eq(
		qualified_root_plan.central,
		{
			"g:org.springframework.*",
		},
		"Qualified group search must support a trailing dot"
	)

	local qualified_partial_plan =
		Coordinates.debug_group_plan(
			"org.springframework.boot"
		)

	eq(
		qualified_partial_plan.central,
		{
			"g:org.springframework.boot*",
		},
		"Qualified group search must preserve the full typed prefix"
	)

	local qualified_short_tail_plan =
		Coordinates.debug_group_plan(
			"org.springframework.a"
		)

	eq(
		qualified_short_tail_plan.central,
		{
			"g:org.springframework.a*",
		},
		"Qualified group search must support a one-character tail"
	)

    --------------------------------------------------------------------------------
	-- GROUP DISCOVERY RANKING
	--------------------------------------------------------------------------------

   local ranked_original_central_search =
   Central.search

	local ranked_group_source =
		Coordinates.new_state()

	ranked_group_source.opts = {}

	local ranked_group_calls = {}

	replace_central_search(function(
		_,
		key,
		args,
		callback
	)
		table.insert(
			ranked_group_calls,
			{
				key = key,
				q = args.q,
				callback = callback,
			}
		)
	end)

	local ranked_group_responses = {}

	Coordinates.complete_group(
		ranked_group_source,
		test_context(),
		{
			value = "spring",
		},
		function(result)
			table.insert(
				ranked_group_responses,
				result
			)
		end
	)

	local basic_group_call

	for _, call in ipairs(
		ranked_group_calls
	) do
		if call.q == "spring" then
			basic_group_call = call
		end
	end

	eq(
		{
			plans = #ranked_group_calls,
			basic =
				basic_group_call
					~= nil,
		},
		{
			plans = 1,
			basic = true,
		},
		"Plain group completion must run exactly one Central discovery query"
	)

	basic_group_call.callback(
		{
			{
				g = "org.example",
				a = "some-spring-helper",
			},
			{
				g = "org.springframework.boot",
				a = "spring-boot",
			},
			{
				g = "org.springframework.boot",
				a = "spring-boot-starter",
			},
			{
				g = "org.springframework.boot",
				a = "spring-boot-starter-data-jpa",
			},
			{
				g = "org.springframework",
				a = "spring-core",
			},
			{
				g = "org.springframework",
				a = "spring-context",
			},
		},
		nil
	)

	local ranked_group_items =
		ranked_group_responses[
			#ranked_group_responses
		].items or {}

	eq(
		ranked_group_items[1]
			and ranked_group_items[1].label,
		"org.springframework.boot",
		"Group discovery must rank stronger dependency matches ahead of incidental matches"
	)


    replace_central_search(
	ranked_original_central_search
	)

    --------------------------------------------------------------------------------
	-- QUALIFIED GROUP RANKING
	--------------------------------------------------------------------------------

	local qualified_ranking_original_central_search =
		Central.search

	local qualified_ranking_callback

	replace_central_search(function(
		_,
		_,
		_,
		callback
	)
		qualified_ranking_callback =
			callback
	end)

	local qualified_ranking_source =
		Coordinates.new_state()

	qualified_ranking_source.opts = {}

	local qualified_ranking_responses = {}

	Coordinates.complete_group(
		qualified_ranking_source,
		test_context(),
		{
			value = "org.springframework.",
		},
		function(result)
			table.insert(
				qualified_ranking_responses,
				result
			)
		end
	)

	local qualified_ranking_docs = {
		{
			g = "org.springframework.boot",
			a = "spring-boot",
		},
	}

	for index = 1, 10 do
		table.insert(
			qualified_ranking_docs,
			{
				g =
					"org.springframework.cloud.stream.app",
				a =
					string.format(
						"cloud-stream-app-%02d",
						index
					),
			}
		)
	end

	qualified_ranking_callback(
		qualified_ranking_docs,
		nil
	)

	local qualified_ranking_items =
		qualified_ranking_responses[
			#qualified_ranking_responses
		].items or {}

	eq(
		qualified_ranking_items[1]
			and qualified_ranking_items[1].label,
		"org.springframework.boot",
		"Qualified group completion must prefer direct namespace children over deeper groups"
	)

	local qualified_ranking_offsets = {}

	for _, item in ipairs(
		qualified_ranking_items
	) do
		qualified_ranking_offsets[
			item.label
		] =
			item.score_offset
	end

	ok(
		qualified_ranking_offsets[
			"org.springframework.boot"
		]
			> qualified_ranking_offsets[
				"org.springframework.cloud.stream.app"
			],
		"Qualified group completion must expose namespace depth through score_offset"
	)

	replace_central_search(
		qualified_ranking_original_central_search
	)

    --------------------------------------------------------------------------------
	-- QUALIFIED GROUP PAGINATION
	--------------------------------------------------------------------------------

	local pagination_original_central_search =
		Central.search

	local pagination_calls = {}

	replace_central_search(function(
		_,
		key,
		args,
		callback
	)
		table.insert(
			pagination_calls,
			{
				key = key,
				q = args.q,
				rows = args.rows,
				start = args.start,
				callback = callback,
			}
		)
	end)

	local pagination_source =
		Coordinates.new_state()

	pagination_source.opts = {}

	local pagination_responses = {}

	Coordinates.complete_group(
		pagination_source,
		test_context(),
		{
			value = "org.springframework.",
		},
		function(result)
			table.insert(
				pagination_responses,
				result
			)
		end
	)

	eq(
		#pagination_calls,
		1,
		"Qualified group completion must start with the first Central page"
	)

	eq(
		{
			q =
				pagination_calls[1].q,
			start =
				pagination_calls[1].start,
		},
		{
			q =
				"g:org.springframework.*",
			start = nil,
		},
		"Qualified group completion must start from the first Central page"
	)

	local first_page = {}

	for index = 1, 200 do
		table.insert(
			first_page,
			{
				g =
					string.format(
						"org.springframework.page1.%03d",
						index
					),
				a =
					string.format(
						"page1-artifact-%03d",
						index
					),
			}
		)
	end

	pagination_calls[1].callback(
		first_page,
		nil
	)

	eq(
		#pagination_calls,
		2,
		"A full qualified Central page must request the next page"
	)

   local first_page_was_emitted =
		false

	for _, result in ipairs(
		pagination_responses
	) do
		for _, item in ipairs(
			(result and result.items)
			or {}
		) do
			if item.label
				== "org.springframework.page1.001"
			then
				first_page_was_emitted =
					true
				break
			end
		end

		if first_page_was_emitted then
			break
		end
	end

	eq(
		first_page_was_emitted,
		true,
		"Qualified group pagination must stream the first page before later pages finish"
	)

	eq(
		{
			q =
				pagination_calls[2].q,
			start =
				pagination_calls[2].start,
		},
		{
			q =
				"g:org.springframework.*",
			start = "200",
		},
		"Qualified Central pagination must preserve the query and advance the start offset"
	)

	pagination_calls[2].callback(
		{
			{
				g =
					"org.springframework.boot",
				a =
					"spring-boot",
			},
		},
		nil
	)

	local pagination_found_boot = false

	for _, result in ipairs(
		pagination_responses
	) do
		for _, item in ipairs(
			(result and result.items)
			or {}
		) do
			if item.label
				== "org.springframework.boot"
			then
				pagination_found_boot = true
				break
			end
		end

		if pagination_found_boot then
			break
		end
	end

	eq(
		pagination_found_boot,
		true,
		"Qualified group completion must include groups discovered on later Central pages"
	)

	replace_central_search(
		pagination_original_central_search
	)

    --------------------------------------------------------------------------------
	-- QUALIFIED GROUP PAGINATION LIMIT
	--------------------------------------------------------------------------------

	local pagination_limit_original_central_search =
		Central.search

	local pagination_limit_calls = {}

	replace_central_search(function(
		_,
		key,
		args,
		callback
	)
		table.insert(
			pagination_limit_calls,
			{
				key = key,
				q = args.q,
				rows = args.rows,
				start = args.start,
				callback = callback,
			}
		)
	end)

	local pagination_limit_source =
		Coordinates.new_state()

	pagination_limit_source.opts = {}

	local pagination_limit_responses = {}

	Coordinates.complete_group(
		pagination_limit_source,
		test_context(),
		{
			value = "org.springframework.",
		},
		function(result)
			table.insert(
				pagination_limit_responses,
				result
			)
		end
	)

	local page_size =
		tonumber(
			pagination_limit_calls[1]
				and pagination_limit_calls[1].rows
		)

	local function full_group_page(prefix)
		local docs = {}

		for index = 1, page_size do
			table.insert(
				docs,
				{
					g =
						string.format(
							"org.springframework.%s.%03d",
							prefix,
							index
						),
					a =
						string.format(
							"%s-artifact-%03d",
							prefix,
							index
						),
				}
			)
		end

		return docs
	end

	pagination_limit_calls[1].callback(
		full_group_page("limit1"),
		nil
	)

	pagination_limit_calls[2].callback(
		full_group_page("limit2"),
		nil
	)

	eq(
		{
			count =
				#pagination_limit_calls,
			second_start =
				pagination_limit_calls[2]
					.start,
			third_start =
				pagination_limit_calls[3]
					.start,
		},
		{
			count = 3,
			second_start = "200",
			third_start = "400",
		},
		"Qualified Central pagination must advance through at most three pages"
	)

	local third_page =
		full_group_page("limit3")

	third_page[1] = {
		g = "org.springframework.boot",
		a = "spring-boot",
	}

	pagination_limit_calls[3].callback(
		third_page,
		nil
	)

	eq(
		#pagination_limit_calls,
		3,
		"Qualified Central pagination must stop after the configured page limit"
	)

	local pagination_limit_found_boot =
		false

	for _, result in ipairs(
		pagination_limit_responses
	) do
		for _, item in ipairs(
			(result and result.items)
			or {}
		) do
			if item.label
				== "org.springframework.boot"
			then
				pagination_limit_found_boot =
					true
				break
			end
		end

		if pagination_limit_found_boot then
			break
		end
	end

	eq(
		pagination_limit_found_boot,
		true,
		"Qualified Central pagination must emit results collected from the final allowed page"
	)

	replace_central_search(
		pagination_limit_original_central_search
	)

	--------------------------------------------------------------------------------
	-- NEXUS GROUP INTEGRATION
	--------------------------------------------------------------------------------

	local original_group_central_search =
		Central.search

	local original_nexus_groups =
		Nexus.groups

	local nexus_group_central_callbacks = {}
	local nexus_group_calls = {}

	replace_central_search(function(
		_,
		_,
		_,
		callback
	)
		table.insert(
			nexus_group_central_callbacks,
			callback
		)
	end)

	replace_nexus_groups(function(
		_,
		repository,
		prefix,
		callback
	)
		table.insert(
			nexus_group_calls,
			{
				repository =
					repository.repository,
				prefix = prefix,
				callback = callback,
			}
		)
	end)

	local nexus_group_source =
		Coordinates.new_state()

	nexus_group_source.opts = {
		repositories = {
			{
				name = "Generic Releases",
				url =
					"https://repo.company.test/releases",
			},
			{
				name = "Company Nexus",
				type = "nexus",
				url =
					"https://nexus.company.test",
				repository =
					"maven-releases",
			},
		},
	}

	eq(
		next(nexus_group_source.group_memory),
		nil,
		"New coordinate state must not start with built-in group hints"
	)

	local nexus_group_responses = {}

	Coordinates.complete_group(
		nexus_group_source,
		test_context(),
		{
			value = "com.comp",
		},
		function(result)
			table.insert(
				nexus_group_responses,
				result
			)
		end
	)

	eq(
		sorted_response_labels(
			nexus_group_responses[
				#nexus_group_responses
			]
		),
		{},
		"Initial group completion must not emit built-in group hints"
	)

	eq(
		#nexus_group_calls,
		1,
		"Group completion must query only configured Nexus repositories"
	)

	eq(
		{
			repository =
				nexus_group_calls[1]
					.repository,
			prefix =
				nexus_group_calls[1]
					.prefix,
		},
		{
			repository =
				"maven-releases",
			prefix = "com.comp",
		},
		"Nexus group completion must receive the configured repository and typed prefix"
	)

	nexus_group_calls[1].callback(
		{
			"com.company.order",
			"com.company.payment",
		},
		nil
	)

	eq(
		{
			order =
				nexus_group_source.group_memory[
					"com.company.order"
				],
			payment =
				nexus_group_source.group_memory[
					"com.company.payment"
				],
		},
		{
			order = true,
			payment = true,
		},
		"Discovered Nexus groups must still be remembered for the current session"
	)

	eq(
		sorted_response_labels(
			nexus_group_responses[
				#nexus_group_responses
			]
		),
		{
			"com.company.order",
			"com.company.payment",
		},
		"Nexus groups must be emitted into dependency completion"
	)

	local nexus_group_sources = {}

	for _, item in ipairs(
		nexus_group_responses[
			#nexus_group_responses
		].items or {}
	) do
		nexus_group_sources[
			item.label
		] =
			item.labelDetails
			and item.labelDetails.description
	end

	eq(
		nexus_group_sources,
		{
			["com.company.order"] =
				"Company Nexus",
			["com.company.payment"] =
				"Company Nexus",
		},
		"Nexus group completion must expose the repository display name"
	)

	for _, central_callback in ipairs(
		nexus_group_central_callbacks
	) do
		central_callback(
			{
				{
					g =
						"com.company.payment",
				},
				{
					g =
						"com.company.user",
				},
			},
			nil
		)
	end

	local emitted_group_counts = {}

	for _, result in ipairs(
		nexus_group_responses
	) do
		for _, item in ipairs(
			(result and result.items)
			or {}
		) do
			emitted_group_counts[
				item.label
			] =
				(emitted_group_counts[
					item.label
				] or 0)
				+ 1
		end
	end

	eq(
		{
			payment =
				emitted_group_counts[
					"com.company.payment"
				],
			user =
				emitted_group_counts[
					"com.company.user"
				],
		},
		{
			payment = 1,
			user = 1,
		},
		"Nexus and Maven Central group results must be deduplicated"
	)

	replace_central_search(
		original_group_central_search
	)

	replace_nexus_groups(
		original_nexus_groups
	)

    --------------------------------------------------------------------------------
	-- CANCELLED GROUP COMPLETION
	--------------------------------------------------------------------------------

	local cancelled_original_central_search =
		Central.search

	local cancelled_central_callback

	replace_central_search(function(
		_,
		_,
		_,
		callback
	)
		cancelled_central_callback =
			callback
	end)

	local cancelled_group_source =
		Coordinates.new_state()

	cancelled_group_source.opts = {}

	local cancelled_group_responses = {}

	local cancel_group_completion =
		Coordinates.complete_group(
			cancelled_group_source,
			test_context(),
			{
				value =
					"org.springframework.ai",
			},
			function(result)
				table.insert(
					cancelled_group_responses,
					result
				)
			end
		)

	local responses_before_cancelled_result =
		#cancelled_group_responses

	cancel_group_completion()

	cancelled_central_callback(
		{
			{
				g =
					"org.springframework.ai",
			},
		},
		nil
	)

	eq(
		cancelled_group_source.group_memory[
			"org.springframework.ai"
		],
		true,
		"Cancelled group completion must still remember successful backend results"
	)

	eq(
		#cancelled_group_responses,
		responses_before_cancelled_result,
		"Cancelled group completion must not emit stale backend results"
	)

	replace_central_search(
		cancelled_original_central_search
	)

	--------------------------------------------------------------------------------
	-- NEXUS ARTIFACT INTEGRATION
	--------------------------------------------------------------------------------

	local original_artifact_central_search =
		Central.search

	local original_nexus_artifacts =
		Nexus.artifacts

	local nexus_artifact_central_callback
	local nexus_artifact_calls = {}

	replace_central_search(function(
		_,
		_,
		_,
		callback
	)
		nexus_artifact_central_callback =
			callback
	end)

	replace_nexus_artifacts(function(
		_,
		repository,
		group_id,
		callback
	)
		table.insert(
			nexus_artifact_calls,
			{
				repository =
					repository.repository,
				group_id = group_id,
				callback = callback,
			}
		)
	end)

	local nexus_artifact_source =
		Coordinates.new_state()

	nexus_artifact_source.opts = {
		repositories = {
			{
				name = "Generic Releases",
				url =
					"https://repo.company.test/releases",
			},
			{
				name = "Company Nexus",
				type = "nexus",
				url =
					"https://nexus.company.test",
				repository =
					"maven-releases",
			},
		},
	}

	local nexus_artifact_responses = {}

	Coordinates.complete_artifact(
		nexus_artifact_source,
		test_context(),
		{
			value = "",
		},
		"com.company.payment",
		function(result)
			table.insert(
				nexus_artifact_responses,
				result
			)
		end
	)

	eq(
		#nexus_artifact_calls,
		1,
		"Artifact completion must query only configured Nexus repositories"
	)

	eq(
		{
			repository =
				nexus_artifact_calls[1]
					.repository,
			group_id =
				nexus_artifact_calls[1]
					.group_id,
		},
		{
			repository =
				"maven-releases",
			group_id =
				"com.company.payment",
		},
		"Nexus artifact completion must receive the configured repository and exact group"
	)

	nexus_artifact_calls[1].callback(
		{
			{
				artifact =
					"private-client",
				latestVersion =
					"2.0.0",
			},
			{
				artifact =
					"shared-client",
				latestVersion =
					"3.0.0",
			},
		},
		nil
	)

	eq(
		sorted_response_labels(
			nexus_artifact_responses[
				#nexus_artifact_responses
			]
		),
		{
			"private-client",
			"shared-client",
		},
		"Nexus artifacts must be emitted into dependency completion"
	)

	local nexus_source_labels = {}

	for _, item in ipairs(
		nexus_artifact_responses[
			#nexus_artifact_responses
		].items or {}
	) do
		nexus_source_labels[
			item.label
		] =
			item.labelDetails
			and item.labelDetails.description
	end

	eq(
		nexus_source_labels,
		{
			["private-client"] =
				"Company Nexus",
			["shared-client"] =
				"Company Nexus",
		},
		"Nexus artifact completion must expose the repository display name"
	)

	nexus_artifact_central_callback(
		{
			{
				g =
					"com.company.payment",
				a =
					"shared-client",
				latestVersion =
					"3.0.0",
			},
			{
				g =
					"com.company.payment",
				a =
					"central-only",
				latestVersion =
					"1.0.0",
			},
		},
		nil
	)

	eq(
		sorted_response_labels(
			nexus_artifact_responses[
				#nexus_artifact_responses
			]
		),
		{
			"central-only",
		},
		"Nexus and Maven Central artifact results must be deduplicated"
	)

	replace_central_search(
		original_artifact_central_search
	)

	replace_nexus_artifacts(
		original_nexus_artifacts
	)

	--------------------------------------------------------------------------------
	-- NEXUS ARTIFACT FAILURE
	--------------------------------------------------------------------------------

	local failure_original_central_search =
		Central.search

	local failure_original_nexus_artifacts =
		Nexus.artifacts

	local failure_central_callback
	local failure_nexus_callback

	replace_central_search(function(
		_,
		_,
		_,
		callback
	)
		failure_central_callback =
			callback
	end)

	replace_nexus_artifacts(function(
		_,
		_,
		_,
		callback
	)
		failure_nexus_callback =
			callback
	end)

	local nexus_failure_source =
		Coordinates.new_state()

	nexus_failure_source.opts = {
		repositories = {
			{
				name = "Company Nexus",
				type = "nexus",
				url =
					"https://nexus.company.test",
				repository =
					"maven-releases",
			},
		},
	}

	local nexus_failure_responses = {}

	Coordinates.complete_artifact(
		nexus_failure_source,
		test_context(),
		{
			value = "",
		},
		"com.company.payment",
		function(result)
			table.insert(
				nexus_failure_responses,
				result
			)
		end
	)

	local responses_before_failure =
		#nexus_failure_responses

	-- The notification itself is not the subject of this test.
	-- Mark the error as already reported so the test only checks
	-- backend isolation.
	nexus_failure_source.notified[
		table.concat({
			"nexus-artifact",
			"https://nexus.company.test",
			"maven-releases",
			"com.company.payment",
		}, ":")
	] = true

	failure_nexus_callback(
		nil,
		"Nexus unavailable"
	)

	eq(
		#nexus_failure_responses,
		responses_before_failure,
		"A Nexus artifact failure must not emit invalid completion results"
	)

	failure_central_callback(
		{
			{
				g =
					"com.company.payment",
				a =
					"central-client",
				latestVersion =
					"1.0.0",
			},
		},
		nil
	)

	eq(
		sorted_response_labels(
			nexus_failure_responses[
				#nexus_failure_responses
			]
		),
		{
			"central-client",
		},
		"A Nexus artifact failure must not discard Maven Central results"
	)

	replace_central_search(
		failure_original_central_search
	)

	replace_nexus_artifacts(
		failure_original_nexus_artifacts
	)

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
	-- MAVEN CENTRAL DISABLED
	--------------------------------------------------------------------------------

	local disabled_original_nexus_groups =
		Nexus.groups

	local disabled_original_nexus_artifacts =
		Nexus.artifacts

	local disabled_original_repository_versions =
		Repository.versions

	local disabled_group_calls = 0
	local disabled_artifact_calls = 0
	local disabled_repository_calls = 0

	replace_nexus_groups(function(
		_,
		repository,
		prefix,
		callback
	)
		disabled_group_calls =
			disabled_group_calls + 1

		eq(
			{
				repository =
					repository.repository,
				prefix = prefix,
			},
			{
				repository =
					"maven-releases",
				prefix = "com.comp",
			},
			"Central-disabled group completion must keep the configured Nexus backend"
		)

		callback(
			{
				"com.company.payment",
			},
			nil
		)
	end)

	replace_nexus_artifacts(function(
		_,
		repository,
		group_id,
		callback
	)
		disabled_artifact_calls =
			disabled_artifact_calls + 1

		eq(
			{
				repository =
					repository.repository,
				group_id = group_id,
			},
			{
				repository =
					"maven-releases",
				group_id =
					"com.company.payment",
			},
			"Central-disabled artifact completion must keep the configured Nexus backend"
		)

		callback(
			{
				{
					artifact =
						"payment-client",
					latestVersion =
						"5.0.0-internal",
				},
			},
			nil
		)
	end)

	replace_repository_versions(function(
		_,
		repository,
		group_id,
		artifact_id,
		callback
	)
		disabled_repository_calls =
			disabled_repository_calls + 1

		eq(
			{
				repository =
					repository.repository,
				group_id = group_id,
				artifact_id = artifact_id,
			},
			{
				repository =
					"maven-releases",
				group_id =
					"com.company.payment",
				artifact_id =
					"payment-client",
			},
			"Central-disabled version completion must keep the configured repository backend"
		)

		callback(
			{
				"5.0.0-internal",
			},
			nil
		)
	end)

	local central_disabled_source =
		Coordinates.new_state()

	central_disabled_source.opts = {
		central = {
			enabled = false,
		},
		repositories = {
			{
				name = "Company Nexus",
				type = "nexus",
				url =
					"https://nexus.company.test",
				repository =
					"maven-releases",
			},
		},
	}

	local disabled_group_response

	Coordinates.complete_group(
		central_disabled_source,
		test_context(),
		{
			value = "com.comp",
		},
		function(result)
			disabled_group_response = result
		end
	)

	eq(
		disabled_group_calls,
		1,
		"Central-disabled completion must still query Nexus groups"
	)

	eq(
		sorted_response_labels(
			disabled_group_response
		),
		{
			"com.company.payment",
		},
		"Central-disabled group completion must use Nexus results"
	)

	local disabled_artifact_response

	Coordinates.complete_artifact(
		central_disabled_source,
		test_context(),
		{
			value = "",
		},
		"com.company.payment",
		function(result)
			disabled_artifact_response =
				result
		end
	)

	eq(
		disabled_artifact_calls,
		1,
		"Central-disabled completion must still query Nexus artifacts"
	)

	eq(
		sorted_response_labels(
			disabled_artifact_response
		),
		{
			"payment-client",
		},
		"Central-disabled artifact completion must use Nexus results"
	)

	local disabled_version_response

	Coordinates.complete_version(
		central_disabled_source,
		test_context(),
		{
			value = "",
		},
		"com.company.payment",
		"payment-client",
		function(result)
			disabled_version_response =
				result
		end
	)

	eq(
		disabled_repository_calls,
		1,
		"Central-disabled completion must still query repository versions"
	)

	eq(
		sorted_response_labels(
			disabled_version_response
		),
		{
			"5.0.0-internal",
		},
		"Central-disabled version completion must use only repository results"
	)

	replace_nexus_groups(
		disabled_original_nexus_groups
	)

	replace_nexus_artifacts(
		disabled_original_nexus_artifacts
	)

	replace_repository_versions(
		disabled_original_repository_versions
	)


	--------------------------------------------------------------------------------
end
