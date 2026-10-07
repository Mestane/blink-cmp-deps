local Util = require("blink_deps.util")
local DiskCache = require("blink_deps.disk_cache")
local Http = require("blink_deps.http")

local M = {}

M.URL = "https://search.maven.org/solrsearch/select"
M.HTTP_CONNECT_TIMEOUT = 3
M.HTTP_MAX_TIME = 3

--------------------------------------------------------------------------------
-- DEBUG
--------------------------------------------------------------------------------

local debug_log = Util.debug_log

-- Every page of a paginated search shares the same q, so the offset has to
-- be part of the label or the log cannot tell pages apart.
local function query_label(args)
	local q = tostring(args.q or "")

	if args.start then
		return q .. " (start=" .. tostring(args.start) .. ")"
	end

	return q
end

--------------------------------------------------------------------------------
-- ENABLED
--------------------------------------------------------------------------------

local function enabled(source)
	local central =
		source.opts
		and source.opts.central

	return type(central) ~= "table"
		or central.enabled ~= false
end

--------------------------------------------------------------------------------
-- REQUEST IDENTITY
--------------------------------------------------------------------------------

local function request_fingerprint(source, args)
	local parts = {
		source.opts.central_url or M.URL,
	}

	local keys = {}

	for key in pairs(args) do
		table.insert(keys, key)
	end

	table.sort(keys)

	for _, key in ipairs(keys) do
		table.insert(
			parts,
			tostring(key) .. "=" .. tostring(args[key])
		)
	end

	return vim.fn.sha256(table.concat(parts, "\n"))
end

--------------------------------------------------------------------------------
-- HTTP
--
-- Transport, retry policy and error classification live in blink_deps.http.
-- What stays here is what is specific to search.maven.org.
--------------------------------------------------------------------------------

M.HTTP_RETRIES = 1

-- search.maven.org stalls at random. The same query answers in under half a
-- second on one attempt and never returns on the next, with no concurrency
-- involved, so a stalled request is worth repeating rather than backing off.
local function retry_budget(source)
	local configured =
		source.opts
		and source.opts.retries

	if type(configured) == "number" then
		return math.max(configured, 0)
	end

	return M.HTTP_RETRIES
end

local function request_spec(source, args)
	return {
		url = source.opts.central_url or M.URL,
		query = args,
		decode = "json",
		connect_timeout =
			source.opts.connect_timeout or M.HTTP_CONNECT_TIMEOUT,
		max_time = source.opts.max_time or M.HTTP_MAX_TIME,
		retries = retry_budget(source),
		on_retry = function(err)
			debug_log(
				source,
				"Central retrying %s after %s",
				query_label(args),
				err.kind
			)
		end,
	}
end

-- Callers of Central.search concatenate the error into notifications, so the
-- structured transport error is flattened to its message at this boundary.
local function run_query(source, args, callback)
	Http.request(request_spec(source, args), function(data, err)
		if err then
			callback(nil, err.message)
			return
		end

		callback(data, nil)
	end)
end

--------------------------------------------------------------------------------
-- SEARCH
--------------------------------------------------------------------------------

function M.search(source, key, args, callback)
	if not enabled(source) then
		callback({}, nil)
		return
	end

	--------------------------------------------------------------------------
	-- 1. SESSION MEMORY CACHE
	--------------------------------------------------------------------------

	local cached = source.central_cache[key]

	if cached then
		callback(cached, nil)
		return
	end

	--------------------------------------------------------------------------
	-- 2. REQUEST ALREADY RUNNING
	--
	-- Check this before touching disk so repeated completion requests do not
	-- repeatedly read the same cache file while a network request is running.
	--------------------------------------------------------------------------

	local running = source.central_inflight[key]

	if running then
		table.insert(running, callback)
		return
	end

	--------------------------------------------------------------------------
	-- 3. PERSISTENT CACHE
	--------------------------------------------------------------------------

	local fingerprint = request_fingerprint(source, args)

	local persisted, cache_status = DiskCache.get(
		source.opts.cache,
		"central",
		fingerprint
	)

	if persisted then
		source.central_cache[key] = persisted

		debug_log(
			source,
			"Central cache hit %s",
			query_label(args)
		)

		callback(persisted, nil)
		return
	end

	if cache_status == "stale" then
		debug_log(
			source,
			"Central cache stale %s",
			query_label(args)
		)
	end

	--------------------------------------------------------------------------
	-- 4. MAVEN CENTRAL
	--------------------------------------------------------------------------

	source.central_inflight[key] = { callback }

	debug_log(
		source,
		"Central request %s",
		query_label(args)
	)

	run_query(source, args, function(data, err)
		local docs = {}

		if not err and data and data.response then
			docs = Util.dedupe_docs(data.response.docs or {})

			------------------------------------------------------------------
			-- Truncation warning
			--
			-- Callers size their rows for the whole result set. If Solr has
			-- more than we asked for, the answer is incomplete and whatever
			-- the user is looking for may simply not be in it.
			------------------------------------------------------------------

			local total = data.response.numFound

			if type(total) == "number" and #docs < total then
				debug_log(
					source,
					"Central truncated %s: %d of %d",
					query_label(args),
					#docs,
					total
				)
			end

			------------------------------------------------------------------
			-- Session cache
			------------------------------------------------------------------

			source.central_cache[key] = docs

			------------------------------------------------------------------
			-- Persistent cache
			--
			-- Disk failures are intentionally non-fatal. Persistent caching is
			-- an optimization and must never break dependency completion.
			------------------------------------------------------------------

			local written, write_err = DiskCache.set(
				source.opts.cache,
				"central",
				fingerprint,
				docs
			)

			if not written and write_err ~= "disabled" then
				debug_log(
					source,
					"Central cache write failed: %s",
					write_err or "unknown error"
				)
			end
		end

		local waiters = source.central_inflight[key] or {}

		source.central_inflight[key] = nil

		for _, waiter in ipairs(waiters) do
			waiter(docs, err)
		end
	end)
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS / TESTS
--------------------------------------------------------------------------------

function M.debug_request_fingerprint(source, args)
	return request_fingerprint(source, args)
end

function M.debug_request_spec(source, args)
	return request_spec(source, args)
end

return M
