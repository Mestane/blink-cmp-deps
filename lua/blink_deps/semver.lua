--------------------------------------------------------------------------------
-- SEMANTIC VERSIONS
--
-- Ordering for ecosystems that version by semver.org: Cargo, and npm after
-- it. Maven is not one of them; its qualifiers follow different rules and
-- live in blink_deps.version_rank.
--
-- The rules, from the specification:
--
--   1. major, minor and patch compare as numbers
--   2. a version with a prerelease is lower than the same version without one
--   3. prereleases compare identifier by identifier: numeric ones as numbers,
--      others as text, numeric lower than text, and when one is a prefix of
--      the other the shorter is lower
--   4. build metadata does not affect precedence
--
-- so that
--
--   1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta
--     < 1.0.0-beta.2 < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0
--
-- Pure functions over strings.
--------------------------------------------------------------------------------

local M = {}

--------------------------------------------------------------------------------
-- PARSE
--
-- Returns { major, minor, patch, prerelease, build } or nil. prerelease is a
-- list of identifiers, numeric ones as numbers; it is empty for a release.
--
-- Strict about shape: three numeric parts are required. A partial version
-- such as "1.2" is a requirement, not a version.
--------------------------------------------------------------------------------

function M.parse(text)
	if type(text) ~= "string" then
		return nil
	end

	local core, build = text:match("^([^+]*)%+?(.*)$")
	local numbers, prerelease = core:match("^([^-]*)%-?(.*)$")

	local major, minor, patch = numbers:match("^(%d+)%.(%d+)%.(%d+)$")

	if not major then
		return nil
	end

	-- A trailing - or + with nothing after it is not a version.
	if core:sub(-1) == "-" or text:sub(-1) == "+" then
		return nil
	end

	local identifiers = {}

	if prerelease ~= "" then
		for identifier in (prerelease .. "."):gmatch("([^.]*)%.") do
			if not identifier:match("^[%w%-]+$") then
				return nil
			end

			if identifier:match("^%d+$") then
				table.insert(identifiers, tonumber(identifier))
			else
				table.insert(identifiers, identifier)
			end
		end
	end

	return {
		major = tonumber(major),
		minor = tonumber(minor),
		patch = tonumber(patch),
		prerelease = identifiers,
		build = build,
	}
end

--------------------------------------------------------------------------------
-- COMPARE
--------------------------------------------------------------------------------

local function sign(left, right)
	if left == right then
		return 0
	end

	return left > right and 1 or -1
end

local function compare_identifiers(left, right)
	local left_numeric = type(left) == "number"
	local right_numeric = type(right) == "number"

	if left_numeric and right_numeric then
		return sign(left, right)
	end

	-- A numeric identifier is lower than a textual one.
	if left_numeric ~= right_numeric then
		return left_numeric and -1 or 1
	end

	return sign(left, right)
end

local function compare_prerelease(left, right)
	-- A release is higher than any prerelease of the same version.
	if #left == 0 or #right == 0 then
		return sign(#right, #left)
	end

	for index = 1, math.min(#left, #right) do
		local result = compare_identifiers(left[index], right[index])

		if result ~= 0 then
			return result
		end
	end

	return sign(#left, #right)
end

local function compare_parsed(left, right)
	local result = sign(left.major, right.major)

	if result ~= 0 then
		return result
	end

	result = sign(left.minor, right.minor)

	if result ~= 0 then
		return result
	end

	result = sign(left.patch, right.patch)

	if result ~= 0 then
		return result
	end

	return compare_prerelease(left.prerelease, right.prerelease)
end

-- 1 if left is the higher version, -1 if right is, 0 if they have the same
-- precedence.
--
-- Something that is not a semantic version sorts below everything that is,
-- and against another such string by text. A registry is free to hold odd
-- entries; they must have a stable place without pretending to understand
-- them.
function M.compare(left, right)
	local left_parsed = M.parse(left)
	local right_parsed = M.parse(right)

	if left_parsed and right_parsed then
		return compare_parsed(left_parsed, right_parsed)
	end

	if left_parsed or right_parsed then
		return left_parsed and 1 or -1
	end

	return sign(tostring(left), tostring(right))
end

function M.is_prerelease(text)
	local parsed = M.parse(text)

	return parsed ~= nil and #parsed.prerelease > 0
end

--------------------------------------------------------------------------------
-- SORT
--
-- Highest first, in place. Entries are version strings or tables with the
-- version under value, the shape registries report versions in.
--
-- Versions of equal precedence, which differ only in build metadata, are
-- ordered by their text so that the result never depends on the input order.
--------------------------------------------------------------------------------

local function value_of(entry)
	if type(entry) == "table" then
		return entry.value
	end

	return entry
end

function M.sort(entries)
	-- Each version is parsed once. Sorting compares every entry many
	-- times, and parsing on each comparison made a list of a few thousand
	-- versions take a tenth of a second.
	local parsed = {}

	local function parse_once(value)
		if type(value) ~= "string" then
			return false
		end

		local result = parsed[value]

		if result == nil then
			result = M.parse(value) or false
			parsed[value] = result
		end

		return result
	end

	table.sort(entries, function(left, right)
		local left_value = value_of(left)
		local right_value = value_of(right)

		local left_parsed = parse_once(left_value)
		local right_parsed = parse_once(right_value)

		local result

		if left_parsed and right_parsed then
			result = compare_parsed(left_parsed, right_parsed)
		elseif left_parsed or right_parsed then
			result = left_parsed and 1 or -1
		else
			result = sign(tostring(left_value), tostring(right_value))
		end

		if result ~= 0 then
			return result > 0
		end

		return tostring(left_value) > tostring(right_value)
	end)

	return entries
end

return M
