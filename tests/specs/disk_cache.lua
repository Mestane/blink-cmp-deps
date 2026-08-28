local Central = require("blink_deps.central")
local DiskCache = require("blink_deps.disk_cache")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- PERSISTENT CACHE
	--------------------------------------------------------------------------------

	local cache_test_root = vim.fn.tempname() .. "-blink-cmp-deps"

	local cache_opts = {
		dir = cache_test_root,
		ttl = 86400,
	}

	local cache_docs = {
		{
			g = "org.springframework.kafka",
			a = "spring-kafka",
			latestVersion = "4.0.0",
		},
	}

	--------------------------------------------------------------------------------
	-- DEFAULTS
	--------------------------------------------------------------------------------

	eq(
		DiskCache.DEFAULT_TTL,
		86400,
		"Persistent cache default TTL must be 24 hours"
	)

	--------------------------------------------------------------------------------
	-- WRITE / READ
	--------------------------------------------------------------------------------

	local cache_written, cache_write_err =
		DiskCache.set(
			cache_opts,
			"central",
			"basic",
			cache_docs
		)

	ok(
		cache_written and cache_write_err == nil,
		"Persistent cache must write valid data"
	)

	local cached_docs, cache_status =
		DiskCache.get(
			cache_opts,
			"central",
			"basic"
		)

	eq(
		cache_status,
		"hit",
		"Persistent cache must report a cache hit"
	)

	eq(
		cached_docs,
		cache_docs,
		"Persistent cache must restore written data"
	)

	--------------------------------------------------------------------------------
	-- OVERWRITE
	--------------------------------------------------------------------------------

	local replacement_docs = {
		{
			g = "org.springframework.kafka",
			a = "spring-kafka",
			latestVersion = "4.1.0",
		},
	}

	local overwrite_written, overwrite_err =
		DiskCache.set(
			cache_opts,
			"central",
			"basic",
			replacement_docs
		)

	ok(
		overwrite_written and overwrite_err == nil,
		"Persistent cache must overwrite an existing entry"
	)

	local overwritten_docs =
		DiskCache.get(
			cache_opts,
			"central",
			"basic"
		)

	eq(
		overwritten_docs,
		replacement_docs,
		"Persistent cache overwrite must expose the newest data"
	)

	--------------------------------------------------------------------------------
	-- DISABLED CACHE
	--------------------------------------------------------------------------------

	local disabled_written, disabled_write_status =
		DiskCache.set(
			{
				dir = cache_test_root,
				enabled = false,
			},
			"central",
			"disabled",
			cache_docs
		)

	ok(
		disabled_written == false
			and disabled_write_status == "disabled",
		"Disabled persistent cache must not write entries"
	)

	local disabled_data, disabled_read_status =
		DiskCache.get(
			{
				dir = cache_test_root,
				enabled = false,
			},
			"central",
			"disabled"
		)

	ok(
		disabled_data == nil
			and disabled_read_status == "disabled",
		"Disabled persistent cache must not read entries"
	)

	--------------------------------------------------------------------------------
	-- CORRUPTED CACHE
	--------------------------------------------------------------------------------

	local corrupt_path =
		DiskCache.debug_path(
			cache_opts,
			"central",
			"corrupt"
		)

	vim.fn.mkdir(vim.fs.dirname(corrupt_path), "p")

	vim.fn.writefile(
		{
			"{ definitely-not-valid-json",
		},
		corrupt_path
	)

	local corrupt_data, corrupt_status =
		DiskCache.get(
			cache_opts,
			"central",
			"corrupt"
		)

	ok(
		corrupt_data == nil
			and corrupt_status == "invalid",
		"Corrupted persistent cache entries must be treated as misses"
	)

	eq(
		vim.fn.filereadable(corrupt_path),
		0,
		"Corrupted persistent cache entries must be removed"
	)

	--------------------------------------------------------------------------------
	-- STALE CACHE
	--------------------------------------------------------------------------------

	local stale_path =
		DiskCache.debug_path(
			cache_opts,
			"central",
			"stale"
		)

	vim.fn.mkdir(vim.fs.dirname(stale_path), "p")

	vim.fn.writefile(
		{
			vim.json.encode({
				schema = DiskCache.SCHEMA_VERSION,
				created_at = os.time() - 10,
				data = cache_docs,
			}),
		},
		stale_path
	)

	local stale_data, stale_status =
		DiskCache.get(
			{
				dir = cache_test_root,
				ttl = 1,
			},
			"central",
			"stale"
		)

	ok(
		stale_data == nil
			and stale_status == "stale",
		"Expired persistent cache entries must be treated as stale"
	)

	eq(
		vim.fn.filereadable(stale_path),
		0,
		"Expired persistent cache entries must be removed"
	)

	--------------------------------------------------------------------------------
	-- REQUEST FINGERPRINT
	--------------------------------------------------------------------------------

	local fingerprint_source = {
		opts = {},
	}

	local fingerprint_one =
		Central.debug_request_fingerprint(
			fingerprint_source,
			{
				q = "g:org.springframework.kafka",
				rows = "200",
				wt = "json",
			}
		)

	local fingerprint_two =
		Central.debug_request_fingerprint(
			fingerprint_source,
			{
				wt = "json",
				q = "g:org.springframework.kafka",
				rows = "200",
			}
		)

	eq(
		fingerprint_one,
		fingerprint_two,
		"Central request fingerprint must not depend on Lua table iteration order"
	)

	local fingerprint_different_args =
		Central.debug_request_fingerprint(
			fingerprint_source,
			{
				q = "g:org.springframework.kafka",
				rows = "100",
				wt = "json",
			}
		)

	ok(
		fingerprint_one ~= fingerprint_different_args,
		"Central request fingerprint must change when request arguments change"
	)

	local fingerprint_different_url =
		Central.debug_request_fingerprint(
			{
				opts = {
					central_url = "https://example.invalid/search",
				},
			},
			{
				q = "g:org.springframework.kafka",
				rows = "200",
				wt = "json",
			}
		)

	ok(
		fingerprint_one ~= fingerprint_different_url,
		"Central request fingerprint must include the Central URL"
	)

	--------------------------------------------------------------------------------
	-- CENTRAL.SEARCH DISK CACHE INTEGRATION
	--------------------------------------------------------------------------------

	local integration_source = {
		opts = {
			debug = false,

			cache = {
				dir = cache_test_root,
				ttl = 86400,
			},
		},

		central_cache = {},
		central_inflight = {},
	}

	local integration_args = {
		q = "g:org.example",
		rows = "200",
		wt = "json",
	}

	local integration_fingerprint =
		Central.debug_request_fingerprint(
			integration_source,
			integration_args
		)

	local integration_docs = {
		{
			g = "org.example",
			a = "example-core",
			latestVersion = "1.0.0",
		},
	}

	local integration_written, integration_write_err =
		DiskCache.set(
			integration_source.opts.cache,
			"central",
			integration_fingerprint,
			integration_docs
		)

	ok(
		integration_written
			and integration_write_err == nil,
		"Central integration test cache entry must be writable"
	)

	local integration_called = false
	local integration_result
	local integration_error

	Central.search(
		integration_source,
		"integration:key",
		integration_args,
		function(docs, err)
			integration_called = true
			integration_result = docs
			integration_error = err
		end
	)

	ok(
		integration_called,
		"Central.search must resolve synchronously from persistent cache"
	)

	eq(
		integration_result,
		integration_docs,
		"Central.search must return data from persistent cache"
	)

	eq(
		integration_error,
		nil,
		"Central.search persistent cache hit must not return an error"
	)

	eq(
		integration_source.central_cache["integration:key"],
		integration_docs,
		"Central.search must promote persistent data into session memory cache"
	)


	--------------------------------------------------------------------------------
	-- FILESYSTEM FAILURE
	--------------------------------------------------------------------------------

	local blocked_cache_root =
		vim.fn.tempname() .. "-blink-cmp-deps-blocked"

	vim.fn.writefile(
		{
			"this is a file, not a directory",
		},
		blocked_cache_root
	)

	local blocked_written, blocked_error =
		DiskCache.set(
			{
				dir = blocked_cache_root,
				ttl = 86400,
			},
			"central",
			"blocked",
			cache_docs
		)

	ok(
		blocked_written == false
			and blocked_error == "mkdir failed",
		"Persistent cache filesystem failures must be non-fatal"
	)

	vim.fn.delete(blocked_cache_root)

	--------------------------------------------------------------------------------
	-- CLEANUP
	--------------------------------------------------------------------------------

	vim.fn.delete(cache_test_root, "rf")

	--------------------------------------------------------------------------------
end
