--------------------------------------------------------------------------------
-- PEP 440 VERSIONS
--
-- Ordering for Python packages. Python does not use semver: a version is
--
--   [epoch!] release [pre] [post] [dev] [+local]
--
--   1.0   2!1.0   1.0a1   1.0rc2   1.0.post1   1.0.dev3   1.0+ubuntu.1
--
-- and within one release the order is
--
--   1.0.dev1 < 1.0a1 < 1.0b1 < 1.0rc1 < 1.0 < 1.0.post1
--
-- with a development release of anything sorting just below it. The
-- specification also accepts many spellings of the same version, all of
-- which have to compare equal:
--
--   1.0a1 = 1.0alpha1 = 1.0-a.1        1.0.post1 = 1.0-1 = 1.0rev1
--   1.0 = 1.0.0 = v1.0                 1.0rc1 = 1.0c1 = 1.0pre1
--
-- Pure functions over strings.
--------------------------------------------------------------------------------

local M = {}

-- Spellings of the prerelease phases, longest first so that "alpha" is not
-- read as "a" followed by garbage.
local PRE_SPELLINGS = {
	{ "alpha", 1 },
	{ "beta", 2 },
	{ "preview", 3 },
	{ "pre", 3 },
	{ "rc", 3 },
	{ "a", 1 },
	{ "b", 2 },
	{ "c", 3 },
}

local POST_SPELLINGS = { "post", "rev", "r" }

--------------------------------------------------------------------------------
-- PARSE
--
-- Returns
--
--   { epoch, release, pre, post, dev, local_version }
--
-- or nil for something that is not a version. release is a list of numbers.
-- pre is { phase, number } with phase 1 for alpha, 2 for beta and 3 for a
-- release candidate. post and dev are numbers. Absent parts are nil.
--------------------------------------------------------------------------------

-- An optional separator, then one of the given words, then an optional
-- separator and an optional number. Returns the rest of the text, the word
-- and the number (0 when left out), or nil if no word is there.
local function take_segment(text, words)
	local body = text:match("^[._-]?(.*)$")

	for _, entry in ipairs(words) do
		local word = type(entry) == "table" and entry[1] or entry

		if body:sub(1, #word) == word then
			-- The separator is taken even when no number follows it:
			-- "1.0a." is 1.0a0, as the reference implementation reads it.
			local digits, rest = body:sub(#word + 1):match("^[._-]?(%d*)(.*)$")

			return rest, entry, tonumber(digits) or 0
		end
	end

	return nil
end

function M.parse(text)
	if type(text) ~= "string" then
		return nil
	end

	local version = vim.trim(text):lower()

	version = version:gsub("^v", "")

	local main, local_version = version:match("^([^+]*)%+(.+)$")

	if not main then
		if version:find("+", 1, true) then
			return nil
		end

		main = version
	else
		-- Alphanumeric segments, each separated by exactly one of . - _
		for _, segment in ipairs(vim.split(local_version, "[._-]")) do
			if not segment:match("^%w+$") then
				return nil
			end
		end
	end

	local parsed = {
		epoch = 0,
		local_version = local_version,
	}

	local epoch, after_epoch = main:match("^(%d+)!(.*)$")

	if epoch then
		parsed.epoch = tonumber(epoch)
		main = after_epoch
	end

	local release = main:match("^%d+[%d.]*")

	if not release then
		return nil
	end

	-- A trailing dot belongs to what follows the release, as in 1.0.post1.
	release = release:gsub("%.+$", "")

	if release:find("..", 1, true) then
		return nil
	end

	parsed.release = {}

	for number in release:gmatch("%d+") do
		table.insert(parsed.release, tonumber(number))
	end

	local rest = main:sub(#release + 1)

	local after_pre, phase, pre_number = take_segment(rest, PRE_SPELLINGS)

	if after_pre then
		parsed.pre = { phase[2], pre_number }
		rest = after_pre
	end

	-- 1.0-1 is a post release written without the word.
	local implicit_post, after_implicit = rest:match("^%-(%d+)(.*)$")

	if implicit_post then
		parsed.post = tonumber(implicit_post)
		rest = after_implicit
	else
		local after_post, _, post_number = take_segment(rest, POST_SPELLINGS)

		if after_post then
			parsed.post = post_number
			rest = after_post
		end
	end

	local after_dev, _, dev_number = take_segment(rest, { "dev" })

	if after_dev then
		parsed.dev = dev_number
		rest = after_dev
	end

	if rest ~= "" then
		return nil
	end

	return parsed
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

-- 1.0 and 1.0.0 are the same release.
local function compare_release(left, right)
	for index = 1, math.max(#left, #right) do
		local result = sign(left[index] or 0, right[index] or 0)

		if result ~= 0 then
			return result
		end
	end

	return 0
end

-- Where a version sits among those of the same release, as a pair that
-- compares correctly:
--
--   a development release of the plain version   lowest
--   alpha, beta, release candidate               by phase, then number
--   no prerelease part                           highest
local function pre_rank(parsed)
	if parsed.pre then
		return parsed.pre[1], parsed.pre[2]
	end

	if parsed.dev and not parsed.post then
		return 0, 0
	end

	return 4, 0
end

-- A local version is compared segment by segment; a number is higher than
-- text, and a longer one is higher than its own beginning.
local function compare_local(left, right)
	if not left or not right then
		return sign(left and 1 or 0, right and 1 or 0)
	end

	local left_parts = vim.split(left, "[._-]")
	local right_parts = vim.split(right, "[._-]")

	for index = 1, math.min(#left_parts, #right_parts) do
		local left_number = tonumber(left_parts[index]:match("^%d+$"))
		local right_number = tonumber(right_parts[index]:match("^%d+$"))

		local result

		if left_number and right_number then
			result = sign(left_number, right_number)
		elseif left_number or right_number then
			result = left_number and 1 or -1
		else
			result = sign(left_parts[index], right_parts[index])
		end

		if result ~= 0 then
			return result
		end
	end

	return sign(#left_parts, #right_parts)
end

local function compare_parsed(left, right)
	local result = sign(left.epoch, right.epoch)

	if result ~= 0 then
		return result
	end

	result = compare_release(left.release, right.release)

	if result ~= 0 then
		return result
	end

	local left_phase, left_number = pre_rank(left)
	local right_phase, right_number = pre_rank(right)

	result = sign(left_phase, right_phase)

	if result ~= 0 then
		return result
	end

	result = sign(left_number, right_number)

	if result ~= 0 then
		return result
	end

	-- No post release is lower than any post release.
	result = sign(left.post or -1, right.post or -1)

	if result ~= 0 then
		return result
	end

	-- A development release is lower than the thing it leads up to.
	result = sign(left.dev or math.huge, right.dev or math.huge)

	if result ~= 0 then
		return result
	end

	return compare_local(left.local_version, right.local_version)
end

-- 1 if left is the higher version, -1 if right is, 0 if they are the same
-- version, however each is spelled.
--
-- Something that is not a version sorts below everything that is, and
-- against another such string by text. An index is free to hold odd
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

-- True for alphas, betas, release candidates and development releases:
-- what pip does not install unless asked to.
function M.is_prerelease(text)
	local parsed = M.parse(text)

	return parsed ~= nil and (parsed.pre ~= nil or parsed.dev ~= nil)
end

--------------------------------------------------------------------------------
-- SORT
--
-- Highest first, in place. Entries are version strings or tables with the
-- version under value, the shape registries report versions in.
--
-- Different spellings of one version are ordered by their text, so that the
-- result never depends on the input order.
--------------------------------------------------------------------------------

local function value_of(entry)
	if type(entry) == "table" then
		return entry.value
	end

	return entry
end

function M.sort(entries)
	table.sort(entries, function(left, right)
		local left_value = value_of(left)
		local right_value = value_of(right)

		local result = M.compare(left_value, right_value)

		if result ~= 0 then
			return result > 0
		end

		return tostring(left_value) > tostring(right_value)
	end)

	return entries
end

return M
