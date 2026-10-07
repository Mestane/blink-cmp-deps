local VERSION = require("blink_deps.version")

--------------------------------------------------------------------------------
-- HTTP TRANSPORT
--
-- The one place that knows how to talk HTTP. Registry adapters describe a
-- request and receive either a body or a structured error; none of them build
-- curl command lines, classify exit codes or decide what is worth retrying.
--
-- Nothing here knows about Maven, Nexus or any other ecosystem.
--------------------------------------------------------------------------------

local M = {}

-- Names the client and says where to reach its maintainers. Registries ask
-- for this, and crates.io refuses requests that do not identify themselves.
M.USER_AGENT =
	"blink-cmp-deps/"
	.. VERSION
	.. " (https://github.com/Mestane/blink-cmp-deps)"

M.CONNECT_TIMEOUT = 3
M.MAX_TIME = 7
M.RETRIES = 1

-- Written after the body so the status survives without --fail-with-body,
-- which collapses every HTTP error into the same exit code 22.
local STATUS_MARKER = "\n%{http_code}"

--------------------------------------------------------------------------------
-- ERROR CLASSIFICATION
--
-- Callers and :checkhealth need to tell "you are offline" from "your token is
-- wrong" from "that package does not exist". A bare stderr string cannot.
--------------------------------------------------------------------------------

local CURL_KINDS = {
	[6] = "dns", -- could not resolve host
	[7] = "connect", -- failed to connect
	[28] = "timeout", -- operation timed out
	[35] = "tls", -- TLS connect error
	[52] = "transport", -- empty reply from server
	[55] = "transport", -- failed sending data
	[56] = "transport", -- failure receiving data
	[60] = "tls", -- peer certificate cannot be verified
}

-- A stalled or dropped connection is worth repeating. A certificate that
-- cannot be verified or a rejected query fails the same way every time.
local RETRYABLE_CURL_CODES = {
	[6] = true,
	[7] = true,
	[28] = true,
	[35] = true,
	[52] = true,
	[55] = true,
	[56] = true,
}

local STATUS_KINDS = {
	[401] = "unauthorized",
	[403] = "forbidden",
	[404] = "not_found",
	[429] = "rate_limited",
}

local function status_kind(status)
	return STATUS_KINDS[status] or "http"
end

--------------------------------------------------------------------------------
-- REDACTION
--
-- curl repeats the URL in its error text. Credentials embedded as
-- https://user:secret@host must never reach a log or a notification.
--------------------------------------------------------------------------------

function M.redact(text)
	if type(text) ~= "string" then
		return ""
	end

	return (text:gsub("(%a[%w+.-]*://)[^/@%s]+@", "%1***@"))
end

local function make_error(kind, message, extra)
	local err = extra or {}

	err.kind = kind
	err.message = M.redact(vim.trim(message or ""))

	if err.message == "" then
		err.message = kind
	end

	return err
end

--------------------------------------------------------------------------------
-- HEADERS
--
-- Headers travel through curl's config on stdin instead of argv. Anything in
-- argv is readable by every local user through the process list, and headers
-- are where registry tokens live.
--------------------------------------------------------------------------------

local function header_config(headers)
	if type(headers) ~= "table" then
		return nil, nil
	end

	local names = {}

	for name in pairs(headers) do
		table.insert(names, name)
	end

	if #names == 0 then
		return nil, nil
	end

	table.sort(names)

	local lines = {}

	for _, name in ipairs(names) do
		local value = headers[name]

		if type(name) ~= "string"
			or type(value) ~= "string"
			or name:find("[%c:]")
			or value:find("%c")
		then
			-- A control character would let a value smuggle in a second
			-- header or a second config directive.
			return nil, "invalid header"
		end

		local escaped = (name .. ": " .. value)
			:gsub("\\", "\\\\")
			:gsub('"', '\\"')

		table.insert(lines, 'header = "' .. escaped .. '"')
	end

	return table.concat(lines, "\n") .. "\n", nil
end

--------------------------------------------------------------------------------
-- COMMAND
--------------------------------------------------------------------------------

local function build_command(spec, has_headers)
	local cmd = {
		"curl",
		"-sS",
		"--connect-timeout",
		tostring(spec.connect_timeout or M.CONNECT_TIMEOUT),
		"--max-time",
		tostring(spec.max_time or M.MAX_TIME),
		"-A",
		spec.user_agent or M.USER_AGENT,
		"-w",
		STATUS_MARKER,
	}

	if has_headers then
		table.insert(cmd, "--config")
		table.insert(cmd, "-")
	end

	if type(spec.query) == "table" and next(spec.query) ~= nil then
		-- Sorted so the same request always produces the same command.
		local keys = {}

		for key in pairs(spec.query) do
			table.insert(keys, key)
		end

		table.sort(keys, function(left, right)
			return tostring(left) < tostring(right)
		end)

		table.insert(cmd, "--get")

		for _, key in ipairs(keys) do
			table.insert(cmd, "--data-urlencode")
			table.insert(
				cmd,
				tostring(key) .. "=" .. tostring(spec.query[key])
			)
		end
	end

	table.insert(cmd, spec.url)

	return cmd
end

--------------------------------------------------------------------------------
-- RESPONSE
--------------------------------------------------------------------------------

local function split_status(stdout)
	local body, status = (stdout or ""):match("^(.*)\n(%d%d%d)$")

	if not body then
		return stdout or "", nil
	end

	return body, tonumber(status)
end

local function interpret(spec, result)
	if result.code ~= 0 then
		return nil, make_error(
			CURL_KINDS[result.code] or "transport",
			result.stderr or "curl failed",
			{ code = result.code }
		)
	end

	local body, status = split_status(result.stdout)

	-- 000 means curl never received a status line.
	if status and status ~= 0 and (status < 200 or status >= 300) then
		return nil, make_error(
			status_kind(status),
			"HTTP " .. tostring(status),
			{ status = status, body = body }
		)
	end

	if spec.decode == "json" then
		local ok, decoded = pcall(vim.json.decode, body)

		if not ok or type(decoded) ~= "table" then
			return nil, make_error("decode", "invalid JSON", {
				status = status,
			})
		end

		return decoded, nil
	end

	return body, nil
end

--------------------------------------------------------------------------------
-- REQUEST
--
-- spec:
--   url              string, http or https
--   query            table of query parameters, optional
--   headers          table of header name to value, optional
--   decode           "json" to decode the body, otherwise the body is text
--   connect_timeout  seconds
--   max_time         seconds
--   retries          transport failures to repeat, default M.RETRIES
--   on_retry         function(err, remaining), optional
--
-- callback(body, err) runs on the main loop, exactly once, unless the request
-- was cancelled first. err is { kind, message, code?, status?, body? }.
--
-- Returns a function that cancels the request.
--------------------------------------------------------------------------------

function M.request(spec, callback)
	if type(spec) ~= "table"
		or type(spec.url) ~= "string"
		or not spec.url:match("^https?://")
	then
		callback(nil, make_error("invalid", "invalid request URL"))

		return function() end
	end

	local stdin, header_err = header_config(spec.headers)

	if header_err then
		callback(nil, make_error("invalid", header_err))

		return function() end
	end

	local cmd = build_command(spec, stdin ~= nil)

	local remaining = M.RETRIES

	if type(spec.retries) == "number" then
		remaining = math.max(spec.retries, 0)
	end

	local cancelled = false
	local handle

	local attempt

	attempt = function()
		handle = vim.system(
			cmd,
			{ text = true, stdin = stdin },
			function(result)
				vim.schedule(function()
					if cancelled then
						return
					end

					local body, err = interpret(spec, result)

					if err
						and remaining > 0
						and RETRYABLE_CURL_CODES[err.code]
					then
						remaining = remaining - 1

						if type(spec.on_retry) == "function" then
							spec.on_retry(err, remaining)
						end

						attempt()
						return
					end

					callback(body, err)
				end)
			end
		)
	end

	attempt()

	return function()
		if cancelled then
			return
		end

		cancelled = true

		if type(handle) == "table" and type(handle.kill) == "function" then
			pcall(handle.kill, handle, "sigterm")
		end
	end
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS / TESTS
--------------------------------------------------------------------------------

function M.debug_command(spec)
	local stdin = header_config(spec.headers)

	return build_command(spec, stdin ~= nil), stdin
end

return M
