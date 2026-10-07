local Http = require("blink_deps.http")
local Pipeline = require("blink_deps.pipeline")
local Semver = require("blink_deps.semver")
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

			-- Dependencies a feature enables explicitly, as "dep:name".
			local explicit = {}

			for _, field in ipairs({ "features", "features2" }) do
				if type(decoded[field]) == "table" then
					for feature, enables in pairs(decoded[field]) do
						if type(feature) == "string" then
							features[feature] = true
						end

						if type(enables) == "table" then
							for _, enabled in ipairs(enables) do
								if type(enabled) == "string" then
									local dependency = enabled:match("^dep:(.+)$")

									if dependency then
										explicit[dependency] = true
									end
								end
							end
						end
					end
				end
			end

			-- An optional dependency is itself a feature of the same
			-- name, unless some feature names it with dep:, which is how
			-- a crate says the dependency is not to be enabled directly.
			if type(decoded.deps) == "table" then
				for _, dependency in ipairs(decoded.deps) do
					if type(dependency) == "table"
						and dependency.optional == true
						and type(dependency.name) == "string"
						and not explicit[dependency.name]
					then
						features[dependency.name] = true
					end
				end
			end

			table.insert(entries, {
				-- As published. The path it is found under is
				-- lowercased; this is how the crate spells itself.
				name = type(decoded.name) == "string" and decoded.name or nil,
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
-- { name, value, yanked, features }, oldest first as the index stores them.
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
-- CURRENT RELEASE
--
-- The release a new dependency would get: the newest that is neither yanked
-- nor a prerelease, or failing that the newest that is not yanked, or
-- failing that the newest of all.
--------------------------------------------------------------------------------

local function newest(entries, acceptable)
	local best

	for _, entry in ipairs(entries) do
		if acceptable(entry)
			and (not best or Semver.compare(entry.value, best.value) > 0)
		then
			best = entry
		end
	end

	return best
end

local function current_release(entries)
	return newest(entries, function(entry)
		return not entry.yanked and not Semver.is_prerelease(entry.value)
	end) or newest(entries, function(entry)
		return not entry.yanked
	end) or newest(entries, function()
		return true
	end)
end

--------------------------------------------------------------------------------
-- FEATURES
--
-- package is { name }.
-- callback(features, err) where features is a sorted list of names, those
-- of the current release. Features differ from release to release.
--------------------------------------------------------------------------------

function M.features(source, package, callback)
	M.index(source, package.name, function(entries, err)
		local release = current_release(entries)

		callback(vim.deepcopy(release and release.features or {}), err)
	end)
end

--------------------------------------------------------------------------------
-- SEARCH
--
-- callback(packages, err) where packages is a list of
-- { name, latest_version, description, downloads }.
--
-- Completion searches with whatever has been typed so far, which is usually
-- the beginning of a name. Measured against crates.io:
--
--   typed      by relevance (the default)      by downloads
--   tok        tok, late, zernio, ...          tokio, tokio-macros, tokio-util
--   ser        ser, epserde, ...               thiserror, serde, serde_derive
--   serde_js   convert-js, js_like_eq, ...     serde_json, chrono, ...
--
-- Relevance ranks whole word matches, so an unfinished word finds obscure
-- crates. Ordering the same matches by downloads puts the crate the user is
-- most likely typing towards on top.
--
-- What that ordering can lose is a little used crate whose exact name was
-- typed, pushed past the page by more popular matches. So the typed text is
-- also looked up directly in the index, which costs nothing against the rate
-- limit, and an exact hit is put first.
--------------------------------------------------------------------------------

function M.search_spec(source, text)
	return {
		url = api_url(source) .. "/api/v1/crates",
		query = {
			q = text,
			per_page = M.SEARCH_ROWS,
			sort = "downloads",
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

local function search_api(source, text, callback)
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

-- The crate named exactly text, or nil. A failed lookup is nil too: this
-- only ever adds to a search, it must not fail one.
local function exact_crate(source, text, callback)
	if not M.index_path(text) then
		callback(nil)
		return
	end

	M.index(source, text, function(entries)
		local release = current_release(entries)

		if not release then
			callback(nil)
			return
		end

		callback({
			name = release.name or text,
			latest_version = release.value,
		})
	end)
end

function M.search_packages(source, text, callback)
	text = Util.trim(text)

	if text == "" then
		callback({}, nil)
		return
	end

	local pending = 2
	local found
	local found_err
	local exact

	local function finish()
		pending = pending - 1

		if pending > 0 then
			return
		end

		local packages = {}

		if exact then
			-- The search knows more about the crate than the index does.
			for _, package in ipairs(found) do
				if package.name == exact.name then
					exact = package
					break
				end
			end

			table.insert(packages, exact)
		end

		for _, package in ipairs(found) do
			if not exact or package.name ~= exact.name then
				table.insert(packages, package)
			end
		end

		-- An exact hit is an answer even when the search itself failed.
		callback(packages, #packages == 0 and found_err or nil)
	end

	search_api(source, text, function(packages, err)
		found = packages
		found_err = err

		finish()
	end)

	exact_crate(source, text, function(package)
		exact = package

		finish()
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
		features = true,
	},

	features = function(_, source, package, callback)
		M.features(source, package, callback)
	end,

	versions = function(_, source, package, callback)
		M.versions(source, package, callback)
	end,

	search = function(_, source, text, callback)
		M.search_packages(source, text, callback)
	end,
}

return M
