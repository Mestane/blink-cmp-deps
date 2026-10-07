local DiskCache = require("blink_deps.disk_cache")

--------------------------------------------------------------------------------
-- REQUEST PIPELINE
--
-- Every remote lookup follows the same four steps:
--
--   1. session memory
--   2. a request for the same key that is already running
--   3. the persistent cache
--   4. the actual fetch
--
-- Each registry used to spell these out by hand, and the copies drifted: some
-- persisted and some did not, some copied results and some shared them. This
-- module is the single implementation.
--
-- It knows nothing about HTTP or about any ecosystem. The caller supplies the
-- key and a fetch function; whatever the fetch produces is what gets cached.
--------------------------------------------------------------------------------

local Pipeline = {}
Pipeline.__index = Pipeline

local function new_stats()
	return {
		memory = 0,
		shared = 0,
		disk = 0,
		network = 0,
		errors = 0,
	}
end

--------------------------------------------------------------------------------
-- CONSTRUCTION
--
-- opts:
--   name      label used in diagnostics
--   memory    existing table to use as the session cache, optional
--   inflight  existing table to use for running requests, optional
--
-- Accepting existing tables lets a caller keep the cache it already owns
-- while handing the bookkeeping over.
--------------------------------------------------------------------------------

function Pipeline.new(opts)
	opts = opts or {}

	return setmetatable({
		name = opts.name or "pipeline",
		memory = opts.memory or {},
		inflight = opts.inflight or {},
		counters = new_stats(),
	}, Pipeline)
end

--------------------------------------------------------------------------------
-- DELIVERY
--------------------------------------------------------------------------------

local function deliver(request, callback, value, err, origin)
	if value ~= nil and request.copy then
		value = vim.deepcopy(value)
	end

	callback(value, err, origin)
end

local function notify(request, event, detail)
	if type(request.on_event) == "function" then
		request.on_event(event, detail)
	end
end

--------------------------------------------------------------------------------
-- FETCH
--
-- request:
--   key       string identifying the lookup within this pipeline
--   fetch     function(done); must call done(value, err) once
--   disk      { opts, namespace, key } to persist through the disk cache,
--             or a function returning that table, optional. opts is the
--             user's cache configuration.
--   copy      hand every consumer its own deep copy, optional
--   on_event  function(event, detail), optional. Events:
--               "stale"         a persisted entry had expired
--               "write_failed"  the result could not be persisted
--
-- callback(value, err, origin) where origin is one of
--   "memory", "shared", "disk", "network".
--
-- A failed fetch is delivered to everyone waiting on it and is never cached,
-- so the next lookup for the same key starts over.
--------------------------------------------------------------------------------

function Pipeline:fetch(request, callback)
	local key = request.key

	--------------------------------------------------------------------------
	-- 1. SESSION MEMORY
	--------------------------------------------------------------------------

	local cached = self.memory[key]

	if cached ~= nil then
		self.counters.memory = self.counters.memory + 1
		deliver(request, callback, cached, nil, "memory")
		return
	end

	--------------------------------------------------------------------------
	-- 2. REQUEST ALREADY RUNNING
	--
	-- Checked before the disk so repeated completion requests do not keep
	-- re-reading the same cache file while a fetch is in flight.
	--------------------------------------------------------------------------

	local running = self.inflight[key]

	if running then
		self.counters.shared = self.counters.shared + 1
		table.insert(running, callback)
		return
	end

	--------------------------------------------------------------------------
	-- 3. PERSISTENT CACHE
	--------------------------------------------------------------------------

	local disk = request.disk

	-- A function is only evaluated here, after memory and running requests
	-- have both missed, so callers can defer the cost of deriving a key.
	if type(disk) == "function" then
		disk = disk()
	end

	if disk then
		local persisted, status = DiskCache.get(
			disk.opts,
			disk.namespace,
			disk.key
		)

		if persisted ~= nil then
			self.memory[key] = persisted
			self.counters.disk = self.counters.disk + 1
			deliver(request, callback, persisted, nil, "disk")
			return
		end

		if status == "stale" then
			notify(request, "stale")
		end
	end

	--------------------------------------------------------------------------
	-- 4. FETCH
	--------------------------------------------------------------------------

	self.inflight[key] = { callback }
	self.counters.network = self.counters.network + 1

	local finished = false

	local function done(value, err)
		-- A fetch that reports twice must not answer its waiters twice.
		if finished then
			return
		end

		finished = true

		if err == nil and value == nil then
			err = "empty result"
		end

		if err ~= nil then
			value = nil
			self.counters.errors = self.counters.errors + 1
		else
			self.memory[key] = value

			if disk then
				-- Persistence is an optimization. A failed write must
				-- never fail the lookup that produced the value.
				local written, write_err = DiskCache.set(
					disk.opts,
					disk.namespace,
					disk.key,
					value
				)

				if not written and write_err ~= "disabled" then
					notify(request, "write_failed", write_err)
				end
			end
		end

		-- Cleared before anyone is called so a waiter that immediately
		-- asks again starts a new request instead of joining a dead one.
		local waiters = self.inflight[key] or {}

		self.inflight[key] = nil

		local first_failure

		for _, waiter in ipairs(waiters) do
			local ok, failure = pcall(
				deliver,
				request,
				waiter,
				value,
				err,
				"network"
			)

			-- One broken consumer must not leave the others waiting forever.
			if not ok and first_failure == nil then
				first_failure = failure
			end
		end

		if first_failure ~= nil then
			error(first_failure, 0)
		end
	end

	local ok, failure = pcall(request.fetch, done)

	-- A fetch that throws before reporting would otherwise leave the key
	-- marked as running for the rest of the session.
	if not ok then
		if finished then
			-- The fetch reported synchronously and a consumer failed.
			-- That failure belongs to the consumer, not to the fetch.
			error(failure, 0)
		end

		done(nil, tostring(failure))
	end
end

--------------------------------------------------------------------------------
-- INVALIDATION
--
-- Running requests are left alone: their waiters still need an answer.
--------------------------------------------------------------------------------

function Pipeline:clear()
	for key in pairs(self.memory) do
		self.memory[key] = nil
	end
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS
--------------------------------------------------------------------------------

function Pipeline:stats()
	local running = 0

	for _ in pairs(self.inflight) do
		running = running + 1
	end

	local entries = 0

	for _ in pairs(self.memory) do
		entries = entries + 1
	end

	local stats = vim.deepcopy(self.counters)

	stats.name = self.name
	stats.entries = entries
	stats.running = running

	return stats
end

return Pipeline
