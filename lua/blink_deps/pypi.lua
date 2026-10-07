local Http = require("blink_deps.http")
local Pep440 = require("blink_deps.pep440")
local Pep508 = require("blink_deps.pep508")
local Pipeline = require("blink_deps.pipeline")
local Worker = require("blink_deps.worker")

--------------------------------------------------------------------------------
-- PYPI
--
-- The Python Package Index, or any index speaking the same protocol:
-- devpi, Artifactory, AWS CodeArtifact.
--
-- One endpoint is used, the standard "simple" index in its JSON form:
--
--   /simple/<project>/     Accept: application/vnd.pypi.simple.v1+json
--
-- It lists every file of a project, and since version 1.1 of the API its
-- versions too. This is what pip itself reads, and the only protocol other
-- indexes are required to implement; PyPI's older /pypi/<project>/json is
-- its own and is not used.
--
-- Measured against pypi.org:
--
--   A project page lists files, not versions, and a project with many
--   wheels per release is large: 2.8 MB for numpy, 4232 files for 137
--   versions. The transfer is compressed (470 KB on the wire), the page is
--   reduced on a worker thread, and only versions are kept.
--
--   A name that is not in normalised form is answered with a redirect, so
--   names are normalised before they are requested.
--
--   There is no search. PyPI has no API to find a project from part of its
--   name, so the only question that can be put to it is whether a project
--   with exactly this name exists.
--
-- Nothing here knows about requirements files. It answers questions about
-- projects.
--------------------------------------------------------------------------------

local M = {}

M.INDEX_URL = "https://pypi.org/simple"

M.HTTP_CONNECT_TIMEOUT = 3

-- Longer than elsewhere: one page can be several megabytes.
M.HTTP_MAX_TIME = 15

M.ACCEPT = "application/vnd.pypi.simple.v1+json"

-- A page at least this large is reduced on a worker thread.
M.ASYNC_BYTES = 256 * 1024

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local function config(source)
	local configured = source.opts and source.opts.pypi

	if type(configured) == "table" then
		return configured
	end

	return {}
end

function M.is_enabled(source)
	return config(source).enabled ~= false
end

local function index_url(source)
	return ((config(source).index_url or M.INDEX_URL):gsub("/+$", ""))
end

--------------------------------------------------------------------------------
-- PROJECT NAMES
--
-- Letters and digits, with single - _ . between them. Returned in the form
-- an index files it under, or nil for something that cannot be a project
-- name, which also keeps arbitrary text out of the URL.
--------------------------------------------------------------------------------

function M.project_path(name)
	if type(name) ~= "string" or not name:match("^%w[%w._-]*$") or not name:match("%w$") then
		return nil
	end

	return Pep508.normalize(name)
end

--------------------------------------------------------------------------------
-- PROJECT PAGES
--
-- Reduces a project page to one line per version:
--
--   <version> TAB <1 if yanked, else 0> TAB <date first published, or empty>
--
-- preceded by a line holding the project's name.
--
-- A version is yanked when every one of its files is. The page says which
-- version a file belongs to only through its name:
--
--   requests-2.31.0-py3-none-any.whl     a wheel: the second field
--   requests-2.31.0.tar.gz               a source archive: after the last -
--
-- Runs on a worker thread, so it is self-contained. A result starting with
-- ! is a failure.
--------------------------------------------------------------------------------

local function reduce_page(body)
	local ok, page = pcall(vim.json.decode, body)

	if not ok or type(page) ~= "table" then
		return "!not JSON"
	end

	if type(page.files) ~= "table" then
		return "!not a project page"
	end

	local function version_of(filename)
		if type(filename) ~= "string" then
			return nil
		end

		if filename:sub(-4) == ".whl" then
			return filename:match("^[^-]+%-([^-]+)%-")
		end

		local stem = filename
			:gsub("%.tar%.[%w]+$", "")
			:gsub("%.tgz$", "")
			:gsub("%.zip$", "")
			:gsub("%.egg$", "")
			:gsub("%.exe$", "")
			:gsub("%.msi$", "")

		return stem:match(".*%-(%d[^-]*)$")
	end

	local order = {}
	local known = {}

	local function entry_for(version)
		local entry = known[version]

		if not entry then
			entry = { files = 0, yanked = 0 }
			known[version] = entry
			order[#order + 1] = version
		end

		return entry
	end

	-- Since API 1.1 the page names its versions. Before that, they are
	-- whatever the files say.
	if type(page.versions) == "table" then
		for _, version in ipairs(page.versions) do
			if type(version) == "string" and version ~= "" then
				entry_for(version)
			end
		end
	end

	local listed = #order > 0

	for _, file in ipairs(page.files) do
		if type(file) == "table" then
			local version = version_of(file.filename)

			if version and (known[version] or not listed) then
				local entry = entry_for(version)

				entry.files = entry.files + 1

				-- yanked is false, true, or the reason as text.
				if file.yanked ~= nil and file.yanked ~= false then
					entry.yanked = entry.yanked + 1
				end

				local uploaded = type(file["upload-time"]) == "string"
					and file["upload-time"]:match("^%d%d%d%d%-%d%d%-%d%d")

				if uploaded and (not entry.published or uploaded < entry.published) then
					entry.published = uploaded
				end
			end
		end
	end

	local name = type(page.name) == "string" and page.name or ""

	local lines = { (name:gsub("[\t\n]", "")) }

	for _, version in ipairs(order) do
		local entry = known[version]

		if not version:find("[\t\n]") then
			lines[#lines + 1] = version
				.. "\t"
				.. ((entry.files > 0 and entry.yanked == entry.files) and "1" or "0")
				.. "\t"
				.. (entry.published or "")
		end
	end

	return table.concat(lines, "\n")
end

-- A reduced page as { name, versions }, each version being
-- { value, yanked, published }, or nil and a message.
function M.parse(reduced)
	if type(reduced) ~= "string" then
		return nil, "unreadable"
	end

	if reduced:sub(1, 1) == "!" then
		return nil, reduced:sub(2)
	end

	local name, rest = reduced:match("^([^\n]*)\n?(.*)$")

	local versions = {}

	for line in rest:gmatch("[^\n]+") do
		local value, yanked, published = line:match("^([^\t]+)\t([01])\t(.*)$")

		if value then
			table.insert(versions, {
				value = value,
				yanked = yanked == "1" or nil,
				published = published ~= "" and published or nil,
			})
		end
	end

	return {
		name = name ~= "" and name or nil,
		versions = versions,
	}, nil
end

-- For tests: reduce and parse in one go, on the calling thread.
function M.read(body)
	return M.parse(reduce_page(body))
end

local function reduce_async(body, callback)
	if #body < M.ASYNC_BYTES then
		callback(M.read(body))
		return
	end

	Worker.run(reduce_page, body, function(reduced)
		callback(M.parse(reduced))
	end)
end

--------------------------------------------------------------------------------
-- PROJECT
--
-- callback(project, err) where project is { name, versions }; versions is
-- empty for a project that does not exist, which is not an error.
--------------------------------------------------------------------------------

local function pipeline(source)
	if not source.pypi_pipeline then
		source.pypi_pipeline = Pipeline.new({
			name = "pypi",
		})
	end

	return source.pypi_pipeline
end

function M.project(source, name, callback)
	local path = M.project_path(name)

	if not path then
		callback({ versions = {} }, nil)
		return
	end

	local url = index_url(source) .. "/" .. path .. "/"

	pipeline(source):fetch({
		key = url,

		disk = function()
			return {
				opts = source.opts.cache,
				namespace = "pypi",
				key = vim.fn.sha256(url),
			}
		end,

		fetch = function(done)
			local spec = {
				url = url,
				compressed = true,
				headers = {
					Accept = M.ACCEPT,
				},
				connect_timeout = source.opts.connect_timeout or M.HTTP_CONNECT_TIMEOUT,
				max_time = source.opts.max_time or M.HTTP_MAX_TIME,
			}

			if type(source.opts.retries) == "number" then
				spec.retries = math.max(source.opts.retries, 0)
			end

			Http.request(spec, function(body, err)
				if err then
					if err.kind == "not_found" then
						done({ versions = {} }, nil)
						return
					end

					done(nil, err.message)
					return
				end

				reduce_async(body, function(project, reduce_err)
					if not project then
						-- An index that only serves the HTML form of
						-- the simple API answers with a page of links.
						done(nil, "unreadable index response: " .. tostring(reduce_err))
						return
					end

					done(project, nil)
				end)
			end)
		end,
	}, function(project, err)
		callback(project or { versions = {} }, err)
	end)
end

--------------------------------------------------------------------------------
-- VERSIONS
--
-- package is { name }.
-- callback(versions, err) where versions is a list of
-- { value, timestamp, yanked, published }. published is the date of the
-- first upload, as YYYY-MM-DD.
--------------------------------------------------------------------------------

function M.versions(source, package, callback)
	M.project(source, package.name, function(project, err)
		local versions = {}

		for _, version in ipairs(project.versions) do
			table.insert(versions, {
				value = version.value,
				timestamp = 0,
				yanked = version.yanked,
				published = version.published,
			})
		end

		callback(versions, err)
	end)
end

--------------------------------------------------------------------------------
-- SEARCH
--
-- callback(packages, err) with at most one package: the project named
-- exactly text, as { name, latest_version }, if there is one.
--
-- latest_version is what pip would install: the newest release that is
-- neither yanked nor a prerelease, or failing that the newest that is not
-- yanked.
--------------------------------------------------------------------------------

local function newest(versions, acceptable)
	local best

	for _, version in ipairs(versions) do
		if acceptable(version)
			and (not best or Pep440.compare(version.value, best.value) > 0)
		then
			best = version
		end
	end

	return best
end

function M.current_release(versions)
	return newest(versions, function(version)
		return not version.yanked and not Pep440.is_prerelease(version.value)
	end) or newest(versions, function(version)
		return not version.yanked
	end) or newest(versions, function()
		return true
	end)
end

function M.search_packages(source, text, callback)
	text = vim.trim(text or "")

	if not M.project_path(text) then
		callback({}, nil)
		return
	end

	M.project(source, text, function(project, err)
		local release = M.current_release(project.versions)

		if not release then
			callback({}, err)
			return
		end

		callback({
			{
				name = project.name or Pep508.normalize(text),
				latest_version = release.value,
			},
		}, nil)
	end)
end

--------------------------------------------------------------------------------
-- REGISTRY
--
-- PyPI as seen through the contract in blink_deps.registries.
--------------------------------------------------------------------------------

M.REGISTRY = {
	id = "pypi",
	name = "PyPI",
	kind = "pypi",

	-- The ecosystem's public default index.
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
