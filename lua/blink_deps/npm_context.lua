--------------------------------------------------------------------------------
-- NPM CONTEXT
--
-- Answers one question about a package.json: what does the cursor mean?
--
-- A package name being typed, or a version, and for a version, of which
-- package. Everything else is nil.
--
-- Packages are named in several places, and not always the same way:
--
--   "dependencies":         { "react": "^18.2.0" }
--   "devDependencies":      { "@types/node": "^20" }
--   "peerDependencies", "optionalDependencies"
--   "bundledDependencies":  ["react"]
--   "overrides":            { "react": "18.2.0", "foo": { "bar": "1.0.0" } }
--   "resolutions":          { "**/react": "18.2.0" }           yarn
--   "pnpm": { "overrides":  { "foo>bar": "1.0.0" } }           pnpm
--
-- All of them reduce to a path of keys ending at the string under the
-- cursor, so this is a small JSON reader that tracks that path.
--
-- It is not a validating parser. A file being edited is rarely valid, so
-- whatever it does not understand is skipped instead of rejected.
--
-- Pure: it takes lines and a position and touches nothing else, so every
-- case can be tested from a fixture.
--------------------------------------------------------------------------------

local M = {}

-- Objects mapping a package name to a version range.
local DEPENDENCY_SECTIONS = {
	dependencies = true,
	devDependencies = true,
	peerDependencies = true,
	optionalDependencies = true,
}

-- Arrays of package names. Both spellings are accepted by npm.
local NAME_LISTS = {
	bundledDependencies = true,
	bundleDependencies = true,
}

--------------------------------------------------------------------------------
-- READER
--
-- Walks the text up to the cursor and reports what is open there:
--
--   containers  open objects and arrays, outermost first. An object carries
--               the key it is currently at, and whether the reader is
--               before the key, after it, or at its value
--   in_string   true when the cursor is inside a string
--   is_key      true when that string is an object key
--   content     the text of that string up to the cursor
--------------------------------------------------------------------------------

local function read(text, cursor)
	local containers = {}

	local in_string = false
	local string_start
	local is_key = false

	local index = 1

	while index <= cursor do
		local char = text:sub(index, index)

		if in_string then
			if char == "\\" then
				index = index + 1
			elseif char == '"' then
				in_string = false

				if is_key then
					local top = containers[#containers]

					top.key = text:sub(string_start, index - 1)
					top.phase = "colon"
				end
			elseif char == "\n" then
				-- A JSON string cannot contain a line break, so one left
				-- open is broken and what follows is not part of it.
				in_string = false
			end
		else
			local top = containers[#containers]

			if char == '"' then
				in_string = true
				string_start = index + 1
				is_key = top ~= nil and top.kind == "object" and top.phase == "key"
			elseif char == "{" then
				table.insert(containers, { kind = "object", phase = "key" })
			elseif char == "[" then
				table.insert(containers, { kind = "array" })
			elseif char == "}" or char == "]" then
				table.remove(containers)
			elseif top and top.kind == "object" then
				if char == ":" then
					top.phase = "value"
				elseif char == "," then
					top.phase = "key"
					top.key = nil
				end
			end
		end

		index = index + 1
	end

	return {
		containers = containers,
		in_string = in_string,
		is_key = is_key,
		content = in_string and text:sub(string_start, cursor) or nil,
	}
end

--------------------------------------------------------------------------------
-- PACKAGE NAMES IN KEYS
--
-- In the dependency sections a key is a package name. Elsewhere it is a
-- selector that names one:
--
--   overrides     react            react@^17         .   (the parent itself)
--   resolutions   react            **/react          parent/@scope/name
--   pnpm          react            react@^17         parent>react
--------------------------------------------------------------------------------

-- Drops a trailing @range. The @ that opens a scope is not one.
local function without_range(selector)
	local position = selector:find("@", 2, true)

	if position then
		return selector:sub(1, position - 1)
	end

	return selector
end

-- The last package named in a path such as parent/@scope/name.
local function last_in_path(selector)
	local scope, name = selector:match("(@[^/]+)/([^/]+)$")

	if scope then
		return scope .. "/" .. name
	end

	return selector:match("([^/]+)$") or selector
end

local function package_from_selector(kind, selector)
	if kind == "resolutions" then
		return last_in_path(selector)
	end

	if kind == "pnpm" then
		return without_range(selector:match("([^>]+)$") or selector)
	end

	return without_range(selector)
end

--------------------------------------------------------------------------------
-- VERSION RANGES
--
-- A range may carry operators and several comparators:
--
--   ^18.2    >=1.2 <2    1.x || 2
--
-- Completion replaces the version being typed, not what surrounds it.
--------------------------------------------------------------------------------

local function version_being_typed(range)
	return range:match("([^%s<>=~%^|]*)$") or ""
end

-- A value that is not a range from the registry: a path, a URL, a git
-- reference, a workspace or catalog protocol, a GitHub shorthand.
local function is_reference(value)
	return value:match("^[%a][%w+.%-]*:") ~= nil or value:find("/", 1, true) ~= nil
end

--------------------------------------------------------------------------------
-- AT
--
-- lines  the buffer
-- row    cursor line, 1 based
-- col    cursor byte column, 0 based
--
-- Returns nil when the cursor is not somewhere a package name or a version
-- goes. Otherwise:
--
--   kind     "name" or "version"
--   value    the text completion would replace, up to the cursor
--   row, col as given
--   section  the top level key the cursor is under: "dependencies",
--            "overrides", "resolutions", "pnpm", ...
--
-- for a name:
--
--   form     where it is being typed:
--              "key"    as a key in a dependency section
--              "list"   as an element of bundledDependencies
--              "alias"  after npm: in an alias such as "npm:react@^18"
--
-- and for a version:
--
--   package  the package it belongs to
--   alias    the key it is declared under, when that differs
--   range    the whole range typed so far
--------------------------------------------------------------------------------

function M.at(lines, row, col)
	if type(lines) ~= "table" or not lines[row] then
		return nil
	end

	local text = table.concat(lines, "\n")
	local offset = 0

	for index = 1, row - 1 do
		offset = offset + #lines[index] + 1
	end

	local state = read(text, offset + math.min(col, #lines[row]))

	if not state.in_string then
		return nil
	end

	local containers = state.containers
	local top = containers[#containers]

	-- The file itself must be an object.
	if not top or containers[1].kind ~= "object" then
		return nil
	end

	--------------------------------------------------------------------------
	-- THE PATH TO THIS STRING
	--
	-- The keys of the objects around it, outermost first. An array adds no
	-- key of its own; it sits under the key of the object holding it.
	--------------------------------------------------------------------------

	local path = {}

	for position = 1, #containers - 1 do
		local container = containers[position]

		if container.kind == "object" then
			if not container.key then
				return nil
			end

			table.insert(path, container.key)
		end
	end

	local section = path[1]

	local function context(kind, value, fields)
		local result = {
			kind = kind,
			value = value,
			row = row,
			col = col,
			section = section,
		}

		for name, field in pairs(fields or {}) do
			result[name] = field
		end

		return result
	end

	--------------------------------------------------------------------------
	-- "bundledDependencies": ["rea|"]
	--------------------------------------------------------------------------

	if top.kind == "array" then
		if #path == 1 and NAME_LISTS[section] then
			return context("name", state.content, { form = "list" })
		end

		return nil
	end

	--------------------------------------------------------------------------
	-- "dependencies": { "rea|" }
	--------------------------------------------------------------------------

	if state.is_key then
		if #path == 1 and DEPENDENCY_SECTIONS[section] then
			return context("name", state.content, { form = "key" })
		end

		return nil
	end

	if top.phase ~= "value" or not top.key or top.key == "" then
		return nil
	end

	--------------------------------------------------------------------------
	-- WHICH PACKAGE
	--------------------------------------------------------------------------

	local key = top.key
	local package

	if #path == 1 and DEPENDENCY_SECTIONS[section] then
		package = key
	elseif section == "overrides" and #path >= 1 then
		-- "." stands for the package the enclosing object is about.
		if key == "." then
			key = path[#path]

			if #path < 2 then
				return nil
			end
		end

		package = package_from_selector("overrides", key)
	elseif section == "resolutions" and #path == 1 then
		package = package_from_selector("resolutions", key)
	elseif section == "pnpm" and #path == 2 and path[2] == "overrides" then
		package = package_from_selector("pnpm", key)
	else
		return nil
	end

	if not package or package == "" then
		return nil
	end

	--------------------------------------------------------------------------
	-- "react-17": "npm:react@^17"
	--
	-- An alias installs another package under this key. Before the @ the
	-- package itself is being named; after it, its version.
	--------------------------------------------------------------------------

	local range = state.content
	local alias

	local aliased = range:match("^npm:(.*)$")

	if aliased then
		local separator = aliased:find("@", 2, true)

		if not separator then
			return context("name", aliased, { form = "alias", alias = key })
		end

		alias = key
		package = aliased:sub(1, separator - 1)
		range = aliased:sub(separator + 1)
	elseif is_reference(range) then
		return nil
	end

	return context("version", version_being_typed(range), {
		package = package,
		alias = alias ~= package and alias or (key ~= package and key or nil),
		range = range,
	})
end

return M
