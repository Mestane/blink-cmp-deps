local M = {}

--------------------------------------------------------------------------------
-- QUALIFIERS
--------------------------------------------------------------------------------

local QUALIFIER_RANK = {
	alpha = 10,
	beta = 20,
	milestone = 30,
	rc = 40,
	snapshot = 50,

	-- Custom qualifiers such as:
	--
	-- 5.0.0-internal
	-- 5.0.0-company
	--
	-- are intentionally treated as prereleases. Maven's generic qualifier
	-- ordering is more permissive, but for completion ranking we prefer the
	-- unqualified stable release when the numeric core is identical.
	unknown = 55,

	stable = 60,

	-- Maven service-pack versions sort after the base release.
	sp = 70,
}

local QUALIFIER_ALIASES = {
	a = "alpha",
	b = "beta",
	m = "milestone",

	cr = "rc",

	ga = "stable",
	final = "stable",
	release = "stable",
}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function normalize(value)
	return vim.trim(tostring(value or "")):lower()
end

local function parse_numeric_core(value)
	local normalized = normalize(value)

	--------------------------------------------------------------------------
	-- Examples:
	--
	-- 2.10.0          -> core = 2.10.0, suffix = ""
	-- 2.10.0-RC1      -> core = 2.10.0, suffix = "-rc1"
	-- 2.10.0.Final    -> core = 2.10.0, suffix = "final"
	-- 2.10.0RC1       -> core = 2.10.0, suffix = "rc1"
	--------------------------------------------------------------------------

	local core, suffix =
		normalized:match("^(%d[%d%.]*)(.*)$")

	if not core then
		return nil, normalized
	end

	-- `1.0.0.Final` initially produces `1.0.0.` as the numeric prefix.
	core = core:gsub("%.+$", "")

	local numbers = {}

	for number in core:gmatch("%d+") do
		table.insert(numbers, tonumber(number))
	end

	if #numbers == 0 then
		return nil, normalized
	end

	return numbers, suffix or ""
end

local function qualifier_info(suffix)
	suffix = normalize(suffix)

	suffix =
		suffix:gsub(
			"^[%._%+%-]+",
			""
		)

	if suffix == "" then
		return {
			name = "stable",
			number = 0,
			rank = QUALIFIER_RANK.stable,
			prerelease = false,
		}
	end

	local name, number =
		suffix:match(
			"^([%a]+)[%._%-]?(%d*)"
		)

	if not name then
		return {
			name = suffix,
			number = 0,
			rank = QUALIFIER_RANK.unknown,
			prerelease = true,
		}
	end

	name =
		QUALIFIER_ALIASES[name]
		or name

	local rank =
		QUALIFIER_RANK[name]

	if not rank then
		return {
			name = name,
			number = tonumber(number) or 0,
			rank = QUALIFIER_RANK.unknown,
			prerelease = true,
		}
	end

	return {
		name = name,
		number = tonumber(number) or 0,
		rank = rank,

		prerelease =
			rank < QUALIFIER_RANK.stable,
	}
end

local function compare_numeric_core(a, b)
	local length =
		math.max(#a, #b)

	for index = 1, length do
		local left = a[index] or 0
		local right = b[index] or 0

		if left ~= right then
			return left > right and 1 or -1
		end
	end

	return 0
end

--------------------------------------------------------------------------------
-- COMPARISON
--------------------------------------------------------------------------------

function M.compare_values(left, right)
	local left_value = normalize(left)
	local right_value = normalize(right)

	if left_value == right_value then
		return 0
	end

	local left_core, left_suffix =
		parse_numeric_core(left_value)

	local right_core, right_suffix =
		parse_numeric_core(right_value)

	--------------------------------------------------------------------------
	-- Unusual non-numeric versions are kept deterministic without pretending
	-- that we understand their versioning scheme.
	--------------------------------------------------------------------------

	if not left_core or not right_core then
		return left_value > right_value
				and 1
			or -1
	end

	local core_result =
		compare_numeric_core(
			left_core,
			right_core
		)

	if core_result ~= 0 then
		return core_result
	end

	local left_qualifier =
		qualifier_info(left_suffix)

	local right_qualifier =
		qualifier_info(right_suffix)

	--------------------------------------------------------------------------
	-- Same numeric version:
	--
	-- sp > stable > custom > snapshot > rc > milestone > beta > alpha
	--------------------------------------------------------------------------

	if left_qualifier.rank
		~= right_qualifier.rank
	then
		return left_qualifier.rank
				> right_qualifier.rank
				and 1
			or -1
	end

	if left_qualifier.name
		~= right_qualifier.name
	then
		return left_qualifier.name
				> right_qualifier.name
				and 1
			or -1
	end

	if left_qualifier.number
		~= right_qualifier.number
	then
		return left_qualifier.number
				> right_qualifier.number
				and 1
			or -1
	end

	--------------------------------------------------------------------------
	-- Semantically equivalent:
	--
	-- 1.0
	-- 1.0.0
	--
	-- or:
	--
	-- 1.0.0
	-- 1.0.0.Final
	--------------------------------------------------------------------------

	return 0
end

function M.is_prerelease(value)
	local core, suffix =
		parse_numeric_core(value)

	if not core then
		return false
	end

	return qualifier_info(suffix).prerelease
end

--------------------------------------------------------------------------------
-- SORT
--------------------------------------------------------------------------------

function M.sort(entries)
	table.sort(entries, function(left, right)
		local left_value =
			type(left) == "table"
				and left.value
			or left

		local right_value =
			type(right) == "table"
				and right.value
			or right

		local comparison =
			M.compare_values(
				left_value,
				right_value
			)

		if comparison ~= 0 then
			return comparison > 0
		end

		--------------------------------------------------------------------------
		-- Timestamp is now only a tie-breaker.
		--
		-- It must never make Maven Central 3.x outrank a private repository 5.x
		-- merely because custom maven-metadata.xml has no publication timestamp.
		--------------------------------------------------------------------------

		local left_timestamp =
			type(left) == "table"
				and tonumber(left.timestamp)
			or 0

		local right_timestamp =
			type(right) == "table"
				and tonumber(right.timestamp)
			or 0

		left_timestamp =
			left_timestamp or 0

		right_timestamp =
			right_timestamp or 0

		if left_timestamp
			~= right_timestamp
		then
			return left_timestamp
				> right_timestamp
		end

		-- Deterministic ordering for semantically equivalent strings.
		return tostring(left_value)
			> tostring(right_value)
	end)

	return entries
end

return M
