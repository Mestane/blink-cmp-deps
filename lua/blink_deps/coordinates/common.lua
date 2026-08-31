local Util = require("blink_deps.util")
local Central = require("blink_deps.central")

local M = {}

M.GROUP_MIN_CHARS = 2
M.GROUP_ROWS = 200
M.ARTIFACT_ROWS = 200
M.VERSION_ROWS = 200

M.KIND = {
	Field = 5,
	Module = 9,
	Constant = 21,
}

-- Blink issues a completion request per keystroke. Without a delay every
-- intermediate prefix reaches Maven Central, which throttles well below
-- that rate.
M.CENTRAL_DEBOUNCE_MS = 250

-- Discovery waits longer. A partly typed search term is never a useful
-- query: a:"jack" and spring AND boot both cost a request and answer with
-- nothing anyone wanted. Local repository matches are emitted immediately,
-- so the extra delay is not visible.
M.DISCOVERY_DEBOUNCE_MS = 400

local function configured_debounce(
	source,
	key
)
	local configured =
		source.opts
		and source.opts[key]

	if type(configured) == "number" then
		return configured
	end

	return nil
end

function M.debounce_ms(source)
	return configured_debounce(
		source,
		"debounce_ms"
	)
		or M.CENTRAL_DEBOUNCE_MS
end

function M.discovery_debounce_ms(source)
	return configured_debounce(
		source,
		"discovery_debounce_ms"
	)
		or configured_debounce(
			source,
			"debounce_ms"
		)
		or M.DISCOVERY_DEBOUNCE_MS
end


--------------------------------------------------------------------------------
-- SHARED RELEVANCE
--
-- Group completion and dependency discovery rank the same Central documents,
-- so the scoring lives here rather than in either one of them.
--------------------------------------------------------------------------------

local lower = Util.lower
local trim = Util.trim
local starts_with = Util.starts_with

local REVERSE_DOMAIN_PREFIXES = {
	"org.",
	"com.",
	"io.",
	"net.",
	"dev.",
	"co.",
	"edu.",
	"me.",
}

-- A reverse domain prefix means the user is typing a coordinate, not
-- searching. Discovery and group completion split on exactly this.
function M.is_reverse_domain_qualified(
	value
)
	local v = lower(value)

	for _, prefix in ipairs(
		REVERSE_DOMAIN_PREFIXES
	) do
		if starts_with(v, prefix) then
			return true
		end
	end

	return false
end

function M.split_tokens(value)
	local tokens = {}

	for token in lower(value):gmatch(
		"[%w]+"
	) do
		if token ~= "" then
			table.insert(
				tokens,
				token
			)
		end
	end

	return tokens
end

function M.discovery_doc_score(
	doc,
	value
)
	if type(doc) ~= "table" then
		return 0
	end

	local group =
		lower(doc.g or "")

	local artifact =
		lower(doc.a or "")

	local v =
		lower(trim(value))

	if v == "" then
		return 0
	end

	local score = 1

	if group == v then
		score = score + 50
	elseif starts_with(group, v) then
		score = score + 30
	elseif group:find(v, 1, true) then
		score = score + 15
	end

	if artifact == v then
		score = score + 50
	elseif starts_with(artifact, v) then
		score = score + 30
	elseif artifact:find(v, 1, true) then
		score = score + 15
	end

	for _, token in ipairs(
		M.split_tokens(v)
	) do
		if #token >= 2 then
			if starts_with(
				artifact,
				token
			) then
				score = score + 10
			elseif artifact:find(
				token,
				1,
				true
			) then
				score = score + 5
			end

			if starts_with(
				group,
				token
			) then
				score = score + 6
			elseif group:find(
				token,
				1,
				true
			) then
				score = score + 3
			end
		end
	end

	return score
end

function M.new_state()
	return {
		group_memory = {},
		central_cache = {},
		central_inflight = {},
		repository_cache = {},
		repository_inflight = {},
		artifact_catalog = {},
		version_catalog = {},
		notified = {},
		local_catalog = nil,
	}
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
