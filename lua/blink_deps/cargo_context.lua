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

local Toml = require("blink_deps.toml_cursor")

local M = {}

local split_key = Toml.split_key
local read = Toml.read

local DEPENDENCY_SECTIONS = {
	["dependencies"] = true,
	["dev-dependencies"] = true,
	["build-dependencies"] = true,
}

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
-- for a name:
--
--   form         where it is being typed:
--                  "key"      as a key in a dependency table
--                  "header"   in a [dependencies.<name>] header
--                  "package"  as the target of a package rename
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
			return context("name", dependency.rest[1], dependency, {
				form = "header",
			})
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

		return context("name", typed, dependency, {
			form = "key",
		})
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
			form = "package",
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
