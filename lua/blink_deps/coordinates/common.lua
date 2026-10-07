local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Pipeline = require("blink_deps.pipeline")
local Relevance = require("blink_deps.relevance")

local M = {}

M.GROUP_MIN_CHARS = 2
M.GROUP_ROWS = Central.NAMESPACE_ROWS
M.ARTIFACT_ROWS = Central.PACKAGE_ROWS
M.VERSION_ROWS = Central.VERSION_ROWS

M.KIND = Util.KIND

-- The debounce policy is shared by every ecosystem and lives in
-- blink_deps.util; these are the names the coordinate code uses for it.
M.CENTRAL_DEBOUNCE_MS = Util.DEBOUNCE_MS
M.DISCOVERY_DEBOUNCE_MS = Util.SEARCH_DEBOUNCE_MS

M.debounce_ms = Util.debounce_ms
M.discovery_debounce_ms = Util.search_debounce_ms

--------------------------------------------------------------------------------
-- SHARED RELEVANCE
--
-- Group completion and dependency discovery rank the same documents. The
-- scoring itself lives in blink_deps.relevance; these are the names the
-- completion code has always used for it.
--------------------------------------------------------------------------------

-- A reverse domain prefix means the user is typing a coordinate, not
-- searching. Discovery and group completion split on exactly this.
M.is_reverse_domain_qualified = Relevance.is_reverse_domain_qualified

M.split_tokens = Util.split_tokens

-- doc is a Maven Central document, { g, a }.
function M.discovery_doc_score(doc, value)
	if type(doc) ~= "table" then
		return 0
	end

	return Relevance.package_score(doc.g, doc.a, value)
end

--------------------------------------------------------------------------------
-- STATE
--
-- Everything a source remembers between completion requests. All of it is
-- keyed by Maven coordinates or by request, never by which file is open, so a
-- pom.xml, a build.gradle and a version catalog can use the same tables.
--
-- Each field is a table so that sharing is a matter of holding the same
-- reference. The pipelines are created here, eagerly, for the same reason: a
-- pipeline created later on one source would be invisible to the others.
--------------------------------------------------------------------------------

local SHARED_FIELDS = {
	"group_memory",
	"artifact_catalog",
	"version_catalog",
	"notified",

	"central_cache",
	"central_inflight",
	"central_pipeline",

	"repository_cache",
	"repository_inflight",
	"repository_pipeline",

	"nexus_artifact_cache",
	"nexus_artifact_inflight",
	"nexus_artifact_pipeline",

	"nexus_group_cache",
	"nexus_group_inflight",
	"nexus_group_pipeline",

	"local_repository_pipeline",
}

local function add_pipeline(state, name, prefix)
	local memory = {}
	local inflight = {}

	state[prefix .. "_cache"] = memory
	state[prefix .. "_inflight"] = inflight

	state[prefix .. "_pipeline"] = Pipeline.new({
		name = name,
		memory = memory,
		inflight = inflight,
	})
end

-- Without an argument this builds a fresh, independent state.
--
-- With one, it returns a new table whose fields are the very same tables as
-- the given state. The caller gets its own object to hang opts and methods
-- on, and still sees every result any other holder has cached.
function M.new_state(shared)
	local state = {}

	if type(shared) == "table" then
		for _, field in ipairs(SHARED_FIELDS) do
			state[field] = shared[field]
		end

		return state
	end

	state.group_memory = {}
	state.artifact_catalog = {}
	state.version_catalog = {}
	state.notified = {}

	add_pipeline(state, "central", "central")
	add_pipeline(state, "repository", "repository")
	add_pipeline(state, "nexus-artifact", "nexus_artifact")
	add_pipeline(state, "nexus-group", "nexus_group")

	state.local_repository_pipeline = Pipeline.new({
		name = "local-repository",
	})

	return state
end

function M.notify_once(
	source,
	key,
	message,
	level
)
	if source.notified[key] then
		return
	end

	source.notified[key] = true

	vim.schedule(function()
		vim.notify(
			message,
			level or vim.log.levels.WARN
		)
	end)
end

function M.resolve(
	item,
	data_key,
	callback
)
	local resolved = vim.deepcopy(item)
	local data =
		resolved.data
		and resolved.data[data_key]

	if data
		and data.kind == "artifact"
	then
		resolved.documentation = {
			kind = "markdown",
			value = string.format(
				"**%s:%s**\n\nLatest: `%s`",
				data.groupId,
				data.artifactId,
				data.latestVersion
					or "unknown"
			),
		}
	elseif data
		and data.kind == "group"
	then
		resolved.documentation = {
			kind = "markdown",
			value =
				"**"
				.. data.groupId
				.. "**",
		}
	end

	callback(resolved)
end

function M.self_test()
	return {
		central_url = Central.URL,
	}
end

return M
