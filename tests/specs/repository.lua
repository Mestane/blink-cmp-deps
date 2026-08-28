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
end
