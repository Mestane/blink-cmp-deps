local Central = require("blink_deps.central")
local DiskCache = require("blink_deps.disk_cache")

return function(test)
	local eq = test.eq

	--------------------------------------------------------------------------------
	-- DEFAULT / EXPLICIT ENABLED
	--------------------------------------------------------------------------------

	local function cached_source(central)
		return {
			opts = {
				central = central,
			},
			central_cache = {
				test = {
					{
						g = "org.example",
					},
				},
			},
			central_inflight = {},
		}
	end

	local function cached_result(central)
		local result

		Central.search(
			cached_source(central),
			"test",
			{
				q = "g:org.example",
			},
			function(docs)
				result = docs
			end
		)

		return result
	end

	eq(
		cached_result(nil),
		{
			{
				g = "org.example",
			},
		},
		"Maven Central must remain enabled by default"
	)

	eq(
		cached_result({}),
		{
			{
				g = "org.example",
			},
		},
		"An empty central configuration must keep Maven Central enabled"
	)

	eq(
		cached_result({
			enabled = true,
		}),
		{
			{
				g = "org.example",
			},
		},
		"central.enabled = true must keep Maven Central enabled"
	)

	--------------------------------------------------------------------------------
	-- DISABLED
	--------------------------------------------------------------------------------

	local original_disk_get = DiskCache.get
	local original_vim_system = vim.system

	local disk_calls = 0
	local system_calls = 0

	rawset(
		DiskCache,
		"get",
		function()
			disk_calls = disk_calls + 1
			return nil, "miss"
		end
	)

	rawset(
		vim,
		"system",
		function()
			system_calls = system_calls + 1
			error(
				"Maven Central HTTP must not run when disabled"
			)
		end
	)

	local disabled_result
	local disabled_error

	Central.search(
		{
			opts = {
				central = {
					enabled = false,
				},
				cache = {
					enabled = true,
				},
			},
			central_cache = {
				disabled = {
					{
						g = "cached.central",
					},
				},
			},
			central_inflight = {},
		},
		"disabled",
		{
			q = "g:org.example",
		},
		function(docs, err)
			disabled_result = docs
			disabled_error = err
		end
	)

	eq(
		disabled_result,
		{},
		"Disabled Maven Central must return no completion documents"
	)

	eq(
		disabled_error,
		nil,
		"Disabled Maven Central must not report a request error"
	)

	eq(
		disk_calls,
		0,
		"Disabled Maven Central must not read the persistent Central cache"
	)

	eq(
		system_calls,
		0,
		"Disabled Maven Central must not start an HTTP request"
	)

	rawset(
		DiskCache,
		"get",
		original_disk_get
	)

	rawset(
		vim,
		"system",
		original_vim_system
	)

	--------------------------------------------------------------------------------
	-- REQUEST SPEC
	--------------------------------------------------------------------------------

	local default_spec = Central.debug_request_spec(
		{ opts = {} },
		{ q = "g:org.example", wt = "json" }
	)

	eq(default_spec.url, Central.URL, "Requests must target Maven Central by default")
	eq(default_spec.decode, "json", "Central responses must be decoded as JSON")

	eq(
		default_spec.query,
		{ q = "g:org.example", wt = "json" },
		"Search arguments must become the query string"
	)

	eq(
		default_spec.connect_timeout,
		Central.HTTP_CONNECT_TIMEOUT,
		"The default connect timeout must be preserved"
	)

	eq(
		default_spec.max_time,
		Central.HTTP_MAX_TIME,
		"The default request timeout must be preserved"
	)

	eq(
		default_spec.retries,
		Central.HTTP_RETRIES,
		"Stalled Central requests must be retried once by default"
	)

	local configured_spec = Central.debug_request_spec(
		{
			opts = {
				central_url = "https://mirror.test/select",
				connect_timeout = 1,
				max_time = 2,
				retries = -4,
			},
		},
		{}
	)

	eq(
		configured_spec.url,
		"https://mirror.test/select",
		"central_url must override the endpoint"
	)

	eq(configured_spec.connect_timeout, 1, "connect_timeout must be configurable")
	eq(configured_spec.max_time, 2, "max_time must be configurable")
	eq(configured_spec.retries, 0, "A negative retry budget must be clamped to zero")

	--------------------------------------------------------------------------------
	-- REQUEST LIFECYCLE
	--
	-- The transport itself is covered by tests/specs/http.lua. These cover
	-- what Central adds on top: one request per key, waiters sharing it, the
	-- string error contract, and failures never being cached.
	--------------------------------------------------------------------------------

	local original_vim_schedule = vim.schedule
	local original_disk_set = DiskCache.set

	local system_callbacks = {}

	rawset(vim, "schedule", function(fn)
		fn()
	end)

	rawset(vim, "system", function(_, _, on_exit)
		table.insert(system_callbacks, on_exit)
		return {}
	end)

	rawset(DiskCache, "get", function()
		return nil, "miss"
	end)

	rawset(DiskCache, "set", function()
		return true, nil
	end)

	local source = {
		opts = {},
		central_cache = {},
		central_inflight = {},
	}

	local results = {}

	local function search()
		Central.search(
			source,
			"lifecycle",
			{ q = "g:org.example" },
			function(docs, err)
				table.insert(results, { docs = docs, err = err })
			end
		)
	end

	search()
	search()

	eq(#system_callbacks, 1, "Identical concurrent searches must share one request")

	-- First attempt stalls, the retry is refused: both waiters get the error.
	system_callbacks[1]({
		code = 28,
		stderr = "curl: (28) Operation timed out",
	})

	eq(#system_callbacks, 2, "A stalled Central request must be retried")
	eq(#results, 0, "Waiters must not be answered while a retry is running")

	system_callbacks[2]({
		code = 7,
		stderr = "curl: (7) Failed to connect",
	})

	eq(#results, 2, "Every waiter must be answered once the request fails")
	eq(results[1].docs, {}, "A failed search must return no documents")

	eq(
		results[1].err,
		"curl: (7) Failed to connect",
		"Central errors must stay plain strings for existing callers"
	)

	eq(
		source.central_cache.lifecycle,
		nil,
		"A failed search must not be cached"
	)

	-- A later search starts over and succeeds.
	results = {}

	search()

	eq(#system_callbacks, 3, "A failed search must be retryable afterwards")

	system_callbacks[3]({
		code = 0,
		stdout = vim.json.encode({
			response = {
				numFound = 1,
				docs = {
					{ g = "org.example", a = "demo", latestVersion = "1.0.0" },
				},
			},
		}) .. "\n200",
	})

	eq(
		results[1],
		{
			docs = {
				{ g = "org.example", a = "demo", latestVersion = "1.0.0" },
			},
		},
		"A successful search must deliver the deduplicated documents"
	)

	search()

	eq(#system_callbacks, 3, "A cached search must not start another request")

	-- An HTTP error is reported, not mistaken for an empty result.
	results = {}

	Central.search(
		source,
		"rejected",
		{ q = "broken" },
		function(docs, err)
			table.insert(results, { docs = docs, err = err })
		end
	)

	system_callbacks[4]({
		code = 0,
		stdout = "bad request\n400",
	})

	eq(results[1].err, "HTTP 400", "An HTTP error must be reported to the caller")
	eq(#system_callbacks, 4, "A rejected query must not be retried")
	eq(source.central_cache.rejected, nil, "A rejected query must not be cached")

	-- Valid JSON that is not a Solr result is an outage, not "no matches".
	results = {}

	Central.search(
		source,
		"malformed",
		{ q = "g:org.example" },
		function(docs, err)
			table.insert(results, { docs = docs, err = err })
		end
	)

	system_callbacks[5]({
		code = 0,
		stdout = '{"error":"service unavailable"}\n200',
	})

	eq(
		results[1],
		{ docs = {}, err = "malformed Central response" },
		"A response without a Solr result must be reported as an error"
	)

	eq(
		source.central_cache.malformed,
		nil,
		"A malformed response must not be cached"
	)

	-- The shared pipeline is doing the bookkeeping.
	local stats = source.central_pipeline:stats()

	eq(stats.name, "central", "Central must run on its own named pipeline")
	eq(stats.network, 4, "Every started search must be counted")
	eq(stats.errors, 3, "Every failed search must be counted")
	eq(stats.shared, 1, "A search that joined a running one must be counted")
	eq(stats.memory, 1, "A search answered from memory must be counted")

	-- Replacing the source's cache table must not leave the pipeline
	-- serving the old one.
	source.central_cache = {
		lifecycle = {
			{ g = "replaced" },
		},
	}

	results = {}

	search()

	eq(
		results[1].docs,
		{ { g = "replaced" } },
		"A replaced cache table must be picked up"
	)

	rawset(vim, "system", original_vim_system)
	rawset(vim, "schedule", original_vim_schedule)
	rawset(DiskCache, "get", original_disk_get)
	rawset(DiskCache, "set", original_disk_set)
end
