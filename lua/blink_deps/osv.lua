local Http = require("blink_deps.http")
local Pipeline = require("blink_deps.pipeline")
local Worker = require("blink_deps.worker")

--------------------------------------------------------------------------------
-- OSV
--
-- Known vulnerabilities, from https://osv.dev.
--
-- OSV is one database covering every ecosystem the plugin completes, in one
-- format. A package is looked up once:
--
--   POST /v1/query   { "package": { "ecosystem": "PyPI", "name": "requests" } }
--
-- and the answer lists every advisory for it together with the versions each
-- one affects. Whether a particular version is affected is then decided
-- here, so marking every version of a list costs one request, not one per
-- version.
--
-- A lookup sends the ecosystem and the name of a package and nothing else.
-- That is still a disclosure to a third party, of a name that may be
-- private, so nothing here runs unless the user has asked for it.
--
-- This module answers questions about packages and versions. It knows
-- nothing about completion.
--------------------------------------------------------------------------------

local M = {}

M.URL = "https://api.osv.dev/v1/query"

M.HTTP_CONNECT_TIMEOUT = 3
M.HTTP_MAX_TIME = 10

-- A package with a long history has several pages of advisories. Beyond
-- this many the lookup stops; what was read is still used.
M.MAX_PAGES = 5

--------------------------------------------------------------------------------
-- ECOSYSTEMS
--
-- How each of the plugin's ecosystems is called in OSV, how it names a
-- package there, and how its versions are ordered. The modules are loaded
-- on first use, so asking about one ecosystem never loads another's.
--------------------------------------------------------------------------------

local ECOSYSTEMS = {
	maven = {
		osv = "Maven",

		-- OSV names a Maven package groupId:artifactId.
		name = function(package)
			return package.namespace .. ":" .. package.name
		end,

		compare = function()
			return require("blink_deps.version_rank").compare_values
		end,
	},

	cargo = {
		osv = "crates.io",

		compare = function()
			return require("blink_deps.semver").compare
		end,
	},

	npm = {
		osv = "npm",

		compare = function()
			return require("blink_deps.semver").compare
		end,
	},

	pypi = {
		osv = "PyPI",

		-- An index spells a project one way; OSV uses the same spelling.
		name = function(package)
			return require("blink_deps.pep508").normalize(package.name)
		end,

		compare = function()
			return require("blink_deps.pep440").compare
		end,
	},
}

-- The OSV name of a package of the given ecosystem, or nil for an
-- ecosystem OSV is not consulted for.
function M.identify(ecosystem, package)
	local known = ECOSYSTEMS[ecosystem]

	if not known or type(package) ~= "table" or type(package.name) ~= "string" then
		return nil
	end

	if known.name then
		local ok, name = pcall(known.name, package)

		if not ok or type(name) ~= "string" or name == "" then
			return nil
		end

		return known.osv, name
	end

	return known.osv, package.name
end

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local function config(source)
	local configured = source.opts and source.opts.security

	if type(configured) == "table" then
		return configured
	end

	return {}
end

-- Off unless asked for: a lookup tells a third party which package is
-- being worked with.
function M.is_enabled(source)
	return config(source).enabled == true
end

local function url(source)
	return config(source).url or M.URL
end

--------------------------------------------------------------------------------
-- ADVISORIES
--
-- Reduces a page of OSV's answer to what is needed to judge a version,
-- keeping for each advisory only the part about the package asked for:
--
--   { advisories = { { id, summary, aliases, severity, versions, ranges } },
--     next_page_token = "..." }
--
-- versions is the explicit list of affected versions, when OSV gives one.
-- ranges is a list of event lists, each event { kind, version } with kind
-- one of introduced, fixed, last_affected.
--
-- The input is the ecosystem, the package name and the response, separated
-- by newlines. Runs on a worker thread, so it is self-contained. A result
-- starting with ! is a failure.
--------------------------------------------------------------------------------

local function reduce_page(input)
	local ecosystem, name, body = input:match("^([^\n]*)\n([^\n]*)\n(.*)$")

	if not ecosystem then
		return "!malformed input"
	end

	local ok, page = pcall(vim.json.decode, body)

	if not ok or type(page) ~= "table" then
		return "!not JSON"
	end

	-- No advisories at all is an empty object.
	if page.vulns ~= nil and type(page.vulns) ~= "table" then
		return "!not an OSV response"
	end

	local function text(value)
		return type(value) == "string" and value ~= "" and value or nil
	end

	-- GitHub advisories carry a ready label; others only a CVSS vector,
	-- which is left for whoever wants to compute a score.
	local function severity_of(vulnerability, affected)
		for _, holder in ipairs({ vulnerability, affected }) do
			for _, field in ipairs({ "database_specific", "ecosystem_specific" }) do
				local specific = holder[field]

				if type(specific) == "table" and text(specific.severity) then
					return specific.severity:lower()
				end
			end
		end

		return nil
	end

	local advisories = {}

	for _, vulnerability in ipairs(page.vulns or {}) do
		-- A withdrawn advisory was published in error.
		if type(vulnerability) == "table"
			and text(vulnerability.id)
			and vulnerability.withdrawn == nil
		then
			local advisory

			for _, affected in ipairs(type(vulnerability.affected) == "table" and vulnerability.affected or {}) do
				local package = type(affected) == "table" and affected.package

				-- One advisory may cover the package in several
				-- ecosystems; only this one's entry applies. PyPI names
				-- are compared as an index spells them.
				if type(package) == "table"
					and package.ecosystem == ecosystem
					and type(package.name) == "string"
					and (
						package.name == name
						or (
							ecosystem == "PyPI"
							and package.name:lower():gsub("[-_.]+", "-") == name
						)
					)
				then
					advisory = advisory
						or {
							id = vulnerability.id,
							summary = text(vulnerability.summary),
							aliases = {},
							versions = {},
							ranges = {},
						}

					advisory.severity = advisory.severity or severity_of(vulnerability, affected)

					for _, version in ipairs(type(affected.versions) == "table" and affected.versions or {}) do
						if type(version) == "string" then
							advisory.versions[#advisory.versions + 1] = version
						end
					end

					for _, range in ipairs(type(affected.ranges) == "table" and affected.ranges or {}) do
						-- A GIT range speaks of commits, which say nothing
						-- about a published version.
						if type(range) == "table"
							and (range.type == "ECOSYSTEM" or range.type == "SEMVER")
							and type(range.events) == "table"
						then
							local events = {}

							for _, event in ipairs(range.events) do
								if type(event) == "table" then
									for _, kind in ipairs({ "introduced", "fixed", "last_affected" }) do
										if type(event[kind]) == "string" then
											events[#events + 1] = { kind, event[kind] }
										end
									end
								end
							end

							if #events > 0 then
								advisory.ranges[#advisory.ranges + 1] = events
							end
						end
					end
				end
			end

			if advisory then
				for _, alias in ipairs(type(vulnerability.aliases) == "table" and vulnerability.aliases or {}) do
					if type(alias) == "string" then
						advisory.aliases[#advisory.aliases + 1] = alias
					end
				end

				advisories[#advisories + 1] = advisory
			end
		end
	end

	-- Lists throughout, and a list of pairs for the fields that may be
	-- absent: an empty Lua table does not survive encoding as either.
	local encoded = {}

	for index, advisory in ipairs(advisories) do
		encoded[index] = {
			advisory.id,
			advisory.summary or "",
			advisory.severity or "",
			advisory.aliases,
			advisory.versions,
			advisory.ranges,
		}
	end

	return vim.json.encode({ encoded, text(page.next_page_token) or "" })
end

-- A reduced page as { advisories, next_page_token }, or nil and a message.
function M.parse(reduced)
	if type(reduced) ~= "string" then
		return nil, "unreadable"
	end

	if reduced:sub(1, 1) == "!" then
		return nil, reduced:sub(2)
	end

	local parts = vim.json.decode(reduced)
	local advisories = {}

	for _, entry in ipairs(parts[1] or {}) do
		local ranges = {}

		for _, events in ipairs(entry[6] or {}) do
			local range = {}

			for _, event in ipairs(events) do
				table.insert(range, { kind = event[1], version = event[2] })
			end

			table.insert(ranges, range)
		end

		table.insert(advisories, {
			id = entry[1],
			summary = entry[2] ~= "" and entry[2] or nil,
			severity = entry[3] ~= "" and entry[3] or nil,
			aliases = entry[4] or {},
			versions = entry[5] or {},
			ranges = ranges,
		})
	end

	return {
		advisories = advisories,
		next_page_token = parts[2] ~= "" and parts[2] or nil,
	}, nil
end

-- For tests: reduce and parse in one go, on the calling thread.
function M.read(ecosystem, name, body)
	return M.parse(reduce_page(ecosystem .. "\n" .. name .. "\n" .. (body or "")))
end

--------------------------------------------------------------------------------
-- LOOKUP
--
-- callback(advisories, err) with every advisory OSV has for a package.
-- Fetched once per package, kept for the session and on disk.
--
-- ecosystem is the plugin's own name for it: maven, cargo, npm, pypi.
-- package is as the registries take it, { namespace, name }.
--
-- A package OSV knows nothing bad about is an empty list. So is a package
-- of an ecosystem OSV is not consulted for; neither is an error.
--------------------------------------------------------------------------------

-- Advisories are facts about packages, whichever delegate asks. They are
-- kept on the unified source when there is one, so that every delegate and
-- the documentation of an item see the same answers.
local function holder(source)
	return source.root or source
end

local function pipeline(source)
	local owner = holder(source)

	if not owner.osv_pipeline then
		owner.osv_pipeline = Pipeline.new({
			name = "osv",
		})
	end

	return owner.osv_pipeline
end

local function fetch_pages(source, osv_ecosystem, name, done)
	local advisories = {}

	local function page(number, token)
		local query = {
			package = {
				ecosystem = osv_ecosystem,
				name = name,
			},
		}

		if token then
			query.page_token = token
		end

		local spec = {
			url = url(source),
			body = vim.json.encode(query),
			compressed = true,
			headers = {
				["Content-Type"] = "application/json",
			},
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

			Worker.run(reduce_page, osv_ecosystem .. "\n" .. name .. "\n" .. body, function(reduced)
				local parsed, parse_err = M.parse(reduced)

				if not parsed then
					done(nil, "unreadable OSV response: " .. tostring(parse_err))
					return
				end

				vim.list_extend(advisories, parsed.advisories)

				if parsed.next_page_token and number < M.MAX_PAGES then
					page(number + 1, parsed.next_page_token)
					return
				end

				done(advisories, nil)
			end)
		end)
	end

	page(1, nil)
end

function M.advisories(source, ecosystem, package, callback)
	local osv_ecosystem, name = M.identify(ecosystem, package)

	if not osv_ecosystem then
		callback({}, nil)
		return
	end

	local key = url(source) .. "\n" .. osv_ecosystem .. "\n" .. name

	pipeline(source):fetch({
		key = key,

		disk = function()
			return {
				opts = source.opts.cache,
				namespace = "osv",
				key = vim.fn.sha256(key),
			}
		end,

		fetch = function(done)
			fetch_pages(source, osv_ecosystem, name, done)
		end,
	}, function(advisories, err)
		callback(advisories or {}, err)
	end)
end

-- What is already known about a package this session, without asking:
-- the advisories, or nil if the lookup has not finished or was never made.
function M.known(source, ecosystem, package)
	local osv_ecosystem, name = M.identify(ecosystem, package)

	local owner = holder(source)

	if not osv_ecosystem or not owner.osv_pipeline then
		return nil
	end

	return owner.osv_pipeline.memory[url(source) .. "\n" .. osv_ecosystem .. "\n" .. name]
end

--------------------------------------------------------------------------------
-- JUDGING A VERSION
--
-- A version is affected by an advisory if it is in the advisory's list of
-- versions, or falls in one of its ranges. A range is a sequence of events
-- read in order:
--
--   introduced X      from X on, affected       ("0" means from the start)
--   fixed Y           from Y on, not affected
--   last_affected Z   after Z, not affected
--
-- so { introduced 0, fixed 2.0, introduced 2.5, fixed 2.6 } affects every
-- version below 2.0 and those from 2.5 up to but not including 2.6.
--------------------------------------------------------------------------------

local function in_range(events, version, compare)
	local affected = false

	for _, event in ipairs(events) do
		if event.kind == "introduced" then
			if event.version == "0" or compare(version, event.version) >= 0 then
				affected = true
			end
		elseif event.kind == "fixed" then
			if compare(version, event.version) >= 0 then
				affected = false
			end
		elseif event.kind == "last_affected" then
			if compare(version, event.version) > 0 then
				affected = false
			end
		end
	end

	return affected
end

-- The lowest fixed version above the given one, across an advisory's
-- ranges: the nearest upgrade that leaves it behind.
local function fixed_in(advisory, version, compare)
	local nearest

	for _, events in ipairs(advisory.ranges) do
		for _, event in ipairs(events) do
			if event.kind == "fixed"
				and compare(event.version, version) > 0
				and (not nearest or compare(event.version, nearest) < 0)
			then
				nearest = event.version
			end
		end
	end

	return nearest
end

-- Returns a function that, given a version, returns the vulnerabilities
-- affecting it, each as { id, summary, severity, aliases, fixed }, in the
-- order the advisories were given. Versions are compared by the
-- ecosystem's own rules. The list returned for a version is shared between
-- calls and must not be altered.
--
-- Built once for a list of versions and reused for each of them. Judging a
-- list naively took seconds: 300 versions against 60 advisories, each
-- listing 300 affected versions, is millions of comparisons, every one of
-- which parses both sides. So listed versions are looked up in a set, and
-- a comparison between two particular strings is made once and remembered;
-- the boundaries of all the ranges together are only a handful of versions.
function M.judge(advisories, ecosystem)
	local known = ECOSYSTEMS[ecosystem]

	if not known then
		return function()
			return {}
		end
	end

	local raw_compare = known.compare()
	local remembered = {}

	local function compare(left, right)
		local key = left .. "\0" .. right
		local result = remembered[key]

		if result == nil then
			result = raw_compare(left, right)
			remembered[key] = result
		end

		return result
	end

	local listed = {}

	for index, advisory in ipairs(advisories or {}) do
		local set = {}

		for _, version in ipairs(advisory.versions) do
			set[version] = true
		end

		listed[index] = set
	end

	-- The same vulnerability is often recorded more than once: by GitHub
	-- as GHSA-..., by an ecosystem's own database as PYSEC-... or
	-- RUSTSEC-..., each naming the other, or the same CVE, as an alias.
	-- Records connected that way are one finding.
	local function merged(found)
		local group_of = {}
		local groups = {}

		for _, finding in ipairs(found) do
			local names = { finding.id }

			vim.list_extend(names, finding.aliases or {})

			local group

			for _, name in ipairs(names) do
				group = group or group_of[name]
			end

			if not group then
				group = {
					id = finding.id,
					aliases = {},
					known = {},
				}

				table.insert(groups, group)
			end

			-- Whichever record says something the others do not is
			-- listened to.
			group.summary = group.summary or finding.summary
			group.severity = group.severity or finding.severity
			group.fixed = group.fixed or finding.fixed

			for _, name in ipairs(names) do
				-- Two groups joined only by a later record stay two;
				-- that needs three databases to disagree and has not
				-- been seen.
				group_of[name] = group_of[name] or group

				if name ~= group.id and not group.known[name] then
					group.known[name] = true
					table.insert(group.aliases, name)
				end
			end
		end

		for _, group in ipairs(groups) do
			group.known = nil
		end

		return groups
	end

	local judged = {}

	return function(version)
		if type(version) ~= "string" or version == "" then
			return {}
		end

		if judged[version] then
			return judged[version]
		end

		local found = {}

		for index, advisory in ipairs(advisories or {}) do
			local affected = listed[index][version] == true

			if not affected then
				for _, events in ipairs(advisory.ranges) do
					if in_range(events, version, compare) then
						affected = true
						break
					end
				end
			end

			if affected then
				table.insert(found, {
					id = advisory.id,
					summary = advisory.summary,
					severity = advisory.severity,
					aliases = advisory.aliases,
					fixed = fixed_in(advisory, version, compare),
				})
			end
		end

		judged[version] = merged(found)

		return judged[version]
	end
end

-- The advisories affecting one version. For a whole list of versions,
-- build a judge once instead.
function M.affecting(advisories, ecosystem, version)
	return M.judge(advisories, ecosystem)(version)
end

return M
