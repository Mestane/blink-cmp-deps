--------------------------------------------------------------------------------
-- DECLARED DEPENDENCIES
--
-- Lists the dependencies a manifest already declares: which package, at
-- which version, and exactly where that version is written.
--
-- Completion asks what one position in a file means. This asks the same
-- question of every position where a version could end, using the same
-- readers, and keeps the answers that are versions. So a version is found
-- here if and only if completion would offer versions at it; the two can
-- never disagree about what a file says.
--
-- It is what anything other than completion builds on: checking a file for
-- vulnerable or outdated dependencies starts from this list.
--
-- Pure: it takes the lines of a file and touches nothing else.
--------------------------------------------------------------------------------

local M = {}

--------------------------------------------------------------------------------
-- READERS
--
-- One per kind of manifest, by the manifest's id. Each gives
--
--   ecosystem  the plugin's name for the ecosystem
--   at         the cursor context function of that file type
--   package    function(context) returning the package a version context
--              belongs to as { namespace, name } and a label to show, or
--              nil if the context is not a declared version
--   no_operators  true where a version is never preceded by an operator
--
-- The context modules are loaded on first use, so scanning one kind of file
-- never loads another's reader.
--------------------------------------------------------------------------------

local MAVEN_BLOCKS = {
	dependency = true,
	plugin = true,
	reportPlugin = true,
	parent = true,
	extension = true,
}

-- What Maven assumes for a plugin declared without a groupId.
local MAVEN_PLUGIN_GROUP = "org.apache.maven.plugins"

local READERS = {
	maven = {
		ecosystem = "maven",

		-- A version stands alone in its element; the > before it closes
		-- a tag and compares nothing.
		no_operators = true,

		at = function(lines, row, col)
			return require("blink_deps.maven_context").at(lines, row, col, MAVEN_BLOCKS)
		end,

		package = function(context)
			local block = context.block

			if context.tag ~= "version" or not block then
				return nil
			end

			local group = block.fields.groupId
			local artifact = block.fields.artifactId

			if (not group or group == "")
				and (block.type == "plugin" or block.type == "reportPlugin")
			then
				group = MAVEN_PLUGIN_GROUP
			end

			if not group or group == "" or not artifact or artifact == "" then
				return nil
			end

			return { namespace = group, name = artifact }, group .. ":" .. artifact
		end,
	},

	cargo = {
		ecosystem = "cargo",

		at = function(lines, row, col)
			return require("blink_deps.cargo_context").at(lines, row, col)
		end,

		package = function(context)
			if context.kind ~= "version" or not context.crate then
				return nil
			end

			return { name = context.crate }, context.crate
		end,
	},

	npm = {
		ecosystem = "npm",

		at = function(lines, row, col)
			return require("blink_deps.npm_context").at(lines, row, col)
		end,

		package = function(context)
			if context.kind ~= "version" or not context.package then
				return nil
			end

			return { name = context.package }, context.package
		end,
	},

	requirements = {
		ecosystem = "pypi",

		at = function(lines, row, col)
			return require("blink_deps.requirements_context").at(lines, row, col)
		end,

		package = function(context)
			if context.kind ~= "version" or not context.normalized then
				return nil
			end

			return { name = context.normalized }, context.package
		end,
	},

	pyproject = {
		ecosystem = "pypi",

		at = function(lines, row, col)
			return require("blink_deps.pyproject_context").at(lines, row, col)
		end,

		package = function(context)
			if context.kind ~= "version" or not context.normalized then
				return nil
			end

			return { name = context.normalized }, context.package
		end,
	},
}

-- True for a manifest whose declared dependencies can be listed.
function M.supports(manifest_id)
	return READERS[manifest_id] ~= nil
end

--------------------------------------------------------------------------------
-- WHERE A VERSION COULD END
--
-- A version is a run of version characters beginning with a digit: 1.2.3,
-- 2.0.0-rc.1, 5.3.9.RELEASE, 1.0+local. Every place such a run ends on a
-- line is a candidate; most lines have none, a dependency line one or two.
--
-- Returns the byte columns just past each run, 0 based.
--------------------------------------------------------------------------------

local function candidates(line)
	local columns = {}
	local position = 1

	while true do
		local first, last = line:find("%d[%w.+!*_-]*", position)

		if not first then
			return columns
		end

		-- A digit inside a word is not the start of a version: the 2 of
		-- log4j2 or the 3 of python3.
		local before = first > 1 and line:sub(first - 1, first - 1) or ""

		if not before:match("[%w_]") then
			table.insert(columns, last)
		end

		position = last + 1
	end
end

--------------------------------------------------------------------------------
-- THE OPERATOR BEFORE A VERSION
--
-- A requirement may name several versions: >=1.2,<2 names two, and only the
-- first is one the dependency could resolve to. A version after <, <= or
-- != is a bound or an exclusion, never what is declared.
--------------------------------------------------------------------------------

local function operator_before(line, start)
	return line:sub(1, start):match("([<>=!~^]+)%s*$") or ""
end

local function is_bound(operator)
	return operator == "<" or operator == "<=" or operator == "!="
end

--------------------------------------------------------------------------------
-- SCAN
--
-- manifest_id  which kind of manifest the lines are, as the manifest
--              registry names it
-- lines        the file
--
-- Returns a list, in file order, of
--
--   ecosystem  the plugin's name for the ecosystem
--   package    { namespace, name }, as the registries take it
--   label      the package as the file writes it
--   version    the version declared
--   operator   what precedes it, such as ^ or >=, or an empty string
--   row        its line, 1 based
--   col        the byte column it starts at, 0 based
--   end_col    the byte column just past it
--
-- An unsupported manifest has no declared dependencies. A version given as
-- a property reference, a wildcard or a range's upper bound is not listed:
-- none of them says which version is in use.
--------------------------------------------------------------------------------

function M.scan(manifest_id, lines)
	local reader = READERS[manifest_id]

	if not reader or type(lines) ~= "table" then
		return {}
	end

	local found = {}

	for row, line in ipairs(lines) do
		local seen = {}

		for _, col in ipairs(candidates(line)) do
			local context = reader.at(lines, row, col)
			local package, label

			if context then
				package, label = reader.package(context)
			end

			if package then
				local version = context.value
				local start = col - #version

				local operator = reader.no_operators and "" or operator_before(line, start)

				-- The reader says how much of the run is the version;
				-- anything else it reports is not a plain version.
				if version ~= ""
					and version:match("^%d[%w.+!_-]*$")
					and line:sub(start + 1, col) == version
					and not seen[start]
					and not is_bound(operator)
				then
					seen[start] = true

					table.insert(found, {
						ecosystem = reader.ecosystem,
						package = package,
						label = label,
						version = version,
						operator = operator,
						row = row,
						col = start,
						end_col = col,
					})
				end
			end
		end
	end

	return found
end

return M
