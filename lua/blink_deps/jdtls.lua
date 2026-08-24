local Util = require("blink_deps.util")

local M = {}

local function debug_log(source, fmt, ...)
	if not source.opts.debug then
		return
	end
	local message = string.format(fmt, ...)
	vim.schedule(function()
		vim.notify("[Maven] " .. message, vim.log.levels.DEBUG)
	end)
end

local function notify_once(source, key, message, level)
	if source.notified[key] then
		return
	end
	source.notified[key] = true
	vim.schedule(function()
		vim.notify(message, level or vim.log.levels.WARN)
	end)
end

local function get_client()
	local clients = vim.lsp.get_clients({ name = "jdtls" })
	if #clients == 0 then
		return nil
	end

	local filename = vim.api.nvim_buf_get_name(0)
	local best
	local best_len = -1

	for _, client in ipairs(clients) do
		local root = client.config and client.config.root_dir
		if type(root) == "string"
			and root ~= ""
			and Util.starts_with(filename, root)
			and #root > best_len
		then
			best = client
			best_len = #root
		end
	end

	return best or clients[1]
end

local function get_index_path(source)
	if source.opts.index_path and source.opts.index_path ~= "" then
		return vim.fn.expand(source.opts.index_path)
	end

	local pattern = vim.fn.stdpath("data")
		.. "/vscode-maven/vscjava.vscode-maven-*/extension/resources/IndexData"
	local paths = vim.fn.glob(pattern, false, true)
	if not paths or #paths == 0 then
		return nil
	end

	table.sort(paths)
	return paths[#paths]
end

local function execute(command, arguments, callback)
	local client = get_client()
	if not client then
		callback(nil, { message = "jdtls is not running" })
		return
	end

	client:request("workspace/executeCommand", {
		command = command,
		arguments = arguments or {},
	}, function(err, result)
		vim.schedule(function()
			callback(result, err)
		end)
	end)
end

local function ensure_index(source, callback)
	if source.index_state == "ready" then
		callback(true)
		return
	end

	if source.index_state == "loading" then
		table.insert(source.index_waiters, callback)
		return
	end

	if not get_client() then
		callback(false)
		return
	end

	local path = get_index_path(source)
	if not path then
		notify_once(source, "index-missing", "Maven completion: vscode-maven IndexData was not found.")
		callback(false)
		return
	end

	source.index_state = "loading"
	table.insert(source.index_waiters, callback)

	execute("java.maven.initializeSearcher", { path }, function(_, err)
		source.index_state = err and "idle" or "ready"
		if err then
			debug_log(source, "index init failed: %s", vim.inspect(err))
		end

		local waiters = source.index_waiters
		source.index_waiters = {}
		local ready = source.index_state == "ready"
		for _, waiter in ipairs(waiters) do
			waiter(ready)
		end
	end)
end

function M.search(source, group_id, artifact_id, callback)
	local key = (group_id or "") .. "\0" .. (artifact_id or "")
	local cached = source.jdtls_cache[key]
	if cached then
		callback(cached)
		return
	end

	local running = source.jdtls_inflight[key]
	if running then
		table.insert(running, callback)
		return
	end

	source.jdtls_inflight[key] = { callback }

	ensure_index(source, function(ready)
		if not ready then
			local waiters = source.jdtls_inflight[key] or {}
			source.jdtls_inflight[key] = nil
			for _, waiter in ipairs(waiters) do
				waiter({})
			end
			return
		end

		debug_log(source, "JDTLS g=%q a=%q", group_id or "", artifact_id or "")

		execute("java.maven.searchArtifact", {
			{
				searchType = "IDENTIFIER",
				groupId = group_id or "",
				artifactId = artifact_id or "",
			},
		}, function(result, err)
			local docs = {}
			if not err and type(result) == "table" then
				docs = Util.dedupe_docs(result)
				source.jdtls_cache[key] = docs
			end

			local waiters = source.jdtls_inflight[key] or {}
			source.jdtls_inflight[key] = nil
			for _, waiter in ipairs(waiters) do
				waiter(docs)
			end
		end)
	end)
end

return M
