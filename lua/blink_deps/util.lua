local M = {}

function M.lower(value)
	return (value or ""):lower()
end

function M.trim(value)
	return vim.trim(value or "")
end

function M.starts_with(value, prefix)
	return value:sub(1, #prefix) == prefix
end

-- Lowercased alphanumeric runs: "Spring-Data JPA" -> spring, data, jpa.
function M.split_tokens(value)
	local tokens = {}

	for token in M.lower(value):gmatch("[%w]+") do
		table.insert(tokens, token)
	end

	return tokens
end

function M.list_to_set(values)
	local set = {}
	for _, value in ipairs(values or {}) do
		set[value] = true
	end
	return set
end

function M.sorted_keys(set)
	local result = {}
	for value in pairs(set or {}) do
		table.insert(result, value)
	end
	table.sort(result)
	return result
end

function M.dedupe_docs(docs)
	local result = {}
	local seen = {}
	for _, doc in ipairs(docs or {}) do
		local group = doc.g or doc.groupId or ""
		local artifact = doc.a or doc.artifactId or ""
		local version = doc.latestVersion or doc.version or doc.v or ""
		local key = group .. "\0" .. artifact .. "\0" .. version
		if key ~= "\0\0" and not seen[key] then
			seen[key] = true
			table.insert(result, {
				g = group,
				a = artifact,
				latestVersion = version,
				v = doc.v,
				timestamp = doc.timestamp,
			})
		end
	end
	return result
end

function M.extract_groups(docs)
	local seen = {}
	local groups = {}
	for _, doc in ipairs(docs or {}) do
		local group = doc.g or doc.groupId
		if group and group ~= "" and not seen[group] then
			seen[group] = true
			table.insert(groups, group)
		end
	end
	table.sort(groups)
	return groups
end

function M.extract_artifacts(docs, group_id)
	local seen = {}
	local artifacts = {}
	for _, doc in ipairs(docs or {}) do
		local group = doc.g or doc.groupId
		local artifact = doc.a or doc.artifactId
		if (not group_id or group == group_id)
			and artifact
			and artifact ~= ""
			and not seen[artifact]
		then
			seen[artifact] = true
			table.insert(artifacts, {
				artifact = artifact,
				latestVersion = doc.latestVersion or doc.version or doc.v or "unknown",
			})
		end
	end
	table.sort(artifacts, function(a, b)
		return a.artifact < b.artifact
	end)
	return artifacts
end

function M.debug_log(source, fmt, ...)
	if not (source and source.opts and source.opts.debug) then
		return
	end

	local message = string.format(fmt, ...)

	vim.schedule(function()
		vim.notify("[blink-cmp-deps] " .. message, vim.log.levels.DEBUG)
	end)
end

-- Wrapped so tests can replace it with a synchronous stub.
function M.defer(ms, fn)
	if type(ms) ~= "number" or ms <= 0 then
		fn()
		return
	end

	vim.defer_fn(fn, ms)
end

--------------------------------------------------------------------------------
-- COMPLETION ITEM KINDS
--
-- The LSP CompletionItemKind values the plugin uses, by name.
--------------------------------------------------------------------------------

M.KIND = {
	Field = 5,
	Module = 9,
	Value = 12,
	Constant = 21,
}

--------------------------------------------------------------------------------
-- DEBOUNCE
--
-- Blink issues a completion request per keystroke. Without a delay every
-- intermediate prefix reaches the network, and registries throttle well
-- below that rate.
--------------------------------------------------------------------------------

M.DEBOUNCE_MS = 250

-- A free text search waits longer. A partly typed search term is never a
-- useful query, it only costs a request. Results found on disk are offered
-- at once, so the extra delay is not visible.
M.SEARCH_DEBOUNCE_MS = 400

local function configured_number(source, key)
	local configured = source.opts and source.opts[key]

	if type(configured) == "number" then
		return configured
	end

	return nil
end

function M.debounce_ms(source)
	return configured_number(source, "debounce_ms") or M.DEBOUNCE_MS
end

function M.search_debounce_ms(source)
	return configured_number(source, "discovery_debounce_ms")
		or configured_number(source, "debounce_ms")
		or M.SEARCH_DEBOUNCE_MS
end

function M.response(items, incomplete)
	return {
		items = items,
		is_incomplete_forward = incomplete == true,
		is_incomplete_backward = incomplete == true,
	}
end

function M.make_range(context, value)
	local pos = context.get_pos()
	return {
		start = {
			line = pos.row,
			character = pos.col - #value,
		},
		["end"] = {
			line = pos.row,
			character = pos.col,
		},
	}
end

return M
