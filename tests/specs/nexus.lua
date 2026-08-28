local Nexus = require("blink_deps.nexus")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- CUSTOM MAVEN REPOSITORIES
	--------------------------------------------------------------------------------

	--------------------------------------------------------------------------------
	-- NEXUS REPOSITORY
	--------------------------------------------------------------------------------

	do
	local nexus_repository = {
		name = "Company Nexus",
		type = "nexus",
		url = "https://nexus.company.test/",
		repository = "maven-releases",
	}

	eq(
		Nexus.is_repository(
			nexus_repository
		),
		true,
		"Nexus repository configuration must be recognized"
	)

	eq(
		Nexus.is_repository({
			type = "nexus",
			url = "https://nexus.company.test",
		}),
		false,
		"Nexus repository configuration must require a repository name"
	)

	eq(
		Nexus.debug_api_url(
			nexus_repository
		),
		"https://nexus.company.test/service/rest/v1/search",
		"Nexus API URL must use the instance root"
	)

	eq(
		Nexus.debug_content_url(
			nexus_repository
		),
		"https://nexus.company.test/repository/maven-releases",
		"Nexus Maven content URL must derive from the repository name"
	)

	eq(
		Nexus.content_url(
			nexus_repository
		),
		"https://nexus.company.test/repository/maven-releases",
		"Nexus Maven content URL must be available to repository backends"
	)

	local nexus_artifacts =
		Nexus.debug_extract_artifacts(
			{
				items = {
					{
						repository = "maven-releases",
						format = "maven2",
						group = "com.company.payment",
						name = "payment-client",
						version = "1.0.0",
					},
					{
						repository = "maven-releases",
						format = "maven2",
						group = "com.company.payment",
						name = "payment-client",
						version = "2.10.0",
					},
					{
						repository = "maven-releases",
						format = "maven2",
						group = "com.company.payment",
						name = "payment-client",
						version = "2.9.0",
					},
					{
						repository = "maven-releases",
						format = "maven2",
						group = "com.company.payment",
						name = "payment-api",
						version = "3.0.0",
					},
					{
						repository = "maven-releases",
						format = "maven2",
						group = "com.company.other",
						name = "unrelated",
						version = "9.0.0",
					},
				},
			},
			"com.company.payment"
		)

	eq(
		nexus_artifacts,
		{
			{
				artifact = "payment-api",
				latestVersion = "3.0.0",
			},
			{
				artifact = "payment-client",
				latestVersion = "2.10.0",
			},
		},
		"Nexus artifact extraction must filter, deduplicate, and rank versions"
	)

	eq(
		Nexus.debug_extract_artifacts(
			{},
			"com.company.payment"
		),
		{},
		"Nexus artifact extraction must tolerate missing items"
	)

	eq(
		Nexus.debug_extract_artifacts(
			{
				items = {
					{},
					{
						group = "com.company.payment",
						version = "1.0.0",
					},
				},
			},
			"com.company.payment"
		),
		{},
		"Nexus artifact extraction must ignore malformed components"
	)

	local nexus_source = {
		opts = {},
	}

	local nexus_request =
		Nexus.debug_request_command(
			nexus_source,
			nexus_repository,
			"com.company.payment",
			nil
		)

	eq(
		nexus_request,
		{
			"curl",
			"-sS",
			"--fail-with-body",
			"--connect-timeout",
			"3",
			"--max-time",
			"7",
			"-A",
			"blink-cmp-deps/"
				.. require("blink_deps.version"),
			"-G",
			"https://nexus.company.test/service/rest/v1/search",
			"--data-urlencode",
			"repository=maven-releases",
			"--data-urlencode",
			"group=com.company.payment",
		},
		"Nexus artifact search must build the expected Search API request"
	)

	local nexus_paginated_request =
		Nexus.debug_request_command(
			nexus_source,
			nexus_repository,
			"com.company.payment",
			"page-token-123"
		)

	eq(
		nexus_paginated_request[
			#nexus_paginated_request - 1
		],
		"--data-urlencode",
		"Nexus continuation token must use URL encoding"
	)

	eq(
		nexus_paginated_request[
			#nexus_paginated_request
		],
		"continuationToken=page-token-123",
		"Nexus continuation token must be added to paginated requests"
	)

	eq(
		Nexus.debug_cache_key(
			nexus_repository,
			"com.company.payment"
		),
		table.concat({
			"https://nexus.company.test",
			"maven-releases",
			"com.company.payment",
		}, "\n"),
		"Nexus artifact cache identity must include instance, repository, and group"
	)

	eq(
		Nexus.debug_cache_key(
			{
				type = "nexus",
				url = "https://nexus.company.test/",
				repository = "maven-releases",
			},
			"com.company.payment"
		),
		Nexus.debug_cache_key(
			{
				type = "nexus",
				url = "https://nexus.company.test",
				repository = "maven-releases",
			},
			"com.company.payment"
		),
		"Nexus artifact cache identity must normalize trailing slashes"
	)

	--------------------------------------------------------------------------------
	-- NEXUS ASYNC ARTIFACT SEARCH
	--------------------------------------------------------------------------------

	do
	local original_vim_system = vim.system
	local original_vim_schedule = vim.schedule

	local nexus_system_calls = {}
	local nexus_system_callbacks = {}

	rawset(vim, "schedule", function(fn)
		fn()
	end)

	rawset(vim, "system", function(cmd, opts, callback)
		table.insert(nexus_system_calls, {
			cmd = vim.deepcopy(cmd),
			opts = opts,
		})

		table.insert(
			nexus_system_callbacks,
			callback
		)

		return {}
	end)

	local async_nexus_source = {
		opts = {},
	}

	local first_nexus_result
	local first_nexus_error

	local second_nexus_result
	local second_nexus_error

	Nexus.artifacts(
		async_nexus_source,
		nexus_repository,
		"com.company.payment",
		function(result, err)
			first_nexus_result = result
			first_nexus_error = err
		end
	)

	Nexus.artifacts(
		async_nexus_source,
		nexus_repository,
		"com.company.payment",
		function(result, err)
			second_nexus_result = result
			second_nexus_error = err
		end
	)

	eq(
		#nexus_system_calls,
		1,
		"Concurrent Nexus artifact searches must share one in-flight request"
	)

	nexus_system_callbacks[1]({
		code = 0,
		stdout = vim.json.encode({
			items = {
				{
					group = "com.company.payment",
					name = "payment-client",
					version = "1.0.0",
				},
				{
					group = "com.company.payment",
					name = "payment-api",
					version = "3.0.0",
				},
			},
			continuationToken = "page-2",
		}),
		stderr = "",
	})

	eq(
		#nexus_system_calls,
		2,
		"Nexus artifact search must follow continuation tokens"
	)

	nexus_system_callbacks[2]({
		code = 0,
		stdout = vim.json.encode({
			items = {
				{
					group = "com.company.payment",
					name = "payment-client",
					version = "2.10.0",
				},
				{
					group = "com.company.other",
					name = "unrelated",
					version = "9.0.0",
				},
			},
			continuationToken = vim.NIL,
		}),
		stderr = "",
	})

	eq(
		#nexus_system_calls,
		2,
		"JSON null Nexus continuation token must stop pagination"
	)

	local expected_async_nexus_artifacts = {
		{
			artifact = "payment-api",
			latestVersion = "3.0.0",
		},
		{
			artifact = "payment-client",
			latestVersion = "2.10.0",
		},
	}

	eq(
		first_nexus_result,
		expected_async_nexus_artifacts,
		"Nexus artifact search must aggregate and deduplicate paginated results"
	)

	eq(
		second_nexus_result,
		expected_async_nexus_artifacts,
		"All Nexus in-flight waiters must receive the completed result"
	)

	ok(
		first_nexus_error == nil
			and second_nexus_error == nil,
		"Successful Nexus artifact searches must not return errors"
	)

	local cached_nexus_result
	local cached_nexus_error

	local calls_before_cache =
		#nexus_system_calls

	Nexus.artifacts(
		async_nexus_source,
		nexus_repository,
		"com.company.payment",
		function(result, err)
			cached_nexus_result = result
			cached_nexus_error = err
		end
	)

	eq(
		#nexus_system_calls,
		calls_before_cache,
		"Nexus artifact cache hits must not start another HTTP request"
	)

	eq(
		cached_nexus_result,
		expected_async_nexus_artifacts,
		"Nexus artifact cache hits must return the completed artifact list"
	)

	eq(
		cached_nexus_error,
		nil,
		"Nexus artifact cache hits must not return an error"
	)

	rawset(
		vim,
		"system",
		original_vim_system
	)

	rawset(
		vim,
		"schedule",
		original_vim_schedule
	)

	end

	--------------------------------------------------------------------------------
	-- NEXUS ASYNC ARTIFACT SEARCH FAILURE
	--------------------------------------------------------------------------------

	do
		local error_original_vim_system =
			vim.system

		local error_original_vim_schedule =
			vim.schedule

		local error_system_calls = {}
		local error_system_callbacks = {}

		rawset(vim, "schedule", function(fn)
			fn()
		end)

		rawset(vim, "system", function(cmd, opts, callback)
			table.insert(error_system_calls, {
				cmd = vim.deepcopy(cmd),
				opts = opts,
			})

			table.insert(
				error_system_callbacks,
				callback
			)

			return {}
		end)

		local error_nexus_source = {
			opts = {},
		}

		local first_error_result
		local first_error_message

		local second_error_result
		local second_error_message

		Nexus.artifacts(
			error_nexus_source,
			nexus_repository,
			"com.company.failure",
			function(result, err)
				first_error_result = result
				first_error_message = err
			end
		)

		Nexus.artifacts(
			error_nexus_source,
			nexus_repository,
			"com.company.failure",
			function(result, err)
				second_error_result = result
				second_error_message = err
			end
		)

		eq(
			#error_system_calls,
			1,
			"Concurrent failing Nexus searches must share one in-flight request"
		)

		error_system_callbacks[1]({
			code = 22,
			stdout = "",
			stderr = "Nexus unavailable",
		})

		ok(
			first_error_result == nil
				and second_error_result == nil,
			"Failed Nexus searches must not return artifact results"
		)

		eq(
			first_error_message,
			"Nexus unavailable",
			"First Nexus waiter must receive the HTTP error"
		)

		eq(
			second_error_message,
			"Nexus unavailable",
			"All Nexus waiters must receive the HTTP error"
		)

		ok(
			next(
				error_nexus_source.nexus_artifact_inflight
					or {}
			) == nil,
			"Failed Nexus searches must clear in-flight state"
		)

		local retry_result
		local retry_error

		Nexus.artifacts(
			error_nexus_source,
			nexus_repository,
			"com.company.failure",
			function(result, err)
				retry_result = result
				retry_error = err
			end
		)

		eq(
			#error_system_calls,
			2,
			"A Nexus search must be retryable after a failed request"
		)

		error_system_callbacks[2]({
			code = 0,
			stdout = vim.json.encode({
				items = {
					{
						group = "com.company.failure",
						name = "recovered-client",
						version = "1.0.0",
					},
				},
				continuationToken = nil,
			}),
			stderr = "",
		})

		eq(
			retry_result,
			{
				{
					artifact = "recovered-client",
					latestVersion = "1.0.0",
				},
			},
			"A Nexus retry must recover successfully after a previous failure"
		)

		eq(
			retry_error,
			nil,
			"A successful Nexus retry must not retain the previous error"
		)

		rawset(
			vim,
			"system",
			error_original_vim_system
		)

		rawset(
			vim,
			"schedule",
			error_original_vim_schedule
		)
	end

	end

	--------------------------------------------------------------------------------
end
