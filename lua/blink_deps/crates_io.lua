local Http = require("blink_deps.http")
local Pipeline = require("blink_deps.pipeline")
local Util = require("blink_deps.util")

--------------------------------------------------------------------------------
-- CRATES.IO
--
-- crates.io is reached through two different services, and each is used for
-- what it is good at:
--
--   the web API      https://crates.io/api/v1/crates?q=...
--                    Search by text. Rate limited, so it is only used for
--                    search, behind the completion debounce.
--
--   the sparse index https://index.crates.io/se/rd/serde
--                    Every published version of one crate, as one JSON object
--                    per line. This is what cargo itself reads. It is served
--                    from a CDN without a rate limit, and it is the protocol
--                    alternate registries speak too.
--
-- Nothing here knows about Cargo.toml. It answers questions about crates.
--------------------------------------------------------------------------------

local M = {}

M.API_URL = "https://crates.io"
M.INDEX_URL = "https://index.crates.io"

M.HTTP_CONNECT_TIMEOUT = 3
M.HTTP_MAX_TIME = 5
M.SEARCH_ROWS = 50

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local function config(source)
	local configured = source.opts and source.opts.crates_io

	if type(configured) == "table" then
		return configured
	end

	return {}
end

function M.is_enabled(source)
	return config(source).enabled ~= false
end

local function trim_slash(value)
	return (value:gsub("/+$", ""))
end

local function api_url(source)
	return trim_slash(config(source).api_url or M.API_URL)
end

local function index_url(source)
	return trim_slash(config(source).index_url or M.INDEX_URL)
end

--------------------------------------------------------------------------------
-- INDEX PATHS
--
-- The index spreads crates over directories by name length, so that no
-- directory grows unbounded:
--
--   a        1/a
--   ab       2/ab
--   abc      3/a/abc
--   serde    se/rd/serde
--
-- Names are lowercased in the path. Returns nil for something that cannot be
-- a crate name, which also keeps arbitrary text out of the URL.
--------------------------------------------------------------------------------

function M.index_path(name)
	if type(name) ~= "string" or not name:match("^[%w_%-]+$") then
		return nil
	end

	local lowered = name:lower()
	local length = #lowered

	if length == 1 then
		return "1/" .. lowered
	end

	if length == 2 then
		return "2/" .. lowered
	end

	if length == 3 then
		return "3/" .. lowered:sub(1, 1) .. "/" .. lowered
	end

	return lowered:sub(1, 2) .. "/" .. lowered:sub(3, 4) .. "/" .. lowered
end

--------------------------------------------------------------------------------
-- INDEX ENTRIES
--
-- One line per published version. A line that cannot be read is skipped: one
-- damaged entry must not hide every other version of the crate.
--
-- Features come from two fields. features2 was added for syntax that older
-- versions of cargo could not parse, and holds entries of the same kind.
--------------------------------------------------------------------------------

function M.parse_index(body)
	local entries = {}

	for line in (body or ""):gmatch("[^\n]+") do
		local ok, decoded = pcall(vim.json.decode, line)

		if ok
			and type(decoded) == "table"
			and type(decoded.vers) == "string"
			and decoded.vers ~= ""
		then
			local features = {}

			for _, field in ipairs({ "features", "features2" }) do
				if type(decoded[field]) == "table" then
					for feature in pairs(decoded[field]) do
						if type(feature) == "string" then
							features[feature] = true
						end
					end
				end
			end

			table.insert(entries, {
				value = decoded.vers,
				yanked = decoded.yanked == true,
				features = Util.sorted_keys(features),
			})
		end
	end

	return entries
end

--------------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------------

local function request(source, spec, callback)
	spec.connect_timeout =
		source.opts.connect_timeout or M.HTTP_CONNECT_TIMEOUT

	spec.max_time = source.opts.max_time or M.HTTP_MAX_TIME

	if type(source.opts.retries) == "number" then
		spec.retries = math.max(source.opts.retries, 0)
	end

	return Http.request(spec, callback)
end

--------------------------------------------------------------------------------
-- PIPELINES
--
-- Search results and index entries are different lookups with different
-- keys, so each has its own cache.
--------------------------------------------------------------------------------

local function pipeline(source, kind)
	local field = "crates_io_" .. kind .. "_pipeline"

	if not source[field] then
		source[field] = Pipeline.new({
			name = "crates-io-" .. kind,
		})
	end

	return source[field]
end

--------------------------------------------------------------------------------
-- INDEX
--
-- callback(entries, err) where entries is a list of
-- { value, yanked, features }, oldest first as the index stores them.
--
-- A crate that does not exist is an empty list, not an error: the name was
-- simply not a crate, and nothing went wrong.
--------------------------------------------------------------------------------

function M.index(source, name, callback)
	local path = M.index_path(name)

	if not path then
		callback({}, nil)
		return
	end

	local url = index_url(source) .. "/" .. path

	pipeline(source, "index"):fetch({
		key = url,

		disk = function()
			return {
				opts = source.opts.cache,
				namespace = "crates-index",
				key = vim.fn.sha256(url),
			}
		end,

		fetch = function(done)
			request(source, { url = url }, function(body, err)
				if err then
					if err.kind == "not_found" then
						done({}, nil)
						return
					end

					done(nil, err.message)
					return
				end

				done(M.parse_index(body), nil)
			end)
		end,
	}, function(entries, err)
		callback(entries or {}, err)
	end)
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- package is { name }.
-- callback(versions, err) where versions is a list of
-- { value, timestamp, yanked }. The index records no publication time.
--------------------------------------------------------------------------------

function M.versions(source, package, callback)
	M.index(source, package.name, function(entries, err)
		local versions = {}

		for _, entry in ipairs(entries) do
			table.insert(versions, {
				value = entry.value,
				timestamp = 0,
				yanked = entry.yanked or nil,
			})
		end

		callback(versions, err)
	end)
end

--------------------------------------------------------------------------------
-- SEARCH
--
-- callback(packages, err) where packages is a list of
-- { name, latest_version, description, downloads }, in the order crates.io
-- ranks them.
--------------------------------------------------------------------------------

function M.search_spec(source, text)
	return {
		url = api_url(source) .. "/api/v1/crates",
		query = {
			q = text,
			per_page = M.SEARCH_ROWS,
		},
		decode = "json",
	}
end

local function text_or_nil(value)
	if type(value) == "string" and value ~= "" then
		return value
	end

	return nil
end

function M.search_packages(source, text, callback)
	text = Util.trim(text)

	if text == "" then
		callback({}, nil)
		return
	end

	local spec = M.search_spec(source, text)
	local key = spec.url .. "\n" .. Util.lower(text)

	pipeline(source, "search"):fetch({
		key = key,

		disk = function()
			return {
				opts = source.opts.cache,
				namespace = "crates-search",
				key = vim.fn.sha256(key),
			}
		end,

		fetch = function(done)
			request(source, spec, function(data, err)
				if err then
					done(nil, err.message)
					return
				end

				-- Valid JSON that is not a search result is an outage,
				-- not "no matches".
				if type(data.crates) ~= "table" then
					done(nil, "malformed crates.io response")
					return
				end

				local packages = {}

				for _, crate in ipairs(data.crates) do
					local name = type(crate) == "table"
						and text_or_nil(crate.name or crate.id)

					if name then
						table.insert(packages, {
							name = name,

							-- The newest release that is not a prerelease,
							-- when the crate has one.
							latest_version = text_or_nil(crate.max_stable_version)
								or text_or_nil(crate.max_version)
								or text_or_nil(crate.newest_version),

							description = text_or_nil(crate.description),

							downloads = type(crate.downloads) == "number"
								and crate.downloads
								or nil,
						})
					end
				end

				done(packages, nil)
			end)
		end,
	}, function(packages, err)
		callback(packages or {}, err)
	end)
end

--------------------------------------------------------------------------------
-- REGISTRY
--
-- crates.io as seen through the contract in blink_deps.registries.
--------------------------------------------------------------------------------

M.REGISTRY = {
	id = "crates-io",
	name = "crates.io",
	kind = "crates-io",

	-- The ecosystem's public default registry.
	public = true,

	capabilities = {
		versions = true,
		search = true,
	},

	versions = function(_, source, package, callback)
		M.versions(source, package, callback)
	end,

	search = function(_, source, text, callback)
		M.search_packages(source, text, callback)
	end,
}

return M
