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
