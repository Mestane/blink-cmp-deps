local Util = require("blink_deps.util")
local DiskCache = require("blink_deps.disk_cache")
local VERSION = require("blink_deps.version")

local M = {}

M.URL = "https://central.sonatype.com/solrsearch/select"
M.HTTP_CONNECT_TIMEOUT = 3
M.HTTP_MAX_TIME = 7

--------------------------------------------------------------------------------
-- DEBUG
--------------------------------------------------------------------------------

local function debug_log(source, fmt, ...)
	if not source.opts.debug then
		return
	end

	local message = string.format(fmt, ...)

	vim.schedule(function()
		vim.notify("[blink-cmp-deps] " .. message, vim.log.levels.DEBUG)
	end)
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
--------------------------------------------------------------------------------

local function run_query(source, args, callback)
	local cmd = {
		"curl",
		"-sS",
		"--fail-with-body",
		"--connect-timeout",
		tostring(source.opts.connect_timeout or M.HTTP_CONNECT_TIMEOUT),
		"--max-time",
		tostring(source.opts.max_time or M.HTTP_MAX_TIME),
		"-A",
		"blink-cmp-deps/" .. VERSION,
		"--get",
		source.opts.central_url or M.URL,
	}

	for key, value in pairs(args) do
		table.insert(cmd, "--data-urlencode")
		table.insert(cmd, key .. "=" .. tostring(value))
	end

	vim.system(cmd, { text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				callback(nil, Util.trim(result.stderr or "curl failed"))
				return
			end

			local ok, decoded = pcall(vim.json.decode, result.stdout or "")

			if not ok or type(decoded) ~= "table" then
				callback(nil, "invalid JSON")
				return
			end

			callback(decoded, nil)
		end)
	end)
end

--------------------------------------------------------------------------------
-- SEARCH
--------------------------------------------------------------------------------

function M.search(source, key, args, callback)
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
			args.q or ""
		)

		callback(persisted, nil)
		return
	end

	if cache_status == "stale" then
		debug_log(
			source,
			"Central cache stale %s",
			args.q or ""
		)
	end

	--------------------------------------------------------------------------
	-- 4. MAVEN CENTRAL
	--------------------------------------------------------------------------

	source.central_inflight[key] = { callback }

	debug_log(
		source,
		"Central request %s",
		args.q or ""
	)

	run_query(source, args, function(data, err)
		local docs = {}

		if not err and data and data.response then
			docs = Util.dedupe_docs(data.response.docs or {})

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

return M
