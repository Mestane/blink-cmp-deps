--------------------------------------------------------------------------------
-- CARGO CONTEXT
--
-- Answers one question about a Cargo.toml: what does the cursor mean?
--
-- A crate name being typed, a version requirement, or a feature, and for the
-- last two, of which crate. Everything else is nil.
--
-- Cargo lets the same dependency be written several ways:
--
--   [dependencies]
--   serde = "1"
--   serde = { version = "1", features = ["derive"] }
--   serde.version = "1"
--
--   [dependencies.serde]
--   version = "1"
--
-- and puts dependency tables in several places: dev-dependencies,
-- build-dependencies, [workspace.dependencies], and per target under
-- [target.'cfg(unix)'.dependencies]. All of them reduce to a path of keys
-- ending at the string under the cursor, so this is a small TOML reader
-- that tracks that path, not a pattern per spelling.
--
-- It is not a validating parser. A file being edited is rarely valid, so
-- whatever it does not understand is skipped instead of rejected.
--
-- Pure: it takes lines and a position and touches nothing else, so every
-- case can be tested from a fixture.
--------------------------------------------------------------------------------

local M = {}

local DEPENDENCY_SECTIONS = {
	["dependencies"] = true,
	["dev-dependencies"] = true,
	["build-dependencies"] = true,
}

--------------------------------------------------------------------------------
-- KEYS
--------------------------------------------------------------------------------

-- Splits a dotted key into its parts. A quoted part may contain dots, as in
-- target.'cfg(target_os = "linux")'.dependencies.
local function split_key(raw)
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
-- DEPENDENCY PATHS
--
-- Finds the dependency table in a key path and returns what comes after it:
--
--   dependencies . serde . version              -> rest = serde, version
--   workspace . dependencies . serde            -> rest = serde
--   target . cfg(unix) . dev-dependencies . x   -> rest = x
--------------------------------------------------------------------------------

local function dependency_path(path)
	local position

	if DEPENDENCY_SECTIONS[path[1]] then
		position = 1
	elseif path[1] == "workspace" and DEPENDENCY_SECTIONS[path[2]] then
		position = 2
	elseif path[1] == "target" and DEPENDENCY_SECTIONS[path[3]] then
		position = 3
	end

	if not position then
		return nil
	end

	local rest = {}

	for index = position + 1, #path do
		table.insert(rest, path[index])
	end

	return {
		section = path[position],
		workspace = path[1] == "workspace",
		target = path[1] == "target" and path[2] or nil,
		rest = rest,
	}
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

local function read(text, cursor)
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
					state.table = split_key(raw)
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
				state.keys = split_key(text:sub(raw_start, index - 1))
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
					top.key = split_key(text:sub(top.key_start, index - 1))
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

--------------------------------------------------------------------------------
-- RENAMED PACKAGES
--
--   json = { package = "serde_json", version = "1" }
--
-- The key is only a local name. Versions and features belong to the crate
-- named by package, which may be written before or after the cursor.
--------------------------------------------------------------------------------

local function package_in(region)
	return region:match("%f[%w_%-]package%s*=%s*[\"']([^\"'\n]*)[\"']")
end

local function line_end(text, position)
	return (text:find("\n", position, true) or (#text + 1)) - 1
end

local function next_header(text, position)
	local start = text:find("\n%s*%[", position)

	return start or (#text + 1)
end

--------------------------------------------------------------------------------
-- VERSION REQUIREMENTS
--
-- A requirement may carry operators and several comparators:
--
--   ^1.2    >=1.2, <2    = 1.0.4
--
-- Completion replaces the version being typed, not the operators around it.
--------------------------------------------------------------------------------

local function version_being_typed(requirement)
	return requirement:match("([^%s,<>=~%^]*)$") or ""
end

--------------------------------------------------------------------------------
-- AT
--
-- lines  the buffer
-- row    cursor line, 1 based
-- col    cursor byte column, 0 based
--
-- Returns nil when the cursor is not somewhere a crate name, a version or a
-- feature goes. Otherwise:
--
--   kind         "name", "version" or "feature"
--   value        the text completion would replace, up to the cursor
--   row, col     as given
--   section      "dependencies", "dev-dependencies" or "build-dependencies"
--   workspace    true under [workspace.dependencies]
--   target       the target of a [target.<target>.dependencies] table
--
-- and for a version or a feature:
--
--   crate        the crate it belongs to, after any package rename
--   alias        the key it is declared under
--   requirement  for a version, the whole requirement typed so far
--------------------------------------------------------------------------------

function M.at(lines, row, col)
	if type(lines) ~= "table" or not lines[row] then
		return nil
	end

	local text = table.concat(lines, "\n")
	local line_offset = 0

	for index = 1, row - 1 do
		line_offset = line_offset + #lines[index] + 1
	end

	local cursor = line_offset + math.min(col, #lines[row])
	local state = read(text, cursor)

	local function context(kind, value, dependency, fields)
		local result = {
			kind = kind,
			value = value,
			row = row,
			col = col,
			section = dependency.section,
			workspace = dependency.workspace,
			target = dependency.target,
		}

		for name, field in pairs(fields or {}) do
			result[name] = field
		end

		return result
	end

	--------------------------------------------------------------------------
	-- [dependencies.ser|
	--------------------------------------------------------------------------

	if state.mode == "header" then
		local path = split_key(state.raw)
		local dependency = dependency_path(path)

		if dependency and #dependency.rest == 1 and not state.raw:find("[\"']") then
			return context("name", dependency.rest[1], dependency)
		end

		return nil
	end

	--------------------------------------------------------------------------
	-- ser|          at the start of a line in a dependency table
	--------------------------------------------------------------------------

	if state.mode == "start" or state.mode == "key" then
		local dependency = dependency_path(state.table)

		if not dependency or #dependency.rest ~= 0 then
			return nil
		end

		local typed = state.mode == "key" and state.raw or ""

		-- A dotted or quoted key is already past the crate name.
		if not typed:match("^[%w_%-]*$") then
			return nil
		end

		return context("name", typed, dependency)
	end

	if state.mode ~= "string" or state.in_key then
		return nil
	end

	-- A string that already spans lines is not something a single line
	-- edit can replace.
	if state.content:find("\n", 1, true) then
		return nil
	end

	--------------------------------------------------------------------------
	-- THE PATH TO THIS STRING
	--------------------------------------------------------------------------

	local path = {}

	vim.list_extend(path, state.table)
	vim.list_extend(path, state.keys or {})

	local in_array = false
	local inline_table = false

	for _, container in ipairs(state.containers) do
		if container.kind == "table" then
			if container.phase ~= "value" or not container.key then
				return nil
			end

			vim.list_extend(path, container.key)

			inline_table = true
			in_array = false
		else
			in_array = true
		end
	end

	local dependency = dependency_path(path)

	if not dependency then
		return nil
	end

	local rest = dependency.rest
	local alias = rest[1]

	if not alias or alias == "" then
		return nil
	end

	--------------------------------------------------------------------------
	-- json = { package = "ser|" }
	--------------------------------------------------------------------------

	if #rest == 2 and rest[2] == "package" and not in_array then
		return context("name", state.content, dependency, {
			alias = alias,
		})
	end

	local kind

	if not in_array and (#rest == 1 or (#rest == 2 and rest[2] == "version")) then
		kind = "version"
	elseif in_array and #rest == 2 and rest[2] == "features" then
		kind = "feature"
	else
		return nil
	end

	--------------------------------------------------------------------------
	-- WHICH CRATE
	--------------------------------------------------------------------------

	local crate = alias

	if inline_table then
		-- An inline table sits on one line.
		crate = package_in(text:sub(state.statement, line_end(text, cursor)))
			or alias
	elseif #state.table > 0 and state.table[#state.table] == alias then
		-- [dependencies.json]: the rename is another key of that table.
		crate = package_in(
			text:sub(state.table_end, next_header(text, state.table_end) - 1)
		) or alias
	end

	if kind == "feature" then
		return context("feature", state.content, dependency, {
			crate = crate,
			alias = alias,
		})
	end

	return context("version", version_being_typed(state.content), dependency, {
		crate = crate,
		alias = alias,
		requirement = state.content,
	})
end

return M
