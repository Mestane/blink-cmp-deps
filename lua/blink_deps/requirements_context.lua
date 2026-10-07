local Pep508 = require("blink_deps.pep508")

--------------------------------------------------------------------------------
-- REQUIREMENTS CONTEXT
--
-- Answers one question about a requirements file: what does the cursor
-- mean?
--
-- A requirements file is a list of PEP 508 requirements, one per line, with
-- pip's own additions around them:
--
--   requests>=2.31            a requirement
--   # a comment               and  requests>=2 # one after a requirement
--   -r other.txt              an option: another file, an index, a flag
--   -e ./local                an editable install
--   ./downloads/pkg.whl       a path
--   https://example.test/x    a URL
--   requests==2.31 \          a line continued on the next
--       --hash=sha256:...
--
-- Only requirements are completed. What part of one the cursor is in is
-- worked out by blink_deps.pep508; this decides whether the line is a
-- requirement at all.
--
-- Pure: it takes lines and a position and touches nothing else.
--------------------------------------------------------------------------------

local M = {}

-- The logical line up to the cursor: a line ending in a backslash continues
-- on the next, so the lines before the cursor's may be part of it.
local function logical_line(lines, row, col)
	local text = lines[row]:sub(1, col)
	local first = row

	while first > 1 and lines[first - 1]:match("\\%s*$") do
		first = first - 1
		text = lines[first]:gsub("\\%s*$", " ") .. text
	end

	return text
end

-- pip starts a comment at a # that begins the line or follows whitespace.
-- A # anywhere else, as in a URL fragment, is not one.
local function in_comment(text)
	return text:match("^%s*#") ~= nil or text:match("%s#") ~= nil
end

--------------------------------------------------------------------------------
-- AT
--
-- lines  the buffer
-- row    cursor line, 1 based
-- col    cursor byte column, 0 based
--
-- Returns nil when the cursor is not in a requirement. Otherwise what
-- blink_deps.pep508 reports, with row and col as given.
--------------------------------------------------------------------------------

function M.at(lines, row, col)
	if type(lines) ~= "table" or type(lines[row]) ~= "string" then
		return nil
	end

	local text = logical_line(lines, row, math.min(col, #lines[row]))

	if in_comment(text) then
		return nil
	end

	local requirement = text:gsub("^%s+", "")

	-- An option, alone or after a requirement.
	if requirement:sub(1, 1) == "-" or requirement:match("%s%-%-?%a") then
		return nil
	end

	-- A path or a URL.
	if requirement:match("^[./~]")
		or requirement:find("://", 1, true)
		or requirement:find("\\", 1, true)
	then
		return nil
	end

	local context = Pep508.at(requirement)

	if not context then
		return nil
	end

	context.row = row
	context.col = col

	return context
end

return M
