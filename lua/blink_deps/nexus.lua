local Util = require("blink_deps.util")
local VERSION = require("blink_deps.version")
local VersionRank = require("blink_deps.version_rank")

local M = {}

M.HTTP_CONNECT_TIMEOUT = 3
M.HTTP_MAX_TIME = 7
M.MAX_PAGES = 20

local function trim_slash(value)
	return (value or ""):gsub("/+$", "")
end

local function valid_repository(repository)
	return type(repository) == "table"
		and repository.type == "nexus"
		and type(repository.url) == "string"
		and repository.url ~= ""
		and type(repository.repository) == "string"
		and repository.repository ~= ""
end

local function api_url(repository)
	if not valid_repository(repository) then
		return nil
	end

	return trim_slash(repository.url)
		.. "/service/rest/v1/search"
end

local function content_url(repository)
	if not valid_repository(repository) then
		return nil
	end

	return trim_slash(repository.url)
		.. "/repository/"
		.. repository.repository
end

local function newer_version(left, right)
	if not left or left == "" then
		return false
	end

	if not right or right == "" then
		return true
	end

	return VersionRank.compare_values(
		left,
		right
	) > 0
end

local function extract_artifacts(data, group_id)
	if type(data) ~= "table"
		or type(data.items) ~= "table"
	then
		return {}
	end

	local by_artifact = {}

	for _, item in ipairs(data.items) do
		if type(item) == "table"
			and item.group == group_id
			and type(item.name) == "string"
			and item.name ~= ""
		then
			local existing =
				by_artifact[item.name]

			if not existing then
				existing = {
					artifact = item.name,
					latestVersion =
						item.version or "unknown",
				}

				by_artifact[item.name] =
					existing
			elseif newer_version(
				item.version,
				existing.latestVersion
			) then
				existing.latestVersion =
					item.version
			end
		end
	end

	local artifacts = {}

	for _, entry in pairs(by_artifact) do
		table.insert(
			artifacts,
			entry
		)
	end

	table.sort(artifacts, function(a, b)
		return a.artifact < b.artifact
	end)

	return artifacts
end

local function cache_key(repository, group_id)
	return table.concat({
		trim_slash(repository.url),
		repository.repository,
		group_id,
	}, "\n")
end

local function request_command(
	source,
	repository,
	group_id,
	continuation_token
)
	local cmd = {
		"curl",
		"-sS",
		"--fail-with-body",
		"--connect-timeout",
		tostring(
			source.opts.connect_timeout
				or M.HTTP_CONNECT_TIMEOUT
		),
		"--max-time",
		tostring(
			source.opts.max_time
				or M.HTTP_MAX_TIME
		),
		"-A",
		"blink-cmp-deps/" .. VERSION,
		"-G",
		api_url(repository),
		"--data-urlencode",
		"repository="
			.. repository.repository,
		"--data-urlencode",
		"group=" .. group_id,
	}

	if continuation_token
		and continuation_token ~= ""
	then
		table.insert(
			cmd,
			"--data-urlencode"
		)

		table.insert(
			cmd,
			"continuationToken="
				.. continuation_token
		)
	end

	return cmd
end

local function request_page(
	source,
	repository,
	group_id,
	continuation_token,
	callback
)
	local cmd =
		request_command(
			source,
			repository,
			group_id,
			continuation_token
		)

	vim.system(
		cmd,
		{ text = true },
		function(result)
			vim.schedule(function()
				if result.code ~= 0 then
					callback(
						nil,
						Util.trim(
							result.stderr
								or "Nexus request failed"
						)
					)
					return
				end

				local ok, data =
					pcall(
						vim.json.decode,
						result.stdout or ""
					)

				if not ok
					or type(data) ~= "table"
				then
					callback(
						nil,
						"invalid Nexus JSON response"
					)
					return
				end

				callback(data, nil)
			end)
		end
	)
end

local function fetch_all_pages(
	source,
	repository,
	group_id,
	callback
)
	local all_items = {}
	local seen_tokens = {}
	local page_count = 0

	local function next_page(token)
		page_count = page_count + 1

		if page_count > M.MAX_PAGES then
			callback(
				nil,
				"Nexus search exceeded maximum page count"
			)
			return
		end

		request_page(
			source,
			repository,
			group_id,
			token,
			function(data, err)
				if err then
					callback(nil, err)
					return
				end

				for _, item in ipairs(
					data.items or {}
				) do
					table.insert(
						all_items,
						item
					)
				end

				local next_token =
					data.continuationToken

				if next_token == nil
					or next_token == ""
				then
					callback({
						items = all_items,
					}, nil)
					return
				end

				if seen_tokens[next_token] then
					callback(
						nil,
						"Nexus returned a repeated continuation token"
					)
					return
				end

				seen_tokens[next_token] = true

				next_page(next_token)
			end
		)
	end

	next_page(nil)
end

function M.artifacts(
	source,
	repository,
	group_id,
	callback
)
	if not valid_repository(repository) then
		callback(
			nil,
			"invalid Nexus repository configuration"
		)
		return
	end

	if type(group_id) ~= "string"
		or group_id == ""
	then
		callback(
			nil,
			"Nexus artifact search requires a group"
		)
		return
	end

	source.nexus_artifact_cache =
		source.nexus_artifact_cache or {}

	source.nexus_artifact_inflight =
		source.nexus_artifact_inflight or {}

	local key =
		cache_key(repository, group_id)

	local cached =
		source.nexus_artifact_cache[key]

	if cached then
		callback(
			vim.deepcopy(cached),
			nil
		)
		return
	end

	local running =
		source.nexus_artifact_inflight[key]

	if running then
		table.insert(
			running,
			callback
		)
		return
	end

	source.nexus_artifact_inflight[key] = {
		callback,
	}

	fetch_all_pages(
		source,
		repository,
		group_id,
		function(data, err)
			local result

			if not err then
				result =
					extract_artifacts(
						data,
						group_id
					)

				source.nexus_artifact_cache[key] =
					vim.deepcopy(result)
			end

			local waiters =
				source.nexus_artifact_inflight[key]
				or {}

			source.nexus_artifact_inflight[key] =
				nil

			for _, waiter in ipairs(waiters) do
				if err then
					waiter(nil, err)
				else
					waiter(
						vim.deepcopy(result),
						nil
					)
				end
			end
		end
	)
end

function M.is_repository(repository)
	return valid_repository(repository)
end

function M.debug_api_url(repository)
	return api_url(repository)
end

function M.debug_content_url(repository)
	return content_url(repository)
end

function M.debug_extract_artifacts(
	data,
	group_id
)
	return extract_artifacts(
		data,
		group_id
	)
end

function M.debug_cache_key(
	repository,
	group_id
)
	return cache_key(
		repository,
		group_id
	)
end

function M.debug_request_command(
	source,
	repository,
	group_id,
	continuation_token
)
	return request_command(
		source,
		repository,
		group_id,
		continuation_token
	)
end

return M
