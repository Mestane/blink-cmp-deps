local Http = require("blink_deps.http")
local Pep508 = require("blink_deps.pep508")
local Pipeline = require("blink_deps.pipeline")
local Worker = require("blink_deps.worker")

--------------------------------------------------------------------------------
-- POPULAR PYPI PROJECTS
--
-- PyPI cannot be asked for projects by part of their name, and its full
-- list of 900,000 names carries no measure of which ones matter: 18,301 of
-- them start with "djan".
--
-- This registry answers name searches from a published list of the 15,000
-- most downloaded projects, with their download counts:
--
--   https://github.com/hugovk/top-pypi-packages
--
-- The list is one static file of 172 KB compressed, refreshed monthly by
-- its maintainer. It is downloaded once and searched here, so nothing the
-- user types is sent anywhere: this is the one remote source that learns
-- nothing about what is being looked for.
--
-- It is not PyPI. If the file is unavailable, name completion falls back
-- to what the other registries know, and nothing fails. A project outside
-- the list is found by its exact name through PyPI itself.
--------------------------------------------------------------------------------

local M = {}

M.URL = "https://raw.githubusercontent.com/hugovk/top-pypi-packages/main/top-pypi-packages.min.json"

M.HTTP_CONNECT_TIMEOUT = 3
M.HTTP_MAX_TIME = 15

-- More matches than this are not worth showing; the list is ordered by
-- downloads, so the ones kept are the ones most likely meant.
M.MAX_RESULTS = 50

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local function config(source)
	local configured = source.opts and source.opts.pypi_top

	if type(configured) == "table" then
		return configured
	end

	return {}
end

function M.is_enabled(source)
	return config(source).enabled ~= false
end

local function url(source)
	return config(source).url or M.URL
end

--------------------------------------------------------------------------------
-- THE LIST
--
-- Reduces the published file to one line per project, most downloaded
-- first:
--
--   <name> TAB <downloads>
--
-- Runs on a worker thread, so it is self-contained. A result starting with
-- ! is a failure.
--------------------------------------------------------------------------------

local function reduce_list(body)
	local ok, document = pcall(vim.json.decode, body)

	if not ok or type(document) ~= "table" or type(document.rows) ~= "table" then
		return "!not a project list"
	end

	local lines = {}

	for _, row in ipairs(document.rows) do
		if type(row) == "table"
			and type(row.project) == "string"
			and row.project ~= ""
			and not row.project:find("[\t\n]")
		then
			local downloads = type(row.download_count) == "number"
				and row.download_count
				or 0

			lines[#lines + 1] = row.project .. "\t" .. string.format("%.0f", downloads)
		end
	end

	return table.concat(lines, "\n")
end

-- A reduced list as { { name, key, downloads }, ... }, or nil and a
-- message. key is the name as an index spells it, which is what a search
-- is matched against.
function M.parse(reduced)
	if type(reduced) ~= "string" then
		return nil, "unreadable"
	end

	if reduced:sub(1, 1) == "!" then
		return nil, reduced:sub(2)
	end

	local projects = {}

	for line in reduced:gmatch("[^\n]+") do
		local name, downloads = line:match("^([^\t]+)\t(%d+)$")

		if name then
			table.insert(projects, {
				name = name,
				key = Pep508.normalize(name),
				downloads = tonumber(downloads),
			})
		end
	end

	return projects, nil
end

-- For tests: reduce and parse in one go, on the calling thread.
function M.read(body)
	return M.parse(reduce_list(body))
end

--------------------------------------------------------------------------------
-- PROJECTS
--
-- callback(projects, err). Fetched once and kept for the session, and on
-- disk for as long as the cache keeps anything.
--------------------------------------------------------------------------------

local function pipeline(source)
	if not source.pypi_top_pipeline then
		source.pypi_top_pipeline = Pipeline.new({
			name = "pypi-top",
		})
	end

	return source.pypi_top_pipeline
end

function M.projects(source, callback)
	local address = url(source)

	pipeline(source):fetch({
		key = address,

		disk = function()
			return {
				opts = source.opts.cache,
				namespace = "pypi-top",
				key = vim.fn.sha256(address),
			}
		end,

		fetch = function(done)
			local spec = {
				url = address,
				compressed = true,
				connect_timeout = source.opts.connect_timeout or M.HTTP_CONNECT_TIMEOUT,
				max_time = source.opts.max_time or M.HTTP_MAX_TIME,
			}

			if type(source.opts.retries) == "number" then
				spec.retries = math.max(source.opts.retries, 0)
			end

			Http.request(spec, function(body, err)
				if err then
					done(nil, err.message)
					return
				end

				-- The file is most of a megabyte, always.
				Worker.run(reduce_list, body, function(reduced)
					local projects, reduce_err = M.parse(reduced)

					if not projects then
						done(nil, "unreadable project list: " .. tostring(reduce_err))
						return
					end

					done(projects, nil)
				end)
			end)
		end,
	}, function(projects, err)
		callback(projects or {}, err)
	end)
end

--------------------------------------------------------------------------------
-- SEARCH
--
-- callback(packages, err) where packages is a list of { name, downloads }:
-- projects whose name starts with the text, most downloaded first, then
-- projects whose name contains it. No version is known here.
--
-- - _ and . in a name are the same character to an index, so they are the
-- same here.
--------------------------------------------------------------------------------

function M.search_packages(source, text, callback)
	local needle = Pep508.normalize(vim.trim(text or ""))

	if needle == "" or needle == "-" then
		callback({}, nil)
		return
	end

	M.projects(source, function(projects, err)
		local starting = {}
		local containing = {}

		for _, project in ipairs(projects) do
			local position = project.key:find(needle, 1, true)

			if position == 1 then
				if #starting < M.MAX_RESULTS then
					table.insert(starting, {
						name = project.name,
						downloads = project.downloads,
					})
				end
			elseif position and #containing < M.MAX_RESULTS then
				table.insert(containing, {
					name = project.name,
					downloads = project.downloads,
				})
			end
		end

		for _, package in ipairs(containing) do
			if #starting >= M.MAX_RESULTS then
				break
			end

			table.insert(starting, package)
		end

		callback(starting, err)
	end)
end

--------------------------------------------------------------------------------
-- REGISTRY
--
-- The list as seen through the contract in blink_deps.registries.
--------------------------------------------------------------------------------

M.REGISTRY = {
	id = "pypi-top",
	name = "Popular PyPI projects",
	kind = "pypi-top",

	capabilities = {
		search = true,
	},

	search = function(_, source, text, callback)
		M.search_packages(source, text, callback)
	end,
}

return M
