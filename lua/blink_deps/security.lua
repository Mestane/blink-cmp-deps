local Osv = require("blink_deps.osv")

--------------------------------------------------------------------------------
-- SECURITY
--
-- What completion shows about known vulnerabilities: a short note next to a
-- version, and the details in its documentation.
--
-- Nothing here makes completion wait. A lookup is started when versions of
-- a package are first asked for and its answer is used from then on; until
-- it arrives, versions are shown without a note. The documentation of a
-- version does wait, since it is asked for one item at a time and has
-- nothing else to show.
--
-- All of it is off unless the user turned security lookups on.
--------------------------------------------------------------------------------

local M = {}

local function ecosystem_of(source)
	return source.ecosystem or "maven"
end

--------------------------------------------------------------------------------
-- WATCH
--
-- Starts looking a package up, if that is wanted and has not been done.
-- Returns at once.
--------------------------------------------------------------------------------

function M.watch(source, package)
	if not Osv.is_enabled(source) then
		return
	end

	Osv.advisories(source, ecosystem_of(source), package, function(_, err)
		if err then
			require("blink_deps.util").debug_log(
				source,
				"Vulnerability lookup failed for %s: %s",
				tostring(package and package.name),
				tostring(err)
			)
		end
	end)
end

--------------------------------------------------------------------------------
-- JUDGE
--
-- Returns a function giving the vulnerabilities of a version of a package,
-- or nil when nothing is known about the package yet or lookups are off.
--
-- The function is kept for as long as the advisories it was built from are
-- the ones known, so judging the same list again costs a table lookup per
-- version.
--------------------------------------------------------------------------------

function M.judge(source, package)
	if not Osv.is_enabled(source) then
		return nil
	end

	local ecosystem = ecosystem_of(source)
	local advisories = Osv.known(source, ecosystem, package)

	if not advisories then
		return nil
	end

	local owner = source.root or source

	owner.security_judges = owner.security_judges or setmetatable({}, { __mode = "k" })

	local judge = owner.security_judges[advisories]

	if not judge then
		judge = Osv.judge(advisories, ecosystem)
		owner.security_judges[advisories] = judge
	end

	return judge
end

--------------------------------------------------------------------------------
-- WORDING
--------------------------------------------------------------------------------

-- The note shown next to a version in the menu, or nil for none.
function M.note(findings)
	local count = #(findings or {})

	if count == 0 then
		return nil
	end

	return count == 1 and "1 vulnerability" or (count .. " vulnerabilities")
end

local SEVERITY_ORDER = {
	critical = 1,
	high = 2,
	moderate = 3,
	medium = 3,
	low = 4,
}

-- The documentation of a version: what it is, and what is known against
-- it, the most severe first.
function M.document(label, version, findings)
	local lines = { "**" .. label .. "** `" .. version .. "`", "" }

	if #findings == 0 then
		table.insert(lines, "No known vulnerabilities.")

		return table.concat(lines, "\n")
	end

	local ordered = vim.list_slice(findings)

	local position = {}

	for index, finding in ipairs(ordered) do
		position[finding] = index
	end

	table.sort(ordered, function(left, right)
		local left_rank = SEVERITY_ORDER[left.severity] or 5
		local right_rank = SEVERITY_ORDER[right.severity] or 5

		if left_rank ~= right_rank then
			return left_rank < right_rank
		end

		return position[left] < position[right]
	end)

	table.insert(lines, M.note(findings):gsub("^%d+", "%0 known") .. "")
	table.insert(lines, "")

	for _, finding in ipairs(ordered) do
		local line = "- **" .. finding.id .. "**"

		if finding.severity then
			line = line .. " (" .. finding.severity .. ")"
		end

		if finding.summary then
			-- One line each: a summary is free text and may hold anything.
			line = line .. " " .. finding.summary:gsub("%s+", " ")
		end

		table.insert(lines, line)

		local details = {}

		if finding.fixed then
			table.insert(details, "Fixed in `" .. finding.fixed .. "`")
		else
			table.insert(details, "No fixed version recorded")
		end

		-- The CVE is the name most people search for.
		for _, alias in ipairs(finding.aliases or {}) do
			if alias:match("^CVE%-") then
				table.insert(details, alias)
			end
		end

		table.insert(lines, "  " .. table.concat(details, " · "))
	end

	return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- ITEMS
--------------------------------------------------------------------------------

-- What a version item carries so that its documentation can be built
-- later, or nil when lookups are off.
function M.item_data(source, package, version, label)
	if not Osv.is_enabled(source) then
		return nil
	end

	return {
		deps_version = {
			ecosystem = ecosystem_of(source),
			package = {
				namespace = package.namespace,
				name = package.name,
			},
			version = version,
			label = label,
		},
	}
end

-- True for an item this module can document.
function M.handles(item)
	local data = type(item) == "table" and type(item.data) == "table" and item.data.deps_version

	return type(data) == "table"
		and type(data.package) == "table"
		and type(data.version) == "string"
end

-- Fills in the documentation of a version item. root is the unified
-- source. Waits for the lookup if it has not finished; a failed lookup
-- leaves the item as it was.
function M.resolve(root, item, callback)
	local resolved = vim.deepcopy(item)
	local data = resolved.data.deps_version

	local source = {
		opts = root.opts,
		root = root,
		ecosystem = data.ecosystem,
	}

	if not Osv.is_enabled(source) then
		callback(resolved)
		return
	end

	Osv.advisories(source, data.ecosystem, data.package, function(_, err)
		local judge = M.judge(source, data.package)

		if err or not judge then
			callback(resolved)
			return
		end

		resolved.documentation = {
			kind = "markdown",
			value = M.document(data.label or data.package.name, data.version, judge(data.version)),
		}

		callback(resolved)
	end)
end

return M
