local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Common =
	require("blink_deps.coordinates.common")

local M = {}

local lower = Util.lower
local trim = Util.trim
local extract_artifacts =
	Util.extract_artifacts
local response = Util.response
local make_range = Util.make_range

local function artifact_score_offset(
	artifact,
	value
)
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

local function build_artifact_item(
	context,
	ctx,
	group_id,
	entry,
	source_name,
	data_key
)
	return {
		label = entry.artifact,
		kind = Common.KIND.Field,
		score_offset =
			artifact_score_offset(
				entry.artifact,
				ctx.value
			),
		labelDetails = {
			description = source_name,
		},
		textEdit = {
			range =
				make_range(
					context,
					ctx.value
				),
			newText = entry.artifact,
		},
		data = {
			[data_key] = {
				kind = "artifact",
				groupId = group_id,
				artifactId =
					entry.artifact,
				latestVersion =
					entry.latestVersion
					or "unknown",
			},
		},
	}
end

function M.target_seed(value)
	local v = lower(trim(value))

	if #v < 2 then
		return nil
	end

	return v:sub(
		1,
		math.min(
			4,
			#v
		)
	)
end

function M.complete(
	source,
	context,
	ctx,
	group_id,
	callback,
	opts
)
	opts = opts or {}

	if not group_id
		or group_id == ""
	then
		callback(
			response({}, true)
		)

		return nil
	end

	local data_key =
		opts.data_key or "deps"

	local cancelled = false
	local sent = {}
	local called = false

	local function emit(
		entries,
		source_name
	)
		if cancelled then
			return
		end

		local items = {}

		for _, entry in ipairs(
			entries or {}
		) do
			if entry.artifact
				and not sent[
					entry.artifact
				]
			then
				sent[
					entry.artifact
				] = true

				table.insert(
					items,
					build_artifact_item(
						context,
						ctx,
						group_id,
						entry,
						source_name
							or group_id,
						data_key
					)
				)
			end
		end

		if #items > 0
			or not called
		then
			called = true

			callback(
				response(
					items,
					true
				)
			)
		end
	end

	local cached =
		source.artifact_catalog[
			group_id
		]

	if cached then
		emit(cached, group_id)
	else
		emit({}, group_id)
	end

	if opts.extra_search then
		opts.extra_search(emit)
	end

	local exact_key =
		"artifact:group:"
		.. group_id

	Central.search(
		source,
		exact_key,
		{
			q = "g:" .. group_id,
			rows = tostring(
				Common.ARTIFACT_ROWS
			),
			wt = "json",
		},
		function(docs, err)
			if err then
				Common.notify_once(
					source,
					"artifact:"
						.. group_id,
					(
						opts.error_prefix
						or "Dependency completion"
					)
						.. ": artifact catalog request failed: "
						.. err
				)

				return
			end

			local entries =
				extract_artifacts(
					docs,
					group_id
				)

			source.artifact_catalog[
				group_id
			] = entries

			emit(
				entries,
				group_id
			)
		end
	)

	local seed =
		M.target_seed(ctx.value)

	if seed then
		local q =
			"g:"
			.. group_id
			.. " AND a:*"
			.. seed
			.. "*"

		Central.search(
			source,
			"artifact:target:"
				.. group_id
				.. ":"
				.. seed,
			{
				q = q,
				rows = "100",
				wt = "json",
			},
			function(docs, err)
				if not err then
					emit(
						extract_artifacts(
							docs,
							group_id
						),
						group_id
					)
				end
			end
		)
	end

	return function()
		cancelled = true
	end
end

function M.debug_queries(
	group_id,
	value,
	artifact_id
)
	local result = {
		group_catalog =
			"g:"
			.. (group_id or ""),
	}

	local seed =
		M.target_seed(
			value or ""
		)

	if seed then
		result.target =
			"g:"
			.. group_id
			.. " AND a:*"
			.. seed
			.. "*"
	end

	if artifact_id
		and artifact_id ~= ""
	then
		result.version_query =
			"g:"
			.. group_id
			.. " AND a:"
			.. artifact_id
	end

	return result
end

return M
