local Pipeline = require("blink_deps.pipeline")
local DiskCache = require("blink_deps.disk_cache")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A fetch that records its calls and is answered by hand, so the order of
	-- events is under the spec's control.
	--------------------------------------------------------------------------------

	local function recorder()
		local state = {
			calls = 0,
			done = {},
		}

		state.fetch = function(done)
			state.calls = state.calls + 1
			table.insert(state.done, done)
		end

		return state
	end

	local function collector()
		local results = {}

		return results, function(value, err, origin)
			table.insert(results, {
				value = value,
				err = err,
				origin = origin,
			})
		end
	end

	--------------------------------------------------------------------------------
	-- NETWORK, THEN MEMORY
	--------------------------------------------------------------------------------

	local pipeline = Pipeline.new({ name = "spec" })
	local remote = recorder()
	local results, collect = collector()

	pipeline:fetch({ key = "serde", fetch = remote.fetch }, collect)

	eq(remote.calls, 1, "A first lookup must start a fetch")
	eq(#results, 0, "A lookup must not answer before its fetch reports")

	remote.done[1]({ "1.0.0" }, nil)

	eq(
		results,
		{ { value = { "1.0.0" }, origin = "network" } },
		"A fetched value must be delivered with its origin"
	)

	pipeline:fetch({ key = "serde", fetch = remote.fetch }, collect)

	eq(remote.calls, 1, "A cached lookup must not fetch again")
	eq(results[2].origin, "memory", "A repeated lookup must be served from memory")
	eq(results[2].value, { "1.0.0" }, "The cached value must be delivered")

	--------------------------------------------------------------------------------
	-- COALESCING
	--------------------------------------------------------------------------------

	pipeline = Pipeline.new()
	remote = recorder()
	results, collect = collector()

	pipeline:fetch({ key = "tokio", fetch = remote.fetch }, collect)
	pipeline:fetch({ key = "tokio", fetch = remote.fetch }, collect)
	pipeline:fetch({ key = "tokio", fetch = remote.fetch }, collect)
	pipeline:fetch({ key = "other", fetch = remote.fetch }, collect)

	eq(remote.calls, 2, "Identical concurrent lookups must share one fetch")

	remote.done[1]({ "1.40.0" }, nil)

	eq(#results, 3, "Every waiter on a key must be answered together")

	for index = 1, 3 do
		eq(
			results[index].value,
			{ "1.40.0" },
			"Every waiter must receive the fetched value"
		)
	end

	eq(pipeline:stats().running, 1, "An unrelated key must still be running")

	remote.done[2]({ "x" }, nil)

	eq(pipeline:stats().running, 0, "A finished fetch must no longer be running")

	--------------------------------------------------------------------------------
	-- FAILURES ARE DELIVERED AND NEVER CACHED
	--------------------------------------------------------------------------------

	pipeline = Pipeline.new()
	remote = recorder()
	results, collect = collector()

	pipeline:fetch({ key = "k", fetch = remote.fetch }, collect)
	pipeline:fetch({ key = "k", fetch = remote.fetch }, collect)

	remote.done[1]({ "partial" }, "timeout")

	eq(
		results,
		{
			{ err = "timeout", origin = "network" },
			{ err = "timeout", origin = "network" },
		},
		"A failure must reach every waiter and carry no value"
	)

	pipeline:fetch({ key = "k", fetch = remote.fetch }, collect)

	eq(remote.calls, 2, "A failed lookup must be retried by the next request")

	remote.done[2]({ "ok" }, nil)

	eq(results[3].value, { "ok" }, "A later success must be delivered")
	eq(results[3].err, nil, "A later success must not retain the old error")

	-- A fetch that reports nothing at all is a failure, not a cached nil.
	pipeline:fetch({ key = "nothing", fetch = remote.fetch }, collect)

	remote.done[3](nil, nil)

	eq(results[4].err, "empty result", "A fetch without a value must be an error")

	-- A structured error is passed through untouched.
	local structured = { kind = "not_found", message = "HTTP 404" }

	pipeline:fetch({ key = "structured", fetch = remote.fetch }, collect)

	remote.done[4](nil, structured)

	ok(
		results[5].err == structured,
		"An error must be delivered exactly as the fetch reported it"
	)

	--------------------------------------------------------------------------------
	-- MISBEHAVING FETCHES
	--------------------------------------------------------------------------------

	pipeline = Pipeline.new()
	remote = recorder()
	results, collect = collector()

	pipeline:fetch({ key = "twice", fetch = remote.fetch }, collect)

	remote.done[1]({ "first" }, nil)
	remote.done[1]({ "second" }, nil)

	eq(#results, 1, "A fetch that reports twice must answer only once")
	eq(results[1].value, { "first" }, "The first report must win")

	pipeline:fetch({
		key = "throws",
		fetch = function()
			error("boom")
		end,
	}, collect)

	ok(
		tostring(results[2].err):find("boom", 1, true) ~= nil,
		"A fetch that throws must be reported as an error"
	)

	eq(pipeline:stats().running, 0, "A fetch that throws must not stay running")

	-- A fetch that answers synchronously works like any other.
	pipeline:fetch({
		key = "sync",
		fetch = function(done)
			done({ "now" }, nil)
		end,
	}, collect)

	eq(results[3].value, { "now" }, "A synchronous fetch must be delivered")

	--------------------------------------------------------------------------------
	-- ONE BROKEN CONSUMER
	--------------------------------------------------------------------------------

	pipeline = Pipeline.new()
	remote = recorder()
	results, collect = collector()

	pipeline:fetch({ key = "k", fetch = remote.fetch }, function()
		error("consumer failed")
	end)

	pipeline:fetch({ key = "k", fetch = remote.fetch }, collect)

	local delivered, failure = pcall(remote.done[1], { "v" }, nil)

	eq(#results, 1, "A failing consumer must not starve the others")

	ok(
		not delivered and tostring(failure):find("consumer failed", 1, true) ~= nil,
		"A consumer failure must still surface instead of being swallowed"
	)

	eq(pipeline:stats().running, 0, "A consumer failure must not leave the key running")

	-- The same holds when the fetch answers synchronously: the failure is the
	-- consumer's and must not be reported as a failed fetch.
	pipeline = Pipeline.new()

	local sync_ok, sync_failure = pcall(function()
		pipeline:fetch({
			key = "sync",
			fetch = function(done)
				done({ "v" }, nil)
			end,
		}, function()
			error("sync consumer failed")
		end)
	end)

	ok(
		not sync_ok
			and tostring(sync_failure):find("sync consumer failed", 1, true) ~= nil,
		"A synchronous consumer failure must surface unchanged"
	)

	eq(
		pipeline:stats().errors,
		0,
		"A consumer failure must not be counted as a failed fetch"
	)

	eq(pipeline.memory.sync, { "v" }, "The fetched value must still be cached")

	-- A waiter that asks again from inside its callback starts a new fetch.
	pipeline = Pipeline.new()
	remote = recorder()

	pipeline:fetch({ key = "again", fetch = remote.fetch }, function()
		pipeline:fetch({ key = "again", fetch = remote.fetch }, function() end)
	end)

	remote.done[1](nil, "failed")

	eq(remote.calls, 2, "Asking again from a callback must start a fresh fetch")

	--------------------------------------------------------------------------------
	-- COPIES
	--------------------------------------------------------------------------------

	pipeline = Pipeline.new()
	remote = recorder()
	results, collect = collector()

	pipeline:fetch({ key = "k", fetch = remote.fetch, copy = true }, collect)

	remote.done[1]({ "a" }, nil)

	table.insert(results[1].value, "mutated")

	pipeline:fetch({ key = "k", fetch = remote.fetch, copy = true }, collect)

	eq(
		results[2].value,
		{ "a" },
		"With copy set, a consumer must not be able to corrupt the cache"
	)

	--------------------------------------------------------------------------------
	-- EXISTING TABLES
	--------------------------------------------------------------------------------

	local memory = { preset = { "cached" } }
	local inflight = {}

	pipeline = Pipeline.new({ memory = memory, inflight = inflight })
	remote = recorder()
	results, collect = collector()

	pipeline:fetch({ key = "preset", fetch = remote.fetch }, collect)

	eq(remote.calls, 0, "A caller supplied cache must be honoured")
	eq(results[1].value, { "cached" }, "A caller supplied entry must be served")

	pipeline:fetch({ key = "new", fetch = remote.fetch }, collect)

	ok(inflight.new ~= nil, "Running requests must be visible in the caller's table")

	remote.done[1]({ "v" }, nil)

	eq(memory.new, { "v" }, "Results must be written to the caller's cache")
	eq(inflight.new, nil, "Finished requests must leave the caller's table")

	--------------------------------------------------------------------------------
	-- PERSISTENT CACHE
	--------------------------------------------------------------------------------

	local dir = vim.fn.tempname()

	local cache_opts = {
		enabled = true,
		dir = dir,
	}

	local function disk(key)
		return {
			opts = cache_opts,
			namespace = "spec",
			key = key,
		}
	end

	pipeline = Pipeline.new()
	remote = recorder()
	results, collect = collector()

	pipeline:fetch({
		key = "serde",
		fetch = remote.fetch,
		disk = disk("serde-key"),
	}, collect)

	remote.done[1]({ "1.0.0" }, nil)

	eq(
		DiskCache.get(cache_opts, "spec", "serde-key"),
		{ "1.0.0" },
		"A fetched value must be persisted"
	)

	-- A new session has no memory but finds the value on disk.
	local second_session = Pipeline.new()

	second_session:fetch({
		key = "serde",
		fetch = remote.fetch,
		disk = disk("serde-key"),
	}, collect)

	eq(remote.calls, 1, "A persisted value must not be fetched again")
	eq(results[2].origin, "disk", "A persisted value must report its origin")
	eq(results[2].value, { "1.0.0" }, "A persisted value must be delivered")

	second_session:fetch({
		key = "serde",
		fetch = remote.fetch,
		disk = disk("serde-key"),
	}, collect)

	eq(
		results[3].origin,
		"memory",
		"A value read from disk must be promoted to memory"
	)

	-- The disk descriptor may be a function, evaluated only when needed.
	local described = 0

	local function lazy_disk()
		described = described + 1
		return disk("serde-key")
	end

	second_session:fetch({
		key = "serde",
		fetch = remote.fetch,
		disk = lazy_disk,
	}, collect)

	eq(described, 0, "A memory hit must not evaluate the disk descriptor")

	local fourth_session = Pipeline.new()

	fourth_session:fetch({
		key = "serde",
		fetch = remote.fetch,
		disk = lazy_disk,
	}, collect)

	eq(described, 1, "A memory miss must evaluate the disk descriptor once")

	eq(
		results[#results].origin,
		"disk",
		"A lazily described entry must be read from disk"
	)

	-- Failures are not persisted either.
	pipeline:fetch({
		key = "broken",
		fetch = remote.fetch,
		disk = disk("broken-key"),
	}, collect)

	remote.done[2](nil, "timeout")

	eq(
		DiskCache.get(cache_opts, "spec", "broken-key"),
		nil,
		"A failed fetch must not be persisted"
	)

	-- An expired entry is reported and refetched.
	local events = {}

	local expiring_opts = {
		enabled = true,
		dir = dir,
		ttl = 1,
	}

	DiskCache.set(expiring_opts, "spec", "old-key", { "old" })

	local original_time = os.time

	rawset(os, "time", function()
		return original_time() + 3600
	end)

	local third_session = Pipeline.new()

	third_session:fetch({
		key = "old",
		fetch = remote.fetch,
		disk = {
			opts = expiring_opts,
			namespace = "spec",
			key = "old-key",
		},
		on_event = function(event)
			table.insert(events, event)
		end,
	}, collect)

	rawset(os, "time", original_time)

	eq(events, { "stale" }, "An expired entry must be reported")
	eq(remote.calls, 3, "An expired entry must be fetched again")

	-- A value that cannot be persisted is still delivered.
	events = {}

	pipeline:fetch({
		key = "text",
		fetch = remote.fetch,
		disk = disk("text-key"),
		on_event = function(event, detail)
			table.insert(events, { event, detail })
		end,
	}, collect)

	remote.done[4]("plain text", nil)

	eq(
		results[#results].value,
		"plain text",
		"A value that cannot be persisted must still be delivered"
	)

	eq(
		events,
		{ { "write_failed", "invalid data" } },
		"A failed write must be reported, not raised"
	)

	-- A disabled cache is silent.
	events = {}

	pipeline:fetch({
		key = "quiet",
		fetch = remote.fetch,
		disk = {
			opts = { enabled = false },
			namespace = "spec",
			key = "quiet-key",
		},
		on_event = function(event)
			table.insert(events, event)
		end,
	}, collect)

	remote.done[5]({ "v" }, nil)

	eq(events, {}, "A disabled cache must not be reported as a failure")

	vim.fn.delete(dir, "rf")

	--------------------------------------------------------------------------------
	-- STATS AND INVALIDATION
	--------------------------------------------------------------------------------

	pipeline = Pipeline.new({ name = "stats" })
	remote = recorder()
	results, collect = collector()

	pipeline:fetch({ key = "a", fetch = remote.fetch }, collect)
	pipeline:fetch({ key = "a", fetch = remote.fetch }, collect)
	remote.done[1]({ "v" }, nil)
	pipeline:fetch({ key = "a", fetch = remote.fetch }, collect)
	pipeline:fetch({ key = "b", fetch = remote.fetch }, collect)
	remote.done[2](nil, "failed")

	eq(
		pipeline:stats(),
		{
			name = "stats",
			memory = 1,
			shared = 1,
			disk = 0,
			network = 2,
			errors = 1,
			entries = 1,
			running = 0,
		},
		"Stats must count each way a lookup was answered"
	)

	pipeline:clear()

	eq(pipeline:stats().entries, 0, "Clearing must empty the session cache")

	pipeline:fetch({ key = "a", fetch = remote.fetch }, collect)

	eq(remote.calls, 3, "A cleared entry must be fetched again")

	-- Clearing leaves a running request alone.
	pipeline:clear()

	remote.done[3]({ "fresh" }, nil)

	eq(
		results[#results].value,
		{ "fresh" },
		"Clearing must not strand a waiter on a running request"
	)
end
