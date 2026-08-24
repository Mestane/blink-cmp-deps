local Source = {}

Source.VERSION = "2026-08-24-r5"

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local CENTRAL_URL = "https://central.sonatype.com/solrsearch/select"
local GROUP_MIN_CHARS = 2
local GROUP_ROWS = 200
local ARTIFACT_ROWS = 200
local VERSION_ROWS = 200
local HTTP_CONNECT_TIMEOUT = 3
local HTTP_MAX_TIME = 7

local KIND = {
	Field = 5,
	Module = 9,
	Value = 12,
	Constant = 21,
}

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

-- Small cold-start catalog. This is not the primary data source; it guarantees
-- useful IDE-like results immediately while the local JDTLS index / Central
-- queries warm the session cache. Every discovered group is remembered for the
-- remainder of the Neovim session.
local BUILTIN_GROUP_HINTS = {
	"org.springframework",
	"org.springframework.boot",
	"org.springframework.data",
	"org.springframework.security",
	"org.springframework.kafka",
	"org.springframework.cloud",
	"org.springframework.batch",
	"org.springframework.ws",
	"org.apache.kafka",
	"org.apache.maven.plugins",
	"org.apache.logging.log4j",
	"org.apache.commons",
	"org.junit.jupiter",
	"org.junit.platform",
	"org.junit.vintage",
	"org.mockito",
	"org.hibernate.orm",
	"org.hibernate.validator",
	"org.postgresql",
	"org.mapstruct",
	"org.projectlombok",
	"org.flywaydb",
	"org.liquibase",
	"org.slf4j",
	"com.google.guava",
	"com.google.code.gson",
	"com.google.protobuf",
	"com.google.inject",
	"com.fasterxml.jackson.core",
	"com.fasterxml.jackson.databind",
	"com.fasterxml.jackson.datatype",
	"com.fasterxml.jackson.dataformat",
	"com.mysql",
	"io.micrometer",
	"io.projectreactor",
	"io.projectreactor.netty",
	"io.grpc",
	"io.netty",
	"ch.qos.logback",
}

local COORDINATE_FIELDS = {
	dependency = {
		groupId = true,
		artifactId = true,
		version = true,
		scope = true,
		type = true,
		classifier = true,
		optional = true,
	},
	exclusion = {
		groupId = true,
		artifactId = true,
	},
	plugin = {
		groupId = true,
		artifactId = true,
		version = true,
		extensions = true,
		inherited = true,
	},
	reportPlugin = {
		groupId = true,
		artifactId = true,
		version = true,
		inherited = true,
	},
	parent = {
		groupId = true,
		artifactId = true,
		version = true,
	},
	extension = {
		groupId = true,
		artifactId = true,
		version = true,
	},
}

local STATIC_VALUES = {
	scope = {
		{ value = "compile", description = "Default dependency scope" },
		{ value = "provided", description = "Provided by the runtime/container" },
		{ value = "runtime", description = "Required at runtime" },
		{ value = "test", description = "Available only for tests" },
		{ value = "system", description = "Explicit local system dependency" },
		{ value = "import", description = "Import dependencyManagement from a POM" },
	},
	type = {
		{ value = "jar", description = "Java archive" },
		{ value = "test-jar", description = "Test JAR" },
		{ value = "pom", description = "Maven POM" },
		{ value = "war", description = "Web application archive" },
		{ value = "ear", description = "Enterprise application archive" },
		{ value = "ejb", description = "EJB archive" },
		{ value = "ejb-client", description = "EJB client archive" },
		{ value = "rar", description = "Resource adapter archive" },
		{ value = "maven-plugin", description = "Maven plugin" },
		{ value = "java-source", description = "Java source artifact" },
		{ value = "javadoc", description = "Javadoc artifact" },
	},
	classifier = {
		{ value = "sources", description = "Source archive" },
		{ value = "javadoc", description = "Javadoc archive" },
		{ value = "tests", description = "Test classes archive" },
		{ value = "test-sources", description = "Test sources archive" },
	},
	optional = {
		{ value = "true", description = "Do not expose dependency transitively" },
		{ value = "false", description = "Normal transitive dependency" },
	},
	packaging = {
		{ value = "jar", description = "Java archive" },
		{ value = "war", description = "Web application" },
		{ value = "pom", description = "Aggregator / parent POM" },
		{ value = "ear", description = "Enterprise application" },
		{ value = "ejb", description = "EJB module" },
		{ value = "rar", description = "Resource adapter" },
		{ value = "maven-plugin", description = "Maven plugin project" },
	},
	extensions = {
		{ value = "true", description = "Load plugin extensions" },
		{ value = "false", description = "Do not load plugin extensions" },
	},
	inherited = {
		{ value = "true", description = "Inherit configuration in child projects" },
		{ value = "false", description = "Do not inherit configuration" },
	},
	phase = {
		{ value = "validate", description = "Validate project" },
		{ value = "initialize", description = "Initialize build state" },
		{ value = "generate-sources", description = "Generate source code" },
		{ value = "process-sources", description = "Process source code" },
		{ value = "generate-resources", description = "Generate resources" },
		{ value = "process-resources", description = "Process resources" },
		{ value = "compile", description = "Compile main sources" },
		{ value = "process-classes", description = "Post-process compiled classes" },
		{ value = "generate-test-sources", description = "Generate test sources" },
		{ value = "process-test-sources", description = "Process test sources" },
		{ value = "generate-test-resources", description = "Generate test resources" },
		{ value = "process-test-resources", description = "Process test resources" },
		{ value = "test-compile", description = "Compile test sources" },
		{ value = "process-test-classes", description = "Post-process test classes" },
		{ value = "test", description = "Run unit tests" },
		{ value = "prepare-package", description = "Prepare package" },
		{ value = "package", description = "Create project package" },
		{ value = "pre-integration-test", description = "Prepare integration tests" },
		{ value = "integration-test", description = "Run integration tests" },
		{ value = "post-integration-test", description = "Clean up integration tests" },
		{ value = "verify", description = "Verify project" },
		{ value = "install", description = "Install into local repository" },
		{ value = "deploy", description = "Deploy to remote repository" },
		{ value = "pre-clean", description = "Before clean phase" },
		{ value = "clean", description = "Clean build output" },
		{ value = "post-clean", description = "After clean phase" },
		{ value = "pre-site", description = "Before site generation" },
		{ value = "site", description = "Generate project site" },
		{ value = "post-site", description = "After site generation" },
		{ value = "site-deploy", description = "Deploy project site" },
	},
	updatePolicy = {
		{ value = "always", description = "Check for updates on every build" },
		{ value = "daily", description = "Check once per day" },
		{ value = "never", description = "Never check automatically" },
	},
	checksumPolicy = {
		{ value = "fail", description = "Fail on checksum mismatch" },
		{ value = "warn", description = "Warn on checksum mismatch" },
		{ value = "ignore", description = "Ignore checksum mismatch" },
	},
	layout = {
		{ value = "default", description = "Default Maven repository layout" },
		{ value = "legacy", description = "Legacy Maven repository layout" },
	},
}

--------------------------------------------------------------------------------
-- SMALL HELPERS
--------------------------------------------------------------------------------

local function lower(value)
	return (value or ""):lower()
end

local function trim(value)
	return vim.trim(value or "")
end

local function starts_with(value, prefix)
	return value:sub(1, #prefix) == prefix
end

local function is_pom()
	return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t") == "pom.xml"
end

local function debug_log(self, fmt, ...)
	if not self.opts.debug then
		return
	end
	local message = string.format(fmt, ...)
	vim.schedule(function()
		vim.notify("[Maven] " .. message, vim.log.levels.DEBUG)
	end)
end

local function notify_once(self, key, message, level)
	if self.notified[key] then
		return
	end
	self.notified[key] = true
	vim.schedule(function()
		vim.notify(message, level or vim.log.levels.WARN)
	end)
end

local function list_to_set(values)
	local set = {}
	for _, value in ipairs(values or {}) do
		set[value] = true
	end
	return set
end

local function sorted_keys(set)
	local result = {}
	for value in pairs(set or {}) do
		table.insert(result, value)
	end
	table.sort(result)
	return result
end

local function dedupe_docs(docs)
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

local function extract_groups(docs)
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

local function extract_artifacts(docs, group_id)
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

local function response(items, incomplete)
	return {
		items = items,
		is_incomplete_forward = incomplete == true,
		is_incomplete_backward = incomplete == true,
	}
end

local function make_range(context, value)
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

--------------------------------------------------------------------------------
-- SOURCE
--------------------------------------------------------------------------------

function Source.new(opts, config)
	-- Current blink.cmp calls new(opts, provider_config). Keep a compatibility
	-- fallback for older configs that passed provider_config as the first arg.
	if type(opts) ~= "table" then
		opts = {}
	end
	if next(opts) == nil and type(config) == "table" and type(config.opts) == "table" then
		opts = config.opts
	end

	local group_memory = list_to_set(BUILTIN_GROUP_HINTS)

	return setmetatable({
		opts = opts,
		group_memory = group_memory,
		central_cache = {},
		central_inflight = {},
		jdtls_cache = {},
		jdtls_inflight = {},
		artifact_catalog = {},
		version_catalog = {},
		index_state = "idle",
		index_waiters = {},
		notified = {},
	}, {
		__index = Source,
	})
end

function Source:enabled()
	return is_pom()
end

function Source:get_trigger_characters()
	return { ".", ">" }
end

--------------------------------------------------------------------------------
-- XML CONTEXT
--------------------------------------------------------------------------------

local function current_context()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local row = cursor[1]
	local col = cursor[2]
	local line = vim.api.nvim_get_current_line()
	local before_cursor = line:sub(1, col)
	local tag, value = before_cursor:match("<([%w_:%-]+)>([^<]*)$")
	if not tag then
		return nil
	end
	return {
		tag = tag:match("([^:]+)$") or tag,
		value = value or "",
		row = row,
		col = col,
	}
end

local function local_tag_name(name)
	return name:match("([^:]+)$") or name
end

local function find_block_end(lines, start_row, block_type)
	local depth = 0
	for row = start_row, #lines do
		for slash, raw_name, tail in lines[row]:gmatch("<(%/?)([%w_:%-]+)(.-)>") do
			local name = local_tag_name(raw_name)
			if name == block_type then
				if slash == "/" then
					depth = depth - 1
					if depth <= 0 then
						return row
					end
				elseif not tail:match("/%s*$") then
					depth = depth + 1
				end
			end
		end
	end
	return math.min(#lines, start_row + 80)
end

local function find_coordinate_block(row, col)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local stack = {}
	for current_row = 1, row do
		local text = lines[current_row] or ""
		if current_row == row then
			text = text:sub(1, col)
		end
		for slash, raw_name, tail in text:gmatch("<(%/?)([%w_:%-]+)(.-)>") do
			local name = local_tag_name(raw_name)
			if COORDINATE_FIELDS[name] then
				if slash == "/" then
					for index = #stack, 1, -1 do
						if stack[index].type == name then
							table.remove(stack, index)
							break
						end
					end
				elseif not tail:match("/%s*$") then
					table.insert(stack, {
						type = name,
						start_row = current_row,
					})
				end
			end
		end
	end
	local current = stack[#stack]
	if not current then
		return nil
	end
	return {
		type = current.type,
		start_row = current.start_row,
		end_row = find_block_end(lines, current.start_row, current.type),
		lines = lines,
	}
end

local function get_tag_value(block, tag)
	if not block then
		return nil
	end
	for row = block.start_row, block.end_row do
		local line = block.lines[row]
		if line then
			local value = line:match("<" .. tag .. ">(.-)</" .. tag .. ">")
			if value and value ~= "" then
				return trim(value)
			end
		end
	end
	return nil
end

local function supports_field(block, field)
	return block
		and COORDINATE_FIELDS[block.type]
		and COORDINATE_FIELDS[block.type][field] == true
end

local function coordinate_group_id(block)
	local group_id = get_tag_value(block, "groupId")
	if group_id and group_id ~= "" then
		return group_id
	end
	if block and (block.type == "plugin" or block.type == "reportPlugin") then
		return "org.apache.maven.plugins"
	end
	return nil
end

--------------------------------------------------------------------------------
-- JDTLS MAVEN INDEX
--------------------------------------------------------------------------------

local function get_jdtls_client()
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
			and starts_with(filename, root)
			and #root > best_len
		then
			best = client
			best_len = #root
		end
	end
	return best or clients[1]
end

local function get_maven_index_path(self)
	if self.opts.index_path and self.opts.index_path ~= "" then
		return vim.fn.expand(self.opts.index_path)
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

local function execute_jdtls_command(command, arguments, callback)
	local client = get_jdtls_client()
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

local function ensure_maven_index(self, callback)
	if self.index_state == "ready" then
		callback(true)
		return
	end
	if self.index_state == "loading" then
		table.insert(self.index_waiters, callback)
		return
	end
	if not get_jdtls_client() then
		callback(false)
		return
	end
	local path = get_maven_index_path(self)
	if not path then
		notify_once(self, "index-missing", "Maven completion: vscode-maven IndexData was not found.")
		callback(false)
		return
	end
	self.index_state = "loading"
	table.insert(self.index_waiters, callback)
	execute_jdtls_command("java.maven.initializeSearcher", { path }, function(_, err)
		self.index_state = err and "idle" or "ready"
		if err then
			debug_log(self, "index init failed: %s", vim.inspect(err))
		end
		local waiters = self.index_waiters
		self.index_waiters = {}
		local ready = self.index_state == "ready"
		for _, waiter in ipairs(waiters) do
			waiter(ready)
		end
	end)
end

local function jdtls_search(self, group_id, artifact_id, callback)
	local key = (group_id or "") .. "\0" .. (artifact_id or "")
	local cached = self.jdtls_cache[key]
	if cached then
		callback(cached)
		return
	end
	local running = self.jdtls_inflight[key]
	if running then
		table.insert(running, callback)
		return
	end
	self.jdtls_inflight[key] = { callback }
	ensure_maven_index(self, function(ready)
		if not ready then
			local waiters = self.jdtls_inflight[key] or {}
			self.jdtls_inflight[key] = nil
			for _, waiter in ipairs(waiters) do
				waiter({})
			end
			return
		end
		debug_log(self, "JDTLS g=%q a=%q", group_id or "", artifact_id or "")
		execute_jdtls_command("java.maven.searchArtifact", {
			{
				searchType = "IDENTIFIER",
				groupId = group_id or "",
				artifactId = artifact_id or "",
			},
		}, function(result, err)
			local docs = {}
			if not err and type(result) == "table" then
				docs = dedupe_docs(result)
				self.jdtls_cache[key] = docs
			end
			local waiters = self.jdtls_inflight[key] or {}
			self.jdtls_inflight[key] = nil
			for _, waiter in ipairs(waiters) do
				waiter(docs)
			end
		end)
	end)
end

--------------------------------------------------------------------------------
-- CENTRAL SEARCH
--------------------------------------------------------------------------------

local function run_central_query(self, args, callback)
	local cmd = {
		"curl",
		"-sS",
		"--fail-with-body",
		"--connect-timeout",
		tostring(self.opts.connect_timeout or HTTP_CONNECT_TIMEOUT),
		"--max-time",
		tostring(self.opts.max_time or HTTP_MAX_TIME),
		"-A",
		"nvim-maven-completion/2.0",
		"--get",
		self.opts.central_url or CENTRAL_URL,
	}
	for key, value in pairs(args) do
		table.insert(cmd, "--data-urlencode")
		table.insert(cmd, key .. "=" .. tostring(value))
	end
	vim.system(cmd, { text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				callback(nil, trim(result.stderr or "curl failed"))
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

local function central_search(self, key, args, callback)
	local cached = self.central_cache[key]
	if cached then
		callback(cached, nil)
		return
	end
	local running = self.central_inflight[key]
	if running then
		table.insert(running, callback)
		return
	end
	self.central_inflight[key] = { callback }
	debug_log(self, "Central %s", args.q or "")
	run_central_query(self, args, function(data, err)
		local docs = {}
		if not err and data and data.response then
			docs = dedupe_docs(data.response.docs or {})
			self.central_cache[key] = docs
		end
		local waiters = self.central_inflight[key] or {}
		self.central_inflight[key] = nil
		for _, waiter in ipairs(waiters) do
			waiter(docs, err)
		end
	end)
end

--------------------------------------------------------------------------------
-- GROUP COMPLETION
--------------------------------------------------------------------------------

local function is_reverse_domain_qualified(value)
	local v = lower(value)
	for _, prefix in ipairs(REVERSE_DOMAIN_PREFIXES) do
		if starts_with(v, prefix) then
			return true
		end
	end
	return false
end

local function split_tokens(value)
	local tokens = {}
	for token in lower(value):gmatch("[%w]+") do
		if token ~= "" then
			table.insert(tokens, token)
		end
	end
	return tokens
end

local function qualified_parent_and_tail(value)
	local parent, tail = value:match("^(.*)%.([^%.]*)$")
	if not parent then
		return nil, value
	end
	return parent, tail or ""
end

local function semantic_group_allowed(group, value)
	local v = lower(trim(value))
	if v == "" then
		return true
	end
	if is_reverse_domain_qualified(v) then
		local parent, tail = qualified_parent_and_tail(v)
		if parent and parent ~= "" then
			-- Once the user has typed a reverse-domain namespace, keep candidates
			-- inside that namespace. Blink still performs the final fuzzy filtering.
			local namespace = parent .. "."
			if not starts_with(lower(group), namespace) and not starts_with(lower(group), v) then
				return false
			end
			if tail == "" then
				return true
			end
		end
	end
	return true
end

local function group_score_offset(group, value)
	local g = lower(group)
	local v = lower(trim(value))
	if v == "" then
		return 0
	end
	if g == v then
		return 20
	end
	if starts_with(g, v) then
		return 12
	end
	local score = 0
	for _, token in ipairs(split_tokens(v)) do
		if #token >= 2 and g:find(token, 1, true) then
			score = score + 3
		end
	end
	return math.min(score, 9)
end

local function build_group_item(context, ctx, group, source)
	return {
		label = group,
		kind = KIND.Module,
		score_offset = group_score_offset(group, ctx.value),
		labelDetails = {
			description = source or "Maven",
		},
		textEdit = {
			range = make_range(context, ctx.value),
			newText = group,
		},
		data = {
			maven = {
				kind = "group",
				groupId = group,
			},
		},
	}
end

local function remember_groups(self, groups)
	for _, group in ipairs(groups or {}) do
		if group and group ~= "" then
			self.group_memory[group] = true
		end
	end
end

local function plan_group_central_queries(value)
	local v = lower(trim(value))
	if #v < GROUP_MIN_CHARS then
		return {}
	end

	local plans = {}
	if is_reverse_domain_qualified(v) then
		local parent, tail = qualified_parent_and_tail(v)
		if parent and parent ~= "" and #tail >= 2 then
			-- Stable query bucket: ka/kaf/kafka all reuse parent + first 2 chars.
			local seed = tail:sub(1, 2)
			local q = "g:" .. parent .. "." .. seed .. "*"
			table.insert(plans, {
				key = "group:q:" .. q,
				q = q,
			})
		elseif #v >= 6 and not v:match("%.$") then
			local q = "g:" .. v .. "*"
			table.insert(plans, {
				key = "group:q:" .. q,
				q = q,
			})
		end
		return plans
	end

	local tokens = split_tokens(v)
	if #tokens >= 2 then
		local first = tokens[1]
		local last = tokens[#tokens]
		if #first >= 3 and #last >= 2 then
			local q = "g:*" .. first .. "*" .. last:sub(1, 2) .. "*"
			table.insert(plans, {
				key = "group:q:" .. q,
				q = q,
			})
		end
	elseif #tokens == 1 and #tokens[1] >= 3 then
		local seed = tokens[1]:sub(1, math.min(4, #tokens[1]))
		local q_group = "g:*" .. seed .. "*"
		table.insert(plans, {
			key = "group:q:" .. q_group,
			q = q_group,
		})
		-- Basic search can discover a group through a matching artifactId.
		-- It is supplementary; Blink will discard groups that do not match.
		table.insert(plans, {
			key = "group:basic:" .. seed,
			q = seed,
		})
	end
	return plans
end

local function plan_group_jdtls_query(value)
	local v = lower(trim(value))
	if #v < GROUP_MIN_CHARS then
		return nil
	end
	if is_reverse_domain_qualified(v) then
		return v, ""
	end
	local tokens = split_tokens(v)
	if #tokens == 0 then
		return nil
	end
	return "", tokens[#tokens]
end

local function complete_group(self, context, ctx, callback)
	local cancelled = false
	local sent = {}
	local called = false

	local function emit(groups, source)
		if cancelled then
			return
		end
		local items = {}
		for _, group in ipairs(groups or {}) do
			if not sent[group] and semantic_group_allowed(group, ctx.value) then
				sent[group] = true
				table.insert(items, build_group_item(context, ctx, group, source))
			end
		end
		if #items > 0 or not called then
			called = true
			callback(response(items, true))
		end
	end

	-- Important: this is synchronous. The completion menu receives useful
	-- candidates before any JDTLS or HTTP operation can be cancelled by the next
	-- keystroke. In particular, org.springframework.kafka is always available.
	emit(sorted_keys(self.group_memory), "Maven")

	if #trim(ctx.value) < GROUP_MIN_CHARS then
		return function()
			cancelled = true
		end
	end

	local jg, ja = plan_group_jdtls_query(ctx.value)
	if jg ~= nil then
		jdtls_search(self, jg, ja, function(docs)
			local groups = extract_groups(docs)
			remember_groups(self, groups)
			emit(groups, "Maven Index")
		end)
	end

	for _, plan in ipairs(plan_group_central_queries(ctx.value)) do
		central_search(self, plan.key, {
			q = plan.q,
			rows = tostring(GROUP_ROWS),
			wt = "json",
		}, function(docs, err)
			if err then
				debug_log(self, "group query failed (%s): %s", plan.q, err)
				return
			end
			local groups = extract_groups(docs)
			remember_groups(self, groups)
			emit(groups, "Maven Central")
		end)
	end

	return function()
		cancelled = true
	end
end

--------------------------------------------------------------------------------
-- ARTIFACT COMPLETION
--------------------------------------------------------------------------------

local function artifact_score_offset(artifact, value)
	local a = lower(artifact)
	local v = lower(trim(value))
	if v == "" then
		return 0
	end
	if a == v then
		return 20
	end
	if a:find(v, 1, true) then
		return 8
	end
	return 0
end

local function build_artifact_item(context, ctx, group_id, entry, source)
	return {
		label = entry.artifact,
		kind = KIND.Field,
		score_offset = artifact_score_offset(entry.artifact, ctx.value),
		labelDetails = {
			description = source or group_id,
		},
		textEdit = {
			range = make_range(context, ctx.value),
			newText = entry.artifact,
		},
		data = {
			maven = {
				kind = "artifact",
				groupId = group_id,
				artifactId = entry.artifact,
				latestVersion = entry.latestVersion or "unknown",
			},
		},
	}
end

local function artifact_target_seed(value)
	local v = lower(trim(value))
	if #v < 2 then
		return nil
	end
	return v:sub(1, math.min(4, #v))
end

local function complete_artifact(self, context, ctx, block, callback)
	local group_id = coordinate_group_id(block)
	if not group_id or group_id == "" then
		callback(response({}, true))
		return nil
	end

	local cancelled = false
	local sent = {}
	local called = false

	local function emit(entries, source)
		if cancelled then
			return
		end
		local items = {}
		for _, entry in ipairs(entries or {}) do
			if entry.artifact and not sent[entry.artifact] then
				sent[entry.artifact] = true
				table.insert(items, build_artifact_item(context, ctx, group_id, entry, source))
			end
		end
		if #items > 0 or not called then
			called = true
			callback(response(items, true))
		end
	end

	local cached = self.artifact_catalog[group_id]
	if cached then
		emit(cached, group_id)
	else
		-- Required first callback for Blink; async sources may append later.
		emit({}, group_id)
	end

	-- Local bundled index is an immediate fallback and does not control freshness.
	jdtls_search(self, group_id, "", function(docs)
		emit(extract_artifacts(docs, group_id), "Maven Index")
	end)

	local exact_key = "artifact:group:" .. group_id
	central_search(self, exact_key, {
		q = 'g:' .. group_id,
		rows = tostring(ARTIFACT_ROWS),
		wt = "json",
	}, function(docs, err)
		if err then
			notify_once(
				self,
				"artifact:" .. group_id,
				"Maven completion: artifact catalog request failed: " .. err
			)
			return
		end
		local entries = extract_artifacts(docs, group_id)
		self.artifact_catalog[group_id] = entries
		emit(entries, group_id)
	end)

	-- The first Central page is not a complete group index. A targeted query
	-- prevents dependencies outside that page from disappearing while typing.
	local seed = artifact_target_seed(ctx.value)
	if seed then
		local q = 'g:' .. group_id .. ' AND a:*' .. seed .. '*'
		central_search(self, "artifact:target:" .. group_id .. ":" .. seed, {
			q = q,
			rows = "100",
			wt = "json",
		}, function(docs, err)
			if not err then
				emit(extract_artifacts(docs, group_id), group_id)
			end
		end)
	end

	return function()
		cancelled = true
	end
end

--------------------------------------------------------------------------------
-- VERSION COMPLETION
--------------------------------------------------------------------------------

local function complete_version(self, context, ctx, block, callback)
	local group_id = coordinate_group_id(block)
	local artifact_id = get_tag_value(block, "artifactId")
	if not group_id or group_id == "" or not artifact_id or artifact_id == "" then
		callback(response({}, true))
		return nil
	end

	local cache_key = group_id .. ":" .. artifact_id
	local cached = self.version_catalog[cache_key]
	if cached then
		local range = make_range(context, ctx.value)
		local items = {}
		for _, version in ipairs(cached) do
			table.insert(items, {
				label = version.value,
				kind = KIND.Constant,
				labelDetails = { description = cache_key },
				textEdit = { range = range, newText = version.value },
			})
		end
		callback(response(items, true))
		return nil
	end

	callback(response({}, true))
	local cancelled = false
	local q = 'g:' .. group_id .. ' AND a:' .. artifact_id
	central_search(self, "version:" .. cache_key, {
		q = q,
		core = "gav",
		rows = tostring(VERSION_ROWS),
		wt = "json",
	}, function(docs, err)
		if cancelled or err then
			return
		end
		local seen = {}
		local versions = {}
		for _, doc in ipairs(docs or {}) do
			local value = doc.v or doc.latestVersion
			if value and value ~= "" and not seen[value] then
				seen[value] = true
				table.insert(versions, {
					value = value,
					timestamp = tonumber(doc.timestamp) or 0,
				})
			end
		end
		table.sort(versions, function(a, b)
			if a.timestamp ~= b.timestamp then
				return a.timestamp > b.timestamp
			end
			return a.value > b.value
		end)
		self.version_catalog[cache_key] = versions
		local range = make_range(context, ctx.value)
		local items = {}
		for _, version in ipairs(versions) do
			table.insert(items, {
				label = version.value,
				kind = KIND.Constant,
				labelDetails = { description = cache_key },
				textEdit = { range = range, newText = version.value },
			})
		end
		callback(response(items, true))
	end)

	return function()
		cancelled = true
	end
end

--------------------------------------------------------------------------------
-- STATIC COMPLETION
--------------------------------------------------------------------------------

local function complete_static(context, ctx, values, callback)
	local range = make_range(context, ctx.value)
	local items = {}
	for index, entry in ipairs(values) do
		table.insert(items, {
			label = entry.value,
			kind = KIND.Value,
			sortText = string.format("%03d", index),
			labelDetails = { description = entry.description },
			textEdit = { range = range, newText = entry.value },
		})
	end
	callback(response(items, true))
	return nil
end

--------------------------------------------------------------------------------
-- LAZY DOCUMENTATION
--------------------------------------------------------------------------------

function Source:resolve(item, callback)
	local resolved = vim.deepcopy(item)
	local data = resolved.data and resolved.data.maven
	if data and data.kind == "artifact" then
		resolved.documentation = {
			kind = "markdown",
			value = string.format(
				"**%s:%s**\n\nLatest: `%s`",
				data.groupId,
				data.artifactId,
				data.latestVersion or "unknown"
			),
		}
	elseif data and data.kind == "group" then
		resolved.documentation = {
			kind = "markdown",
			value = "**" .. data.groupId .. "**",
		}
	end
	callback(resolved)
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS
--------------------------------------------------------------------------------

function Source.self_test()
	local known = list_to_set(BUILTIN_GROUP_HINTS)
	return {
		version = Source.VERSION,
		kafka = known["org.springframework.kafka"] == true,
		apache_kafka = known["org.apache.kafka"] == true,
		google_guava = known["com.google.guava"] == true,
		central_url = CENTRAL_URL,
	}
end

function Source.debug_group_plan(value)
	local plans = plan_group_central_queries(value)
	local queries = {}
	for _, plan in ipairs(plans) do
		table.insert(queries, plan.q)
	end
	local jg, ja = plan_group_jdtls_query(value)
	return {
		version = Source.VERSION,
		value = value,
		central = queries,
		jdtls = jg ~= nil and { groupId = jg, artifactId = ja } or nil,
	}
end

function Source.debug_seed_groups(value)
	local result = {}
	for _, group in ipairs(BUILTIN_GROUP_HINTS) do
		if semantic_group_allowed(group, value) then
			table.insert(result, group)
		end
	end
	return result
end

function Source.debug_artifact_queries(group_id, value, artifact_id)
	local result = {
		version = Source.VERSION,
		group_catalog = 'g:' .. (group_id or ''),
	}
	local seed = artifact_target_seed(value or '')
	if seed then
		result.target = 'g:' .. group_id .. ' AND a:*' .. seed .. '*'
	end
	if artifact_id and artifact_id ~= '' then
		result.version_query = 'g:' .. group_id .. ' AND a:' .. artifact_id
	end
	return result
end

--------------------------------------------------------------------------------
-- ENTRY
--------------------------------------------------------------------------------

function Source:get_completions(context, callback)
	if not is_pom() then
		callback(response({}, false))
		return nil
	end

	local ctx = current_context()
	if not ctx then
		callback(response({}, false))
		return nil
	end

	if ctx.tag == "packaging" then
		return complete_static(context, ctx, STATIC_VALUES.packaging, callback)
	end
	if ctx.tag == "phase" then
		return complete_static(context, ctx, STATIC_VALUES.phase, callback)
	end
	if ctx.tag == "updatePolicy" then
		return complete_static(context, ctx, STATIC_VALUES.updatePolicy, callback)
	end
	if ctx.tag == "checksumPolicy" then
		return complete_static(context, ctx, STATIC_VALUES.checksumPolicy, callback)
	end
	if ctx.tag == "layout" then
		return complete_static(context, ctx, STATIC_VALUES.layout, callback)
	end

	local block = find_coordinate_block(ctx.row, ctx.col)
	if not block then
		callback(response({}, false))
		return nil
	end

	if ctx.tag == "groupId" and supports_field(block, "groupId") then
		return complete_group(self, context, ctx, callback)
	end
	if ctx.tag == "artifactId" and supports_field(block, "artifactId") then
		return complete_artifact(self, context, ctx, block, callback)
	end
	if ctx.tag == "version" and supports_field(block, "version") then
		return complete_version(self, context, ctx, block, callback)
	end
	if ctx.tag == "scope" and supports_field(block, "scope") then
		return complete_static(context, ctx, STATIC_VALUES.scope, callback)
	end
	if ctx.tag == "type" and supports_field(block, "type") then
		return complete_static(context, ctx, STATIC_VALUES.type, callback)
	end
	if ctx.tag == "classifier" and supports_field(block, "classifier") then
		return complete_static(context, ctx, STATIC_VALUES.classifier, callback)
	end
	if ctx.tag == "optional" and supports_field(block, "optional") then
		return complete_static(context, ctx, STATIC_VALUES.optional, callback)
	end
	if ctx.tag == "extensions" and supports_field(block, "extensions") then
		return complete_static(context, ctx, STATIC_VALUES.extensions, callback)
	end
	if ctx.tag == "inherited" and supports_field(block, "inherited") then
		return complete_static(context, ctx, STATIC_VALUES.inherited, callback)
	end

	callback(response({}, false))
	return nil
end

return Source
