local Http = require("blink_deps.http")
local Pipeline = require("blink_deps.pipeline")
local Util = require("blink_deps.util")
local Worker = require("blink_deps.worker")

--------------------------------------------------------------------------------
-- NPM REGISTRY
--
-- The npm registry, or anything speaking its protocol: Verdaccio,
-- Artifactory, GitHub Packages.
--
-- Three endpoints are used, each for what it is good at:
--
--   /-/v1/search?text=...   Search by text.
--
--   /<package>              Every version of one package. Requested in the
--                           abbreviated form npm itself installs from; the
--                           full document carries every README ever
--                           published.
--
--   /<package>/latest       The current release alone, about two kilobytes.
--                           Used to check whether a typed name exists
--                           without fetching all of its versions.
--
-- Measured against registry.npmjs.org:
--
--   Even abbreviated, a popular package is large: 2.9 MB for react, 8.7 MB
--   for typescript, because nightly builds are published as versions. The
--   transfer is compressed (1.2 MB and 1.6 MB on the wire), the document is
--   decoded off the main thread, and only version numbers are kept.
--
--   Search matches whole words. "reac" does not find react and "lodas" does
--   not find lodash; "react" and "lodash" do. Nothing in this API finds a
--   package from the beginning of a word, so name completion becomes useful
--   once a word of the name is complete.
--
-- Nothing here knows about package.json. It answers questions about
-- packages.
--------------------------------------------------------------------------------

local M = {}

M.REGISTRY_URL = "https://registry.npmjs.org"

M.HTTP_CONNECT_TIMEOUT = 3

-- Longer than elsewhere: one response can be several megabytes.
M.HTTP_MAX_TIME = 15

M.SEARCH_ROWS = 50

-- What npm sends: the abbreviated document, or the full one from a registry
-- that has no abbreviated form.
M.ACCEPT = "application/vnd.npm.install-v1+json; q=1.0, application/json; q=0.8, */*"

-- A document at least this large is decoded on a worker thread. Decoding
-- 8.7 MB took 41 ms, long enough to notice while typing; below a few hundred
-- kilobytes it takes less than handing the text to another thread would.
M.ASYNC_DECODE_BYTES = 256 * 1024

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local function config(source)
	local configured = source.opts and source.opts.npm

	if type(configured) == "table" then
		return configured
	end

	return {}
end

function M.is_enabled(source)
	return config(source).enabled ~= false
end

local function registry_url(source)
	return ((config(source).registry_url or M.REGISTRY_URL):gsub("/+$", ""))
end

--------------------------------------------------------------------------------
-- PACKAGE NAMES
--
-- name or @scope/name. Anything else is not a package name, which also
-- keeps arbitrary text out of the URL.
--------------------------------------------------------------------------------

local PART = "[%w%-_~][%w%-%._~]*"

function M.is_package_name(name)
	if type(name) ~= "string" or #name > 214 then
		return false
	end

	return name:match("^" .. PART .. "$") ~= nil
		or name:match("^@" .. PART .. "/" .. PART .. "$") ~= nil
end

-- The path of a package under the registry root. The slash of a scoped
-- name is encoded, as npm encodes it: registries other than npmjs.org
-- route on it.
local function package_path(name)
	return (name:gsub("/", "%%2f"))
end

--------------------------------------------------------------------------------
-- PACKAGE DOCUMENTS
--
-- Reduces a package document to what completion needs:
--
--   { versions = { "1.0.0", ... },      every published version
--     deprecated = { "0.9.0", ... },    the ones marked as deprecated
--     tags = { latest = "1.0.0" } }     dist-tags
--
-- The lists are in text order, so the same document always reduces to the
-- same value; ordering versions properly is left to whoever shows them.
--
-- The reduction runs on a worker thread for a large document. A worker has
-- a Lua state of its own and only text may cross to and from it, so the
-- function below takes text, returns text, and refers to nothing outside
-- itself: no upvalues and no modules of the plugin, only what Neovim
-- provides in every state. A result starting with ! is a failure.
--------------------------------------------------------------------------------

local function reduce_encoded(body)
	local ok, document = pcall(vim.json.decode, body)

	if not ok or type(document) ~= "table" then
		return "!invalid JSON"
	end

	if type(document.versions) ~= "table" then
		return "!not a package document"
	end

	local versions = {}
	local deprecated = {}

	for version, manifest in pairs(document.versions) do
		if type(version) == "string" and version ~= "" then
			versions[#versions + 1] = version

			if type(manifest) == "table"
				and type(manifest.deprecated) == "string"
				and manifest.deprecated ~= ""
			then
				deprecated[#deprecated + 1] = version
			end
		end
	end

	local tags = {}

	if type(document["dist-tags"]) == "table" then
		for tag, version in pairs(document["dist-tags"]) do
			if type(tag) == "string" and type(version) == "string" then
				tags[#tags + 1] = { tag, version }
			end
		end
	end

	table.sort(versions)
	table.sort(deprecated)

	-- Lists throughout: an empty Lua table cannot say whether it is a list
	-- or an object, and the two do not survive encoding the same way.
	return vim.json.encode({ versions, deprecated, tags })
end

local function decode_reduced(encoded)
	if type(encoded) ~= "string" then
		return nil, "decoding failed"
	end

	if encoded:sub(1, 1) == "!" then
		return nil, encoded:sub(2)
	end

	local parts = vim.json.decode(encoded)
	local tags = {}

	for _, pair in ipairs(parts[3] or {}) do
		tags[pair[1]] = pair[2]
	end

	return {
		versions = parts[1] or {},
		deprecated = parts[2] or {},
		tags = tags,
	}, nil
end

-- Returns the reduced document, or nil and a message for something that is
-- not a package document.
function M.reduce(body)
	return decode_reduced(reduce_encoded(body))
end

-- callback(reduced, err), on the main loop.
local function reduce_async(body, callback)
	if #body < M.ASYNC_DECODE_BYTES then
		callback(M.reduce(body))
		return
	end

	Worker.run(reduce_encoded, body, function(encoded)
		callback(decode_reduced(encoded))
	end)
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

local function pipeline(source, kind)
	local field = "npm_" .. kind .. "_pipeline"

	if not source[field] then
		source[field] = Pipeline.new({
			name = "npm-" .. kind,
		})
	end

	return source[field]
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- package is { name }, with its scope: "@types/node".
-- callback(versions, err) where versions is a list of
-- { value, timestamp, deprecated, tags }. deprecated is true for a version
-- its publisher has marked so; tags lists the dist-tags pointing at a
-- version, such as latest or next.
--
-- A package that does not exist is an empty list, not an error.
--------------------------------------------------------------------------------

local function to_versions(reduced)
	local deprecated = Util.list_to_set(reduced.deprecated)
	local tags = {}

	for tag, version in pairs(reduced.tags) do
		tags[version] = tags[version] or {}
		table.insert(tags[version], tag)
	end

	local versions = {}

	for _, value in ipairs(reduced.versions) do
		local entry = {
			value = value,
			timestamp = 0,
		}

		if deprecated[value] then
			entry.deprecated = true
		end

		if tags[value] then
			table.sort(tags[value])
			entry.tags = tags[value]
		end

		table.insert(versions, entry)
	end

	return versions
end

function M.versions(source, package, callback)
	local name = package.name

	if not M.is_package_name(name) then
		callback({}, nil)
		return
	end

	local url = registry_url(source) .. "/" .. package_path(name)

	pipeline(source, "versions"):fetch({
		key = url,

		disk = function()
			return {
				opts = source.opts.cache,
				namespace = "npm-versions",
				key = vim.fn.sha256(url),
			}
		end,

		fetch = function(done)
			request(source, {
				url = url,
				compressed = true,
				headers = {
					Accept = M.ACCEPT,
				},
			}, function(body, err)
				if err then
					if err.kind == "not_found" then
						done({}, nil)
						return
					end

					done(nil, err.message)
					return
				end

				reduce_async(body, function(reduced, reduce_err)
					if not reduced then
						done(nil, "malformed npm response: " .. tostring(reduce_err))
						return
					end

					done(to_versions(reduced), nil)
				end)
			end)
		end,
	}, function(versions, err)
		callback(versions or {}, err)
	end)
end

--------------------------------------------------------------------------------
-- SEARCH
--
-- callback(packages, err) where packages is a list of
-- { name, latest_version, description, downloads }, the most downloaded
-- first. downloads is the weekly figure.
--
-- The registry orders results by its own relevance score, which rewards a
-- name that is exactly the search text and little else. Ordered by
-- downloads, the same results put the package most people mean on top:
-- "express" gives express and express-rate-limit before the long tail of
-- packages that merely mention it.
--
-- A typed name is also looked up directly, so a package that exists is
-- offered even when the search does not rank it.
--------------------------------------------------------------------------------

function M.search_spec(source, text)
	return {
		url = registry_url(source) .. "/-/v1/search",
		query = {
			text = text,
			size = M.SEARCH_ROWS,
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
				namespace = "npm-search",
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
				if type(data.objects) ~= "table" then
					done(nil, "malformed npm response")
					return
				end

				local packages = {}

				for position, object in ipairs(data.objects) do
					local package = type(object) == "table" and object.package

					local name = type(package) == "table" and text_or_nil(package.name)

					if name then
						local downloads = type(object.downloads) == "table"
							and object.downloads.weekly

						table.insert(packages, {
							name = name,
							latest_version = text_or_nil(package.version),
							description = text_or_nil(package.description),
							downloads = type(downloads) == "number" and downloads or nil,
							position = position,
						})
					end
				end

				-- By downloads; the registry's own order settles ties, so
				-- the result is the same on every run.
				table.sort(packages, function(left, right)
					local left_downloads = left.downloads or -1
					local right_downloads = right.downloads or -1

					if left_downloads ~= right_downloads then
						return left_downloads > right_downloads
					end

					return left.position < right.position
				end)

				for _, package in ipairs(packages) do
					package.position = nil
				end

				done(packages, nil)
			end)
		end,
	}, function(packages, err)
		callback(packages or {}, err)
	end)
end

-- The package named exactly text, or nil. A failed lookup is nil too: this
-- only ever adds to a search, it must not fail one.
local function exact_package(source, text, callback)
	if not M.is_package_name(text) then
		callback(nil)
		return
	end

	local url = registry_url(source) .. "/" .. package_path(text) .. "/latest"

	pipeline(source, "latest"):fetch({
		key = url,

		fetch = function(done)
			request(source, {
				url = url,
				decode = "json",
			}, function(manifest, err)
				if err then
					if err.kind == "not_found" then
						-- A table, so that "no such package" is remembered
						-- for the session like any other answer.
						done({ missing = true }, nil)
						return
					end

					done(nil, err.message)
					return
				end

				done({
					name = text_or_nil(manifest.name) or text,
					latest_version = text_or_nil(manifest.version),
					description = text_or_nil(manifest.description),
				}, nil)
			end)
		end,
	}, function(package)
		if not package or package.missing then
			callback(nil)
			return
		end

		callback(vim.deepcopy(package))
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
			-- The search knows more about the package: its downloads.
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

	exact_package(source, text, function(package)
		exact = package

		finish()
	end)
end

--------------------------------------------------------------------------------
-- REGISTRY
--
-- The npm registry as seen through the contract in blink_deps.registries.
--------------------------------------------------------------------------------

M.REGISTRY = {
	id = "npm",
	name = "npm",
	kind = "npm",

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
