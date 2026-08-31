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

function M.debounce_ms(source)
	local configured =
		source.opts
		and source.opts.debounce_ms

	if type(configured) == "number" then
		return configured
	end

	return M.CENTRAL_DEBOUNCE_MS
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
