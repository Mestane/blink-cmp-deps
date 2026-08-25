local Util = require("blink_deps.util")
local VERSION = require("blink_deps.version")

local M = {}

M.URL = "https://central.sonatype.com/solrsearch/select"
M.HTTP_CONNECT_TIMEOUT = 3
M.HTTP_MAX_TIME = 7

local function debug_log(source, fmt, ...)
	if not source.opts.debug then
		return
	end
	local message = string.format(fmt, ...)
	vim.schedule(function()
        vim.notify("[blink-cmp-deps] " .. message, vim.log.levels.DEBUG)
	end)
end

local function run_query(source, args, callback)
	local cmd = {
		"curl",
		"-sS",
		"--fail-with-body",
		"--connect-timeout",
		tostring(source.opts.connect_timeout or M.HTTP_CONNECT_TIMEOUT),
		"--max-time",
		tostring(source.opts.max_time or M.HTTP_MAX_TIME),
		"-A",
		"blink-cmp-deps/" .. VERSION,
		"--get",
		source.opts.central_url or M.URL,
	}
	for key, value in pairs(args) do
		table.insert(cmd, "--data-urlencode")
		table.insert(cmd, key .. "=" .. tostring(value))
	end

	vim.system(cmd, { text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				callback(nil, Util.trim(result.stderr or "curl failed"))
				return
			end

			local ok, decoded = pcall(vim.json.decode, result.stdout or "")
			if not ok or type(decoded) ~= "table" then
				callback(nil, "invalid JSON")
				return
			end

			callback(decoded, nil)
		end)
	end)
end

function M.search(source, key, args, callback)
	local cached = source.central_cache[key]
	if cached then
		callback(cached, nil)
		return
	end

	local running = source.central_inflight[key]
	if running then
		table.insert(running, callback)
		return
	end

	source.central_inflight[key] = { callback }
	debug_log(source, "Central %s", args.q or "")

	run_query(source, args, function(data, err)
		local docs = {}
		if not err and data and data.response then
			docs = Util.dedupe_docs(data.response.docs or {})
			source.central_cache[key] = docs
		end

		local waiters = source.central_inflight[key] or {}
		source.central_inflight[key] = nil
		for _, waiter in ipairs(waiters) do
			waiter(docs, err)
		end
	end)
end

return M
