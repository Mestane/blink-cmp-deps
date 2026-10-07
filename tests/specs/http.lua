local Http = require("blink_deps.http")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- vim.system is replaced so no spec ever reaches the network. Each call is
	-- recorded and answered by hand, which is what lets retries and
	-- cancellation be tested deterministically.
	--------------------------------------------------------------------------------

	local original_vim_system = vim.system
	local original_vim_schedule = vim.schedule

	local calls
	local killed

	local function install()
		calls = {}
		killed = 0

		rawset(vim, "schedule", function(fn)
			fn()
		end)

		rawset(vim, "system", function(cmd, opts, on_exit)
			table.insert(calls, {
				cmd = vim.deepcopy(cmd),
				opts = opts,
				on_exit = on_exit,
			})

			return {
				kill = function()
					killed = killed + 1
				end,
			}
		end)
	end

	local function restore()
		rawset(vim, "system", original_vim_system)
		rawset(vim, "schedule", original_vim_schedule)
	end

	local function answer(index, result)
		calls[index].on_exit(result)
	end

	local function contains(list, value)
		for _, entry in ipairs(list) do
			if entry == value then
				return true
			end
		end

		return false
	end

	--------------------------------------------------------------------------------
	-- COMMAND
	--------------------------------------------------------------------------------

	local cmd, stdin = Http.debug_command({
		url = "https://registry.test/search",
		query = {
			rows = 5,
			q = "g:org.example",
			core = "gav",
		},
		connect_timeout = 2,
		max_time = 9,
	})

	eq(cmd[1], "curl", "The transport must invoke curl")
	eq(cmd[#cmd], "https://registry.test/search", "The URL must be the final argument")
	eq(stdin, nil, "A request without headers must not write to stdin")

	ok(
		not contains(cmd, "--config"),
		"A request without headers must not read a curl config"
	)

	ok(
		not contains(cmd, "--fail-with-body"),
		"HTTP errors must be read from the status, not from curl exit 22"
	)

	local encoded = {}

	for index, value in ipairs(cmd) do
		if value == "--data-urlencode" then
			table.insert(encoded, cmd[index + 1])
		end
	end

	eq(
		encoded,
		{ "core=gav", "q=g:org.example", "rows=5" },
		"Query parameters must be emitted in a stable sorted order"
	)

	local function option(name)
		for index, value in ipairs(cmd) do
			if value == name then
				return cmd[index + 1]
			end
		end

		return nil
	end

	eq(option("--connect-timeout"), "2", "connect_timeout must reach curl")
	eq(option("--max-time"), "9", "max_time must reach curl")

	ok(
		option("-A"):match("^blink%-cmp%-deps/") ~= nil,
		"Requests must identify the plugin in the user agent"
	)

	ok(
		not contains(cmd, "--compressed"),
		"Compression must not be requested unless asked for"
	)

	ok(
		contains(
			Http.debug_command({
				url = "https://registry.test/large",
				compressed = true,
			}),
			"--compressed"
		),
		"A request for a large response must be able to ask for compression"
	)

	local post = Http.debug_command({
		url = "https://api.test/query",
		body = '{"package":{"name":"demo"}}',
	})

	eq(
		{ post[#post - 2], post[#post - 1], post[#post] },
		{ "--data-binary", '{"package":{"name":"demo"}}', "https://api.test/query" },
		"A body must be sent as given, which makes the request a POST"
	)

	ok(not contains(cmd, "--data-binary"), "A request without a body must stay a GET")

	--------------------------------------------------------------------------------
	-- HEADERS NEVER TOUCH ARGV
	--------------------------------------------------------------------------------

	local auth_cmd, auth_stdin = Http.debug_command({
		url = "https://registry.test/private",
		headers = {
			Authorization = "Bearer s3cr3t",
			Accept = 'application/json; note="x\\y"',
		},
	})

	ok(
		contains(auth_cmd, "--config"),
		"Headers must be passed through a curl config"
	)

	for _, argument in ipairs(auth_cmd) do
		ok(
			not argument:find("s3cr3t", 1, true),
			"A credential must never appear in the process arguments"
		)
	end

	eq(
		auth_stdin,
		'header = "Accept: application/json; note=\\"x\\\\y\\""\n'
			.. 'header = "Authorization: Bearer s3cr3t"\n',
		"Headers must be escaped and written to stdin in sorted order"
	)

	--------------------------------------------------------------------------------
	-- REDACTION
	--------------------------------------------------------------------------------

	eq(
		Http.redact("curl: (6) Could not resolve https://user:hunter2@nexus.test/x"),
		"curl: (6) Could not resolve https://***@nexus.test/x",
		"Credentials embedded in a URL must be redacted"
	)

	eq(
		Http.redact("https://repo.test/a@b"),
		"https://repo.test/a@b",
		"An @ in the path must not be mistaken for credentials"
	)

	eq(Http.redact(nil), "", "Redacting a missing message must not fail")

	--------------------------------------------------------------------------------
	-- SUCCESS
	--------------------------------------------------------------------------------

	install()

	local body
	local err

	Http.request({
		url = "https://registry.test/a",
		decode = "json",
	}, function(result, request_err)
		body = result
		err = request_err
	end)

	eq(#calls, 1, "A request must start exactly one process")
	eq(calls[1].opts.stdin, nil, "A request without headers must not send stdin")

	answer(1, {
		code = 0,
		stdout = '{"name":"serde"}\n200',
	})

	eq(body, { name = "serde" }, "A JSON body must be decoded")
	eq(err, nil, "A successful request must not report an error")

	-- Text body, and a body whose own last line looks like a status.
	Http.request({
		url = "https://registry.test/b",
	}, function(result, request_err)
		body = result
		err = request_err
	end)

	answer(2, {
		code = 0,
		stdout = "line one\n404\n200",
	})

	eq(body, "line one\n404", "Only the final line is the status")
	eq(err, nil, "A 200 response must not report an error")

	-- A response without the status marker is still usable.
	Http.request({
		url = "https://registry.test/c",
	}, function(result, request_err)
		body = result
		err = request_err
	end)

	answer(3, {
		code = 0,
		stdout = "<metadata/>",
	})

	eq(body, "<metadata/>", "A body without a status line must pass through")
	eq(err, nil, "A body without a status line must not be an error")

	--------------------------------------------------------------------------------
	-- HTTP ERRORS
	--------------------------------------------------------------------------------

	local function http_error(status)
		install()

		local seen_body
		local seen_err

		Http.request({
			url = "https://registry.test/x",
			decode = "json",
		}, function(result, request_err)
			seen_body = result
			seen_err = request_err
		end)

		answer(1, {
			code = 0,
			stdout = "denied\n" .. tostring(status),
		})

		eq(seen_body, nil, "An HTTP error must not produce a body")
		eq(#calls, 1, "An HTTP error must not be retried")

		return seen_err
	end

	eq(http_error(401).kind, "unauthorized", "401 must be classified")
	eq(http_error(403).kind, "forbidden", "403 must be classified")
	eq(http_error(404).kind, "not_found", "404 must be classified")
	eq(http_error(429).kind, "rate_limited", "429 must be classified")

	local server_error = http_error(503)

	eq(server_error.kind, "http", "Other statuses must be generic HTTP errors")
	eq(server_error.status, 503, "The status must be reported")
	eq(server_error.message, "HTTP 503", "The message must name the status")
	eq(server_error.body, "denied", "The error body must be kept for diagnostics")

	--------------------------------------------------------------------------------
	-- INVALID JSON
	--------------------------------------------------------------------------------

	install()

	Http.request({
		url = "https://registry.test/x",
		decode = "json",
	}, function(result, request_err)
		body = result
		err = request_err
	end)

	answer(1, {
		code = 0,
		stdout = "<html>maintenance</html>\n200",
	})

	eq(body, nil, "Invalid JSON must not produce a body")
	eq(err.kind, "decode", "Invalid JSON must be a decode error")
	eq(#calls, 1, "Invalid JSON must not be retried")

	--------------------------------------------------------------------------------
	-- RETRY
	--------------------------------------------------------------------------------

	install()

	local retries = {}
	local finished = 0

	Http.request({
		url = "https://registry.test/x",
		on_retry = function(retry_err, remaining)
			table.insert(retries, {
				kind = retry_err.kind,
				remaining = remaining,
			})
		end,
	}, function(result, request_err)
		finished = finished + 1
		body = result
		err = request_err
	end)

	answer(1, {
		code = 28,
		stderr = "curl: (28) Operation timed out",
	})

	eq(#calls, 2, "A timed out request must be retried once by default")
	eq(finished, 0, "A retried request must not call back early")

	eq(
		retries,
		{ { kind = "timeout", remaining = 0 } },
		"on_retry must report the failure and the remaining budget"
	)

	answer(2, {
		code = 0,
		stdout = "ok\n200",
	})

	eq(finished, 1, "A request must call back exactly once")
	eq(body, "ok", "A successful retry must deliver the body")
	eq(err, nil, "A successful retry must not retain the first error")

	-- Budget exhausted.
	install()

	Http.request({
		url = "https://user:hunter2@registry.test/x",
		retries = 2,
	}, function(result, request_err)
		body = result
		err = request_err
	end)

	for index = 1, 3 do
		answer(index, {
			code = 6,
			stderr = "curl: (6) Could not resolve https://user:hunter2@registry.test/x",
		})
	end

	eq(#calls, 3, "retries = 2 must mean three attempts in total")
	eq(body, nil, "An exhausted retry budget must not produce a body")
	eq(err.kind, "dns", "A resolution failure must be classified")
	eq(err.code, 6, "The curl exit code must be reported")

	ok(
		not err.message:find("hunter2", 1, true),
		"An error message must never contain credentials"
	)

	-- A failure that repeats identically is not retried.
	install()

	Http.request({
		url = "https://registry.test/x",
	}, function(_, request_err)
		err = request_err
	end)

	answer(1, {
		code = 60,
		stderr = "curl: (60) SSL certificate problem",
	})

	eq(#calls, 1, "A certificate failure must not be retried")
	eq(err.kind, "tls", "A certificate failure must be classified")

	-- retries = 0 disables the retry.
	install()

	Http.request({
		url = "https://registry.test/x",
		retries = 0,
	}, function(_, request_err)
		err = request_err
	end)

	answer(1, {
		code = 28,
		stderr = "",
	})

	eq(#calls, 1, "retries = 0 must disable retrying")
	eq(err.kind, "timeout", "The failure must still be classified")
	eq(err.message, "timeout", "An empty stderr must fall back to the kind")

	--------------------------------------------------------------------------------
	-- CANCELLATION
	--------------------------------------------------------------------------------

	install()

	local cancelled_calls = 0

	local cancel = Http.request({
		url = "https://registry.test/x",
	}, function()
		cancelled_calls = cancelled_calls + 1
	end)

	cancel()
	cancel()

	eq(killed, 1, "Cancelling must kill the process exactly once")

	answer(1, {
		code = 28,
		stderr = "curl: (28) Operation timed out",
	})

	eq(cancelled_calls, 0, "A cancelled request must never call back")
	eq(#calls, 1, "A cancelled request must not be retried")

	--------------------------------------------------------------------------------
	-- INVALID REQUESTS
	--------------------------------------------------------------------------------

	install()

	local function invalid(spec)
		local seen

		Http.request(spec, function(_, request_err)
			seen = request_err
		end)

		return seen
	end

	eq(invalid(nil).kind, "invalid", "A missing spec must be rejected")
	eq(invalid({}).kind, "invalid", "A missing URL must be rejected")

	eq(
		invalid({ url = "file:///etc/passwd" }).kind,
		"invalid",
		"Only http and https URLs may be requested"
	)

	eq(
		invalid({
			url = "https://registry.test/x",
			headers = {
				Authorization = 'Bearer a\nurl = "https://evil.test"',
			},
		}).kind,
		"invalid",
		"A header value must not be able to inject a config directive"
	)

	eq(
		invalid({
			url = "https://registry.test/x",
			headers = {
				["X-A: b\r\nX-C"] = "d",
			},
		}).kind,
		"invalid",
		"A header name must not be able to inject a second header"
	)

	eq(#calls, 0, "An invalid request must never start a process")

	restore()
end
