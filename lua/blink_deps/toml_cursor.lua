--------------------------------------------------------------------------------
-- TOML CURSOR
--
-- Reads a TOML file up to the cursor and says what is open there: which
-- table the cursor is under, which key is being given a value, which inline
-- tables and arrays enclose it, and whether it is inside a string.
--
-- Cargo.toml and pyproject.toml are both TOML and ask the same question of
-- it, so the reading is done here once. What the answer means is each
-- file's own business.
--
-- It is not a validating parser. A file being edited is rarely valid, so
-- whatever it does not understand is skipped instead of rejected.
--
-- Pure functions over strings.
--------------------------------------------------------------------------------

local M = {}

--------------------------------------------------------------------------------
-- KEYS
--------------------------------------------------------------------------------

-- Splits a dotted key into its parts. A quoted part may contain dots, as in
-- target.'cfg(target_os = "linux")'.dependencies.
function M.split_key(raw)
	local parts = {}
	local current = {}
	local quote

	for index = 1, #raw do
		local char = raw:sub(index, index)

		if quote then
			if char == quote then
				quote = nil
			else
				table.insert(current, char)
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "." then
			table.insert(parts, vim.trim(table.concat(current)))
			current = {}
		else
			table.insert(current, char)
		end
	end

	table.insert(parts, vim.trim(table.concat(current)))

	return parts
end

--------------------------------------------------------------------------------
-- READER
--
-- Walks the text up to the cursor and reports where it stopped:
--
--   mode        "start"    at the beginning of a line
--               "header"   inside an unfinished [table] header
--               "key"      typing a key, before any =
--               "value"    after =, outside any string
--               "string"   inside a string
--               "comment"  inside a comment
--   table       key path of the enclosing [table]
--   table_end   offset just past that table's header
--   raw         text of the header or key typed so far
--   keys        key path of the current statement
--   containers  open inline tables and arrays, outermost first
--   content     text of the string so far
--   statement   offset where the current statement began
--------------------------------------------------------------------------------

function M.read(text, cursor)
	local state = {
		mode = "start",
		table = {},
		table_end = 1,
		containers = {},
	}

	local index = 1
	local raw_start
	local string_start
	local quote
	local multiline

	local function end_statement()
		state.mode = "start"
		state.keys = nil
		state.containers = {}
	end

	while index <= cursor do
		local char = text:sub(index, index)
		local mode = state.mode

		if mode == "comment" then
			if char == "\n" then
				state.mode = state.after_comment
				-- The newline still ends or continues whatever the comment
				-- interrupted, so it is handled again in that mode.
				index = index - 1
			end
		elseif mode == "string" then
			if multiline then
				if text:sub(index, index + 2) == quote:rep(3) then
					state.mode = "value"
					index = index + 2
				elseif char == "\\" and quote == '"' then
					index = index + 1
				end
			elseif char == "\n" then
				-- A string left open at the end of a line: the statement
				-- is broken, and what follows is not part of it.
				end_statement()
			elseif char == "\\" and quote == '"' then
				index = index + 1
			elseif char == quote then
				state.mode = "value"
			end
		elseif mode == "start" then
			if char == "#" then
				state.mode = "comment"
				state.after_comment = "start"
			elseif char == "[" then
				state.mode = "header"
				raw_start = index + 1
			elseif not char:match("%s") then
				state.mode = "key"
				state.statement = index
				raw_start = index
			end
		elseif mode == "header" then
			if char == "]" then
				local raw = text:sub(raw_start, index - 1)

				-- [[bin]] and friends: an array of tables. The second
				-- bracket shows up as a leading [ in the raw text.
				if raw:sub(1, 1) == "[" then
					state.table = { "[[" .. raw:sub(2) .. "]]" }
				else
					state.table = M.split_key(raw)
				end

				state.table_end = index + 1
				state.mode = "value"
				state.keys = nil
			elseif char == "\n" then
				state.table = {}
				state.table_end = index + 1
				end_statement()
			end
		elseif mode == "key" then
			if char == "=" then
				state.keys = M.split_key(text:sub(raw_start, index - 1))
				state.mode = "value"
			elseif char == "\n" then
				end_statement()
			elseif char == "#" then
				state.mode = "comment"
				state.after_comment = "start"
			end
		elseif mode == "value" then
			local top = state.containers[#state.containers]

			if char == '"' or char == "'" then
				quote = char
				multiline = text:sub(index, index + 2) == char:rep(3)

				if multiline then
					index = index + 2
				end

				string_start = index + 1
				state.mode = "string"
				state.in_key = top ~= nil and top.kind == "table" and top.phase == "key"
			elseif char == "#" then
				state.mode = "comment"
				state.after_comment = "value"
			elseif char == "\n" then
				-- An array may span lines. An inline table may not, so one
				-- left open is a broken statement, not a continuing one.
				if not top or top.kind == "table" then
					end_statement()
				end
			elseif char == "{" then
				table.insert(state.containers, {
					kind = "table",
					phase = "key",
					key_start = index + 1,
				})
			elseif char == "[" then
				table.insert(state.containers, { kind = "array" })
			elseif char == "}" or char == "]" then
				table.remove(state.containers)
			elseif top and top.kind == "table" then
				if char == "=" and top.phase == "key" then
					top.key = M.split_key(text:sub(top.key_start, index - 1))
					top.phase = "value"
				elseif char == "," then
					top.phase = "key"
					top.key = nil
					top.key_start = index + 1
				end
			end
		end

		index = index + 1
	end

	if state.mode == "header" or state.mode == "key" then
		state.raw = text:sub(raw_start, cursor)
	elseif state.mode == "string" then
		state.content = text:sub(string_start, cursor)
		state.multiline = multiline
	end

	return state
end

return M
