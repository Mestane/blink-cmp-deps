local Util = require("blink_deps.util")
local DiskCache = require("blink_deps.disk_cache")
local Http = require("blink_deps.http")
local Pipeline = require("blink_deps.pipeline")

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
-- PIPELINE
--
-- Memory, request sharing and persistence live in blink_deps.pipeline. The
-- source keeps owning the two tables so its cache survives for the session.
--------------------------------------------------------------------------------

local function pipeline(source)
	local existing = source.central_pipeline

	-- Rebuilt if the source's tables were replaced underneath it.
	if existing
		and existing.memory == source.central_cache
		and existing.inflight == source.central_inflight
	then
		return existing
	end

	source.central_cache = source.central_cache or {}
	source.central_inflight = source.central_inflight or {}

	source.central_pipeline = Pipeline.new({
		name = "central",
		memory = source.central_cache,
		inflight = source.central_inflight,
	})

	return source.central_pipeline
end

--------------------------------------------------------------------------------
-- SEARCH
--------------------------------------------------------------------------------

local function fetch_docs(source, args, done)
	debug_log(
		source,
		"Central request %s",
		query_label(args)
	)

	run_query(source, args, function(data, err)
		if err then
			done(nil, err)
			return
		end

		-- Valid JSON that is not a Solr result is a failure. Treating it
		-- as "no matches" would hide an outage behind an empty menu.
		if type(data.response) ~= "table" then
			done(nil, "malformed Central response")
			return
		end

		local docs = Util.dedupe_docs(data.response.docs or {})

		----------------------------------------------------------------------
		-- Truncation warning
		--
		-- Callers size their rows for the whole result set. If Solr has
		-- more than we asked for, the answer is incomplete and whatever
		-- the user is looking for may simply not be in it.
		----------------------------------------------------------------------

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

		done(docs, nil)
	end)
end

function M.search(source, key, args, callback)
	if not enabled(source) then
		callback({}, nil)
		return
	end

	pipeline(source):fetch({
		key = key,

		-- Deferred: the fingerprint is a hash, and a memory hit on the
		-- completion hot path has no use for it.
		disk = function()
			return {
				opts = source.opts.cache,
				namespace = "central",
				key = request_fingerprint(source, args),
			}
		end,

		fetch = function(done)
			fetch_docs(source, args, done)
		end,

		on_event = function(event, detail)
			if event == "stale" then
				debug_log(
					source,
					"Central cache stale %s",
					query_label(args)
				)
			elseif event == "write_failed" then
				debug_log(
					source,
					"Central cache write failed: %s",
					detail or "unknown error"
				)
			end
		end,
	}, function(docs, err, origin)
		if origin == "disk" then
			debug_log(
				source,
				"Central cache hit %s",
				query_label(args)
			)
		end

		-- Callers iterate the result without checking it, so a failure
		-- is an empty list alongside the error.
		callback(docs or {}, err)
	end)
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- package is the ecosystem neutral shape { namespace, name }. For Maven that
-- is the groupId and the artifactId.
--
-- callback(versions, err) where versions is a list of { value, timestamp }.
--------------------------------------------------------------------------------

M.VERSION_ROWS = 200

function M.versions(source, package, callback)
	local id = package.namespace .. ":" .. package.name

	M.search(
		source,
		"version:" .. id,
		{
			q = "g:" .. package.namespace .. " AND a:" .. package.name,
			core = "gav",
			rows = tostring(M.VERSION_ROWS),
			wt = "json",
		},
		function(docs, err)
			if err then
				callback({}, err)
				return
			end

			local versions = {}

			for _, doc in ipairs(docs or {}) do
				local value = doc.v or doc.latestVersion

				if type(value) == "string" and value ~= "" then
					table.insert(versions, {
						value = value,
						timestamp = tonumber(doc.timestamp) or 0,
					})
				end
			end

			callback(versions, nil)
		end
	)
end

--------------------------------------------------------------------------------
-- REGISTRY
--
-- Maven Central as seen through the contract in blink_deps.registries.
--------------------------------------------------------------------------------

function M.is_enabled(source)
	return enabled(source)
end

M.REGISTRY = {
	id = "central",
	name = "Maven Central",
	kind = "central",

	capabilities = {
		versions = true,
	},

	versions = function(_, source, package, callback)
		M.versions(source, package, callback)
	end,
}

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
