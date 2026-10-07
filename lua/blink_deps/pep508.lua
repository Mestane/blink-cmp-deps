--------------------------------------------------------------------------------
-- PEP 508 REQUIREMENTS
--
-- A Python dependency is written the same way wherever it appears, in a
-- requirements file or as a string in pyproject.toml:
--
--   requests[security,socks] >=2.31,<3 ; python_version >= "3.8"
--   \______/ \____________/  \_______/   \_____________________/
--     name       extras      specifiers          marker
--
-- or, pointing somewhere other than the index,
--
--   requests @ https://example.test/requests.whl
--
-- Given a requirement up to the cursor, this says which part the cursor is
-- in. Pure functions over strings; where the requirement came from is the
-- caller's business.
--------------------------------------------------------------------------------

local M = {}

-- Longest first, so that === is not read as == followed by =.
local OPERATORS = { "===", "~=", "==", "!=", "<=", ">=", "<", ">" }

-- How an index spells a project name: lowercase, with any run of - _ .
-- written as a single hyphen. Typing_Extensions, typing.extensions and
-- typing-extensions are one project.
function M.normalize(name)
	return ((name or ""):lower():gsub("[-_.]+", "-"))
end

local function take_operator(clause)
	for _, operator in ipairs(OPERATORS) do
		if clause:sub(1, #operator) == operator then
			return operator, clause:sub(#operator + 1)
		end
	end

	return nil, clause
end

--------------------------------------------------------------------------------
-- AT
--
-- text is the requirement from its first character to the cursor.
--
-- Returns nil when the cursor is not somewhere a name, an extra or a
-- version goes: in a marker, in a URL, after the name with nothing begun.
-- Otherwise:
--
--   kind       "name", "extra" or "version"
--   value      the text completion would replace, up to the cursor
--
-- and for an extra or a version:
--
--   package    the project name as written
--   normalized the project name as an index spells it
--   extras     the extras already listed before the cursor
--
-- and for a version:
--
--   operator   the comparison the version belongs to, such as >= or ==
--------------------------------------------------------------------------------

function M.at(text)
	if type(text) ~= "string" then
		return nil
	end

	local requirement = text:gsub("^%s+", "")

	-- Everything after a semicolon is an environment marker, and after an
	-- @ a URL or a path.
	if requirement:find(";", 1, true) or requirement:find("@", 1, true) then
		return nil
	end

	-- Still inside the name.
	if requirement:match("^[%w._-]*$") then
		return {
			kind = "name",
			value = requirement,
		}
	end

	local name = requirement:match("^[%w][%w._-]*")

	if not name then
		return nil
	end

	local rest = requirement:sub(#name + 1):gsub("^%s+", "")

	local function context(kind, value, fields)
		local result = {
			kind = kind,
			value = value,
			package = name,
			normalized = M.normalize(name),
		}

		for field, entry in pairs(fields or {}) do
			result[field] = entry
		end

		return result
	end

	--------------------------------------------------------------------------
	-- [security, so|
	--------------------------------------------------------------------------

	local extras = {}

	if rest:sub(1, 1) == "[" then
		local closing = rest:find("]", 1, true)
		local inside = rest:sub(2, (closing or (#rest + 1)) - 1)

		local parts = vim.split(inside, ",", { plain = true })

		if not closing then
			local typed = table.remove(parts):gsub("^%s+", "")

			for _, part in ipairs(parts) do
				part = vim.trim(part)

				if part ~= "" then
					table.insert(extras, part)
				end
			end

			if not typed:match("^[%w._-]*$") then
				return nil
			end

			return context("extra", typed, { extras = extras })
		end

		for _, part in ipairs(parts) do
			part = vim.trim(part)

			if part ~= "" then
				table.insert(extras, part)
			end
		end

		rest = rest:sub(closing + 1):gsub("^%s+", "")
	end

	--------------------------------------------------------------------------
	-- >=2.31, <3|
	--
	-- Specifiers may be wrapped in parentheses, an older spelling that is
	-- still valid. Only the last clause is being typed.
	--------------------------------------------------------------------------

	rest = rest:gsub("^%(%s*", "")

	local clause = (rest:match("([^,]*)$") or ""):gsub("^%s+", "")

	local operator, typed = take_operator(clause)

	if not operator then
		return nil
	end

	typed = typed:gsub("^%s+", "")

	-- Anything that cannot be part of a version means the specifier is
	-- already past its version.
	if not typed:match("^[%w.*+!_-]*$") then
		return nil
	end

	return context("version", typed, {
		operator = operator,
		extras = extras,
	})
end

return M
