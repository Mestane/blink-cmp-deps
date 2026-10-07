local Pep508 = require("blink_deps.pep508")
local Toml = require("blink_deps.toml_cursor")

--------------------------------------------------------------------------------
-- PYPROJECT CONTEXT
--
-- Answers one question about a pyproject.toml: what does the cursor mean?
--
-- Dependencies are written in two styles, and in many places.
--
-- As requirement strings in an array, the same strings a requirements file
-- holds:
--
--   [project]
--   dependencies = ["requests>=2.31", "rich"]
--
--   [project.optional-dependencies]
--   dev = ["pytest>=8"]
--
--   [dependency-groups]            [build-system]
--   test = ["pytest>=8"]           requires = ["setuptools>=61"]
--
--   [tool.uv]                      [tool.pdm.dev-dependencies]
--   dev-dependencies = [...]       test = [...]
--
--   [tool.hatch.envs.default]
--   dependencies = [...]
--
-- And, in Poetry's own tables, as a key naming the project and a value
-- constraining its version, much like Cargo:
--
--   [tool.poetry.dependencies]
--   requests = "^2.31"
--   httpx = { version = "^0.27", extras = ["http2"] }
--
--   [tool.poetry.group.dev.dependencies]
--   pytest = "^8"
--
-- What part of a requirement string the cursor is in is worked out by
-- blink_deps.pep508; this decides whether a string is a requirement at all,
-- and reads Poetry's tables itself.
--
-- Pure: it takes lines and a position and touches nothing else.
--------------------------------------------------------------------------------

local M = {}

--------------------------------------------------------------------------------
-- WHERE REQUIREMENT ARRAYS LIVE
--
-- Each entry is a key path; * stands for any one key, such as the name of
-- an extra, a group or an environment.
--------------------------------------------------------------------------------

local REQUIREMENT_ARRAYS = {
	{ "project", "dependencies" },
	{ "project", "optional-dependencies", "*" },
	{ "dependency-groups", "*" },
	{ "build-system", "requires" },
	{ "tool", "uv", "dev-dependencies" },
	{ "tool", "uv", "constraint-dependencies" },
	{ "tool", "uv", "override-dependencies" },
	{ "tool", "pdm", "dev-dependencies", "*" },
	{ "tool", "hatch", "envs", "*", "dependencies" },
	{ "tool", "hatch", "envs", "*", "extra-dependencies" },
}

local function matches(path, pattern)
	if #path ~= #pattern then
		return false
	end

	for index, expected in ipairs(pattern) do
		if expected ~= "*" and path[index] ~= expected then
			return false
		end
	end

	return true
end

local function is_requirement_array(path)
	for _, pattern in ipairs(REQUIREMENT_ARRAYS) do
		if matches(path, pattern) then
			return true
		end
	end

	return false
end

--------------------------------------------------------------------------------
-- POETRY TABLES
--
-- Finds a Poetry dependency table at the start of a key path and returns
-- what comes after it:
--
--   tool.poetry.dependencies . requests . version   -> requests, version
--   tool.poetry.group.dev.dependencies . pytest     -> pytest
--------------------------------------------------------------------------------

local POETRY_TABLES = {
	{ "tool", "poetry", "dependencies" },
	{ "tool", "poetry", "dev-dependencies" },
	{ "tool", "poetry", "group", "*", "dependencies" },
}

local function poetry_rest(path)
	for _, pattern in ipairs(POETRY_TABLES) do
		if #path >= #pattern then
			local head = {}

			for index = 1, #pattern do
				head[index] = path[index]
			end

			if matches(head, pattern) then
				local rest = {}

				for index = #pattern + 1, #path do
					table.insert(rest, path[index])
				end

				return rest
			end
		end
	end

	return nil
end

-- A constraint may carry operators and several comparators:
--
--   ^2.31    >=2.0,<3.0    ~2.31 || ^3.0
--
-- Completion replaces the version being typed, not what surrounds it.
local function version_being_typed(constraint)
	return constraint:match("([^%s,<>=~%^!|]*)$") or ""
end

--------------------------------------------------------------------------------
-- AT
--
-- lines  the buffer
-- row    cursor line, 1 based
-- col    cursor byte column, 0 based
--
-- Returns nil when the cursor is not somewhere a project name, an extra or
-- a version goes. Otherwise what blink_deps.pep508 reports for a
-- requirement string, or the same shape for a Poetry entry:
--
--   kind        "name", "extra" or "version"
--   value       the text completion would replace, up to the cursor
--   row, col    as given
--   style       "pep508" for a requirement string, "poetry" for a table
--               entry
--   package     the project name as written      (extra, version)
--   normalized  the project name as an index spells it
--   operator    the comparison of a requirement string's specifier
--   constraint  for a Poetry version, the whole constraint typed so far
--   form        for a Poetry name, "key": it is being typed as a table key
--------------------------------------------------------------------------------

function M.at(lines, row, col)
	if type(lines) ~= "table" or type(lines[row]) ~= "string" then
		return nil
	end

	local text = table.concat(lines, "\n")
	local offset = 0

	for index = 1, row - 1 do
		offset = offset + #lines[index] + 1
	end

	local state = Toml.read(text, offset + math.min(col, #lines[row]))

	local function finish(context, style)
		context.row = row
		context.col = col
		context.style = style

		return context
	end

	--------------------------------------------------------------------------
	-- [tool.poetry.dependencies]
	-- reque|
	--------------------------------------------------------------------------

	if state.mode == "start" or state.mode == "key" then
		local rest = poetry_rest(state.table)

		if not rest or #rest ~= 0 then
			return nil
		end

		local typed = state.mode == "key" and state.raw or ""

		-- A dotted or quoted key is already past the project name.
		if not typed:match("^[%w_%-]*$") then
			return nil
		end

		return finish({
			kind = "name",
			value = typed,
			form = "key",
		}, "poetry")
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

	local arrays = 0
	local tables = 0
	local in_array = false

	for _, container in ipairs(state.containers) do
		if container.kind == "table" then
			if container.phase ~= "value" or not container.key then
				return nil
			end

			vim.list_extend(path, container.key)

			tables = tables + 1
			in_array = false
		else
			arrays = arrays + 1
			in_array = true
		end
	end

	--------------------------------------------------------------------------
	-- dependencies = ["requests>=2.|"]
	--
	-- A string directly in the array. One inside an inline table there,
	-- such as { include-group = "test" }, is not a requirement.
	--------------------------------------------------------------------------

	if arrays == 1 and tables == 0 and is_requirement_array(path) then
		local context = Pep508.at(state.content)

		if not context then
			return nil
		end

		return finish(context, "pep508")
	end

	--------------------------------------------------------------------------
	-- requests = "^2.|"
	-- httpx = { version = "^0.|", extras = ["htt|"] }
	--------------------------------------------------------------------------

	local rest = poetry_rest(path)

	if not rest then
		return nil
	end

	local name = rest[1]

	-- python is the interpreter the project supports, not a project.
	if not name or name == "" or name:lower() == "python" then
		return nil
	end

	local package = {
		package = name,
		normalized = Pep508.normalize(name),
	}

	if in_array then
		if #rest == 2 and rest[2] == "extras" and arrays == 1 then
			package.kind = "extra"
			package.value = state.content

			return finish(package, "poetry")
		end

		return nil
	end

	if #rest == 1 or (#rest == 2 and rest[2] == "version") then
		package.kind = "version"
		package.value = version_being_typed(state.content)
		package.constraint = state.content

		return finish(package, "poetry")
	end

	return nil
end

return M
