local Repository = require("blink_deps.repository")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- METADATA URL
	--------------------------------------------------------------------------------

	eq(
		Repository.debug_metadata_url(
			{
				url = "https://repo.company.com/maven/releases",
			},
			"com.company.payment",
			"payment-client"
		),
		"https://repo.company.com/maven/releases/com/company/payment/payment-client/maven-metadata.xml",
		"Custom repository metadata URL must follow the Maven repository layout"
	)

	eq(
		Repository.debug_metadata_url(
			{
				url = "https://repo.company.com/maven/releases/",
			},
			"com.company.payment",
			"payment-client"
		),
		"https://repo.company.com/maven/releases/com/company/payment/payment-client/maven-metadata.xml",
		"Custom repository metadata URL must ignore trailing repository slashes"
	)

	--------------------------------------------------------------------------------
	-- NEXUS METADATA URL
	--------------------------------------------------------------------------------

	eq(
		Repository.debug_metadata_url(
			{
				type = "nexus",
				url = "https://nexus.company.test/",
				repository = "maven-releases",
			},
			"com.company.payment",
			"payment-client"
		),
		"https://nexus.company.test/repository/maven-releases/com/company/payment/payment-client/maven-metadata.xml",
		"Nexus repository metadata URL must use the derived Maven content root"
	)

	eq(
		Repository.debug_metadata_url(
			{
				type = "nexus",
				url = "https://nexus.company.test",
			},
			"com.company.payment",
			"payment-client"
		),
		nil,
		"Invalid Nexus repositories must not fall back to the instance root"
	)

	--------------------------------------------------------------------------------
	-- METADATA VERSION PARSING
	--------------------------------------------------------------------------------

	eq(
		Repository.debug_extract_versions([[
	<metadata>
		<groupId>com.company.payment</groupId>
		<artifactId>payment-client</artifactId>

		<versioning>
			<versions>
				<version>1.0.0</version>
				<version>1.1.0</version>
				<version>1.1.0</version>
				<version>2.0.0</version>
			</versions>
		</versioning>
	</metadata>
		]]),
		{
			"1.0.0",
			"1.1.0",
			"2.0.0",
		},
		"Custom repository metadata must extract and deduplicate versions"
	)

	eq(
		Repository.debug_extract_versions([[
	<metadata>
		<versioning>
			<versions>
				<version>
					1.0.0&amp;build
				</version>
			</versions>
		</versioning>
	</metadata>
		]]),
		{
			"1.0.0&build",
		},
		"Custom repository metadata must trim values and decode XML entities"
	)

	eq(
		Repository.debug_extract_versions([[
	<metadata>
		<versioning>
			<versions>
			</versions>
		</versioning>
	</metadata>
		]]),
		{},
		"Custom repository metadata without versions must return an empty list"
	)

	--------------------------------------------------------------------------------
	-- REPOSITORY NAME
	--------------------------------------------------------------------------------

	eq(
		Repository.debug_name({
			name = "Company Releases",
			url = "https://repo.company.com/releases",
		}),
		"Company Releases",
		"Custom repository must prefer its configured display name"
	)

	eq(
		Repository.debug_name({
			url = "https://repo.company.com/releases",
		}),
		"https://repo.company.com/releases",
		"Custom repository must fall back to its URL as the display name"
	)

	--------------------------------------------------------------------------------
	-- CACHE IDENTITY
	--------------------------------------------------------------------------------

	local repository_cache_key =
		Repository.debug_cache_key(
			{
				url = "https://repo.company.com/maven/releases",
			},
			"com.company.payment",
			"payment-client"
		)

	local repository_cache_key_with_slash =
		Repository.debug_cache_key(
			{
				url = "https://repo.company.com/maven/releases/",
			},
			"com.company.payment",
			"payment-client"
		)

	eq(
		repository_cache_key,
		repository_cache_key_with_slash,
		"Custom repository cache key must normalize trailing repository slashes"
	)

	local different_repository_cache_key =
		Repository.debug_cache_key(
			{
				url = "https://repo.example.com/maven/releases",
			},
			"com.company.payment",
			"payment-client"
		)

	ok(
		repository_cache_key ~= different_repository_cache_key,
		"Custom repository cache key must include the repository URL"
	)

	local different_artifact_cache_key =
		Repository.debug_cache_key(
			{
				url = "https://repo.company.com/maven/releases",
			},
			"com.company.payment",
			"other-client"
		)

	ok(
		repository_cache_key ~= different_artifact_cache_key,
		"Custom repository cache key must include Maven coordinates"
	)

	local nexus_releases_cache_key =
		Repository.debug_cache_key(
			{
				type = "nexus",
				url = "https://nexus.company.test",
				repository = "maven-releases",
			},
			"com.company.payment",
			"payment-client"
		)

	local nexus_snapshots_cache_key =
		Repository.debug_cache_key(
			{
				type = "nexus",
				url = "https://nexus.company.test",
				repository = "maven-snapshots",
			},
			"com.company.payment",
			"payment-client"
		)

	ok(
		nexus_releases_cache_key
			~= nexus_snapshots_cache_key,
		"Nexus repository cache identity must include the Nexus repository name"
	)

	--------------------------------------------------------------------------------
	-- NEXUS VERSION REQUEST
	--------------------------------------------------------------------------------

	do
		local original_vim_system =
			vim.system

		local original_vim_schedule =
			vim.schedule

		local system_calls = {}
		local system_callbacks = {}

		rawset(vim, "schedule", function(fn)
			fn()
		end)

		rawset(vim, "system", function(
			cmd,
			opts,
			callback
		)
			table.insert(
				system_calls,
				{
					cmd =
						vim.deepcopy(cmd),
					opts = opts,
				}
			)

			table.insert(
				system_callbacks,
				callback
			)

			return {}
		end)

		local source = {
			opts = {
				cache = {
					enabled = false,
				},
			},
		}

		local repository = {
			name = "Company Nexus",
			type = "nexus",
			url = "https://nexus.company.test",
			repository = "maven-releases",
		}

		local versions
		local request_error

		Repository.versions(
			source,
			repository,
			"com.company.payment",
			"payment-client",
			function(result, err)
				versions = result
				request_error = err
			end
		)

		eq(
			#system_calls,
			1,
			"Nexus version completion must start one Maven metadata request"
		)

		system_callbacks[1]({
			code = 0,
			stdout = [[
				<metadata>
					<versioning>
						<versions>
							<version>1.0.0</version>
							<version>2.0.0-company</version>
						</versions>
					</versioning>
				</metadata>
			]],
			stderr = "",
		})

		eq(
			{
				url =
					system_calls[1].cmd[
						#system_calls[1].cmd
					],
				versions = versions,
				err = request_error,
			},
			{
				url =
					"https://nexus.company.test/repository/maven-releases/com/company/payment/payment-client/maven-metadata.xml",
				versions = {
					"1.0.0",
					"2.0.0-company",
				},
				err = nil,
			},
			"Nexus version completion must use the content root and parse Maven metadata"
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
	-- INVALID REPOSITORY
	--------------------------------------------------------------------------------

	local invalid_repository_called = false
	local invalid_repository_versions
	local invalid_repository_error

	Repository.versions(
		{
			opts = {
				cache = {
					enabled = false,
				},
			},
		},
		{},
		"com.company",
		"demo",
		function(versions, err)
			invalid_repository_called = true
			invalid_repository_versions = versions
			invalid_repository_error = err
		end
	)

	ok(
		invalid_repository_called,
		"Invalid custom repositories must resolve without starting a request"
	)

	eq(
		invalid_repository_versions,
		{},
		"Invalid custom repositories must return no versions"
	)

	eq(
		invalid_repository_error,
		"invalid repository",
		"Invalid custom repositories must return an explicit error"
	)

	--------------------------------------------------------------------------------
	-- REQUEST SPEC
	--------------------------------------------------------------------------------

	local generic_repository = {
		name = "Company",
		url = "https://repo.company.test/maven/",
	}

	local default_spec = Repository.debug_request_spec(
		{ opts = {} },
		generic_repository,
		"com.company",
		"demo"
	)

	eq(
		default_spec.url,
		"https://repo.company.test/maven/com/company/demo/maven-metadata.xml",
		"A repository request must target the artifact metadata"
	)

	eq(
		default_spec.connect_timeout,
		Repository.HTTP_CONNECT_TIMEOUT,
		"The default connect timeout must be preserved"
	)

	eq(
		default_spec.max_time,
		Repository.HTTP_MAX_TIME,
		"The default request timeout must be preserved"
	)

	eq(default_spec.retries, 0, "Repository requests must not be retried")
	eq(default_spec.decode, nil, "Maven metadata must be read as text, not JSON")

	local configured_spec = Repository.debug_request_spec(
		{
			opts = {
				connect_timeout = 1,
				max_time = 2,
			},
		},
		generic_repository,
		"com.company",
		"demo"
	)

	eq(configured_spec.connect_timeout, 1, "connect_timeout must be configurable")
	eq(configured_spec.max_time, 2, "max_time must be configurable")

	--------------------------------------------------------------------------------
	-- REQUEST FAILURES
	--
	-- The transport itself is covered by tests/specs/http.lua. These cover the
	-- repository boundary: string errors, one attempt, nothing cached.
	--------------------------------------------------------------------------------

	do
		local original_vim_system = vim.system
		local original_vim_schedule = vim.schedule

		local system_callbacks = {}

		rawset(vim, "schedule", function(fn)
			fn()
		end)

		rawset(vim, "system", function(_, _, on_exit)
			table.insert(system_callbacks, on_exit)
			return {}
		end)

		local source = {
			opts = {
				cache = {
					enabled = false,
				},
			},
		}

		local results = {}

		local function versions()
			Repository.versions(
				source,
				generic_repository,
				"com.company",
				"demo",
				function(result, err)
					table.insert(results, { versions = result, err = err })
				end
			)
		end

		versions()
		versions()

		eq(
			#system_callbacks,
			1,
			"Identical concurrent version lookups must share one request"
		)

		system_callbacks[1]({
			code = 0,
			stdout = "Not Found\n404",
		})

		eq(#system_callbacks, 1, "A missing artifact must not be retried")

		eq(
			results,
			{
				{ versions = {}, err = "HTTP 404" },
				{ versions = {}, err = "HTTP 404" },
			},
			"A missing artifact must reach every waiter as a plain string error"
		)

		-- A failure is not remembered: the next lookup asks again.
		results = {}

		versions()

		eq(#system_callbacks, 2, "A failed lookup must not be cached")

		system_callbacks[2]({
			code = 28,
			stderr = "curl: (28) Operation timed out",
		})

		eq(#system_callbacks, 2, "A timed out repository request must not be retried")

		eq(
			results[1].err,
			"curl: (28) Operation timed out",
			"A transport failure must report the curl message"
		)

		-- Success is cached for the session.
		results = {}

		versions()

		system_callbacks[3]({
			code = 0,
			stdout = "<metadata><versioning><versions>"
				.. "<version>1.0.0</version>"
				.. "</versions></versioning></metadata>\n200",
		})

		eq(
			results[1],
			{ versions = { "1.0.0" } },
			"A successful lookup must parse the metadata and report no error"
		)

		versions()

		eq(#system_callbacks, 3, "A successful lookup must be served from memory")

		--------------------------------------------------------------------------
		-- A 200 THAT IS NOT MAVEN METADATA
		--------------------------------------------------------------------------

		local dir = vim.fn.tempname()

		local persistent_source = {
			opts = {
				cache = {
					enabled = true,
					dir = dir,
				},
			},
		}

		local function persistent_versions(target)
			local seen = {}

			Repository.versions(
				target,
				generic_repository,
				"com.company",
				"demo",
				function(result, err)
					seen.versions = result
					seen.err = err
				end
			)

			return seen
		end

		local login = persistent_versions(persistent_source)

		system_callbacks[4]({
			code = 0,
			stdout = "<html><body>Please sign in</body></html>\n200",
		})

		eq(
			login,
			{ versions = {}, err = "unexpected repository response" },
			"A page that is not Maven metadata must be reported as an error"
		)

		local after_login = persistent_versions(persistent_source)

		eq(
			#system_callbacks,
			5,
			"A page that is not Maven metadata must not be cached"
		)

		-- Metadata without versions is a real, cacheable answer.
		system_callbacks[5]({
			code = 0,
			stdout = "<metadata><versioning/></metadata>\n200",
		})

		eq(
			after_login,
			{ versions = {} },
			"Metadata without versions must be an empty result, not an error"
		)

		--------------------------------------------------------------------------
		-- PERSISTENCE
		--------------------------------------------------------------------------

		-- A new session with the same cache directory needs no request.
		local next_session = {
			opts = persistent_source.opts,
		}

		eq(
			persistent_versions(next_session),
			{ versions = {} },
			"A persisted lookup must be served in a later session"
		)

		eq(#system_callbacks, 5, "A persisted lookup must not start a request")

		eq(
			next_session.repository_pipeline:stats().disk,
			1,
			"A persisted lookup must be answered by the disk cache"
		)

		vim.fn.delete(dir, "rf")

		rawset(vim, "system", original_vim_system)
		rawset(vim, "schedule", original_vim_schedule)
	end
end
