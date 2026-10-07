--------------------------------------------------------------------------------
-- MAVEN CONTEXT
--
-- Answers one question about a pom.xml: what does the cursor mean?
--
-- Which element's text it is in, what has been typed there, and which
-- coordinate (dependency, plugin, parent, ...) that element belongs to,
-- together with the sibling values of that coordinate.
--
-- This is a small XML scanner rather than a set of line patterns, because
-- the questions depend on structure. A commented out <dependency> opens
-- nothing. A <groupId> inside a plugin's nested <dependencies> belongs to
-- that dependency, not to the plugin. Line patterns cannot tell.
--
-- It is not a validating parser. A file being edited is rarely well formed,
-- so anything it does not understand is skipped instead of rejected.
--
-- Pure: it takes lines and a position and touches nothing else, so every
-- case can be tested from a fixture.
--------------------------------------------------------------------------------

local M = {}

local function local_name(name)
	return name:match("([^:]+)$") or name
end

--------------------------------------------------------------------------------
-- SCANNER
--------------------------------------------------------------------------------

-- The index of the > that ends the tag opening at start, or nil if the tag
-- does not end by limit. A > inside a quoted attribute value does not count.
local function tag_end(text, start, limit)
	local quote

	for index = start + 1, limit do
		local byte = text:byte(index)

		if quote then
			if byte == quote then
				quote = nil
			end
		elseif byte == 34 or byte == 39 then
			quote = byte
		elseif byte == 62 then
			return index
		end
	end

	return nil
end

-- Constructs that are skipped whole: comments, CDATA sections, processing
-- instructions and declarations.
local SKIPPED = {
	{ open = "<!--", close = "-->" },
	{ open = "<![CDATA[", close = "]]>" },
	{ open = "<?", close = "?>" },
	{ open = "<!", close = ">" },
}

-- Walks text from first to limit and reports every element tag that is
-- complete within that range:
--
--   handler("open", name, tag_start, tag_end, self_closing)
--   handler("close", name, tag_start, tag_end)
--
-- A handler returning true stops the walk.
--
-- Returns true if the walk ended in the middle of a tag or of a skipped
-- construct, which is how a caller learns that a position is not in
-- element text at all.
local function scan(text, first, limit, handler)
	local position = first

	while position <= limit do
		local start = text:find("<", position, true)

		if not start or start > limit then
			return false
		end

		local skipped = false

		for _, construct in ipairs(SKIPPED) do
			if text:sub(start, start + #construct.open - 1) == construct.open then
				local _, finish = text:find(
					construct.close,
					start + #construct.open,
					true
				)

				if not finish or finish > limit then
					return true
				end

				position = finish + 1
				skipped = true

				break
			end
		end

		if not skipped then
			local closing, name = text:match("^<(/?)([%a_][%w_:%.%-]*)", start)

			if not name then
				-- A stray < in text, as in "a < b".
				position = start + 1
			else
				local finish = tag_end(text, start, limit)

				if not finish then
					return true
				end

				local stop

				if closing == "/" then
					stop = handler("close", local_name(name), start, finish)
				else
					stop = handler(
						"open",
						local_name(name),
						start,
						finish,
						text:byte(finish - 1) == 47
					)
				end

				if stop then
					return false
				end

				position = finish + 1
			end
		end
	end

	return false
end

--------------------------------------------------------------------------------
-- POSITIONS
--------------------------------------------------------------------------------

local function line_starts(lines)
	local starts = {}
	local offset = 1

	for index, line in ipairs(lines) do
		starts[index] = offset
		offset = offset + #line + 1
	end

	return starts
end

local function row_of(starts, position)
	local row = 1

	for index = 1, #starts do
		if starts[index] > position then
			break
		end

		row = index
	end

	return row
end

--------------------------------------------------------------------------------
-- TYPED VALUE
--
-- What has been typed in the element so far. Usually the element opens on
-- the cursor line and the value is everything after the tag. An element may
-- also be laid out as
--
--   <version>
--       1.0
--   </version>
--
-- in which case the value is what precedes the cursor on its own line. A
-- value that already spans several lines of text is not something a single
-- line edit can replace, so it is not offered completion.
--------------------------------------------------------------------------------

local function typed_value(content)
	if content:find("<", 1, true) then
		return nil
	end

	local before, last_line = content:match("^(.*)\n([^\n]*)$")

	if not before then
		return content
	end

	if before:find("%S") then
		return nil
	end

	return (last_line:gsub("^%s+", ""))
end

--------------------------------------------------------------------------------
-- BLOCK
--
-- The coordinate element around the cursor and the values of its direct
-- children. Only direct children: a nested element with the same name
-- belongs to something else.
--------------------------------------------------------------------------------

local function read_block(text, lines, starts, element)
	local fields = {}
	local open = {}
	local finish

	scan(text, element.tag_end + 1, #text, function(kind, name, tag_start, tag_stop, self_closing)
		if kind == "open" then
			if not self_closing then
				local parent = open[#open]

				if parent then
					parent.simple = false
				end

				table.insert(open, {
					name = name,
					content_start = tag_stop + 1,
					simple = true,
				})
			end

			return false
		end

		-- A closing tag. Find what it closes among the children.
		for index = #open, 1, -1 do
			if open[index].name == name then
				local child = open[index]

				if index == 1
					and child.simple
					and fields[name] == nil
				then
					local value = vim.trim(
						text:sub(child.content_start, tag_start - 1)
					)

					if value ~= "" then
						fields[name] = value
					end
				end

				for _ = index, #open do
					table.remove(open)
				end

				return false
			end
		end

		-- It closes nothing inside, so it closes the block itself or
		-- something around it. Either way the block ends here.
		finish = tag_start

		return true
	end)

	return {
		type = element.name,
		fields = fields,
		start_row = row_of(starts, element.tag_start),
		end_row = finish and row_of(starts, finish) or #lines,
		lines = lines,
	}
end

--------------------------------------------------------------------------------
-- AT
--
-- lines        the buffer
-- row          cursor line, 1 based
-- col          cursor byte column, 0 based
-- block_types  set of element names that hold a coordinate
--
-- Returns nil when the cursor is not in the text of an element: in a
-- comment, inside a tag, between elements after a child, or outside the
-- document.
--
-- Otherwise:
--   tag    name of the element the cursor is in, without namespace prefix
--   value  what has been typed in it up to the cursor
--   row    as given
--   col    as given
--   path   names from the root down to and including tag
--   block  the coordinate element this one is a direct child of, or nil:
--            type       its name
--            fields     values of its direct children, by name
--            start_row  line of its opening tag
--            end_row    line of its closing tag, or the last line
--            lines      the buffer
--------------------------------------------------------------------------------

function M.at(lines, row, col, block_types)
	if type(lines) ~= "table" or not lines[row] then
		return nil
	end

	local text = table.concat(lines, "\n")
	local starts = line_starts(lines)

	-- The cursor sits after this many bytes of text.
	local cursor = starts[row] - 1 + math.min(col, #lines[row])

	local stack = {}
	local content_start

	local inside_markup = scan(text, 1, cursor, function(kind, name, tag_start, tag_stop, self_closing)
		if kind == "open" then
			if self_closing then
				content_start = nil
			else
				table.insert(stack, {
					name = name,
					tag_start = tag_start,
					tag_end = tag_stop,
				})

				content_start = tag_stop + 1
			end

			return false
		end

		-- Whatever was opened after the matching element and never
		-- closed is abandoned with it.
		for index = #stack, 1, -1 do
			if stack[index].name == name then
				for _ = index, #stack do
					table.remove(stack)
				end

				break
			end
		end

		-- After a closing tag the cursor is between children, not in the
		-- text of the element that just opened.
		content_start = nil

		return false
	end)

	if inside_markup or not content_start then
		return nil
	end

	local element = stack[#stack]

	if not element then
		return nil
	end

	local value = typed_value(text:sub(content_start, cursor))

	if not value then
		return nil
	end

	local path = {}

	for _, entry in ipairs(stack) do
		table.insert(path, entry.name)
	end

	local block
	local parent = stack[#stack - 1]

	if parent and block_types and block_types[parent.name] then
		block = read_block(text, lines, starts, parent)
	end

	return {
		tag = element.name,
		value = value,
		row = row,
		col = col,
		path = path,
		block = block,
	}
end

return M
