local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Common =
	require("blink_deps.coordinates.common")

local M = {}

local lower = Util.lower
local trim = Util.trim
local response = Util.response
local make_range = Util.make_range

M.MIN_CHARS = 3
M.ROWS = 100

--------------------------------------------------------------------------------
-- QUERY PLANNING
--
-- Two shapes, both measured against search.maven.org:
--
--   jackson-databind      -> a:"jackson-databind"      11 hits,  ~200 ms
--   spring data jpa       -> spring AND data AND jpa   94 hits,  ~224 ms
--
-- The a field is a whole string, not tokenized, so an exact match is cheap and
-- lands the real artifact at the top. Wildcards on it take 25 seconds or time
-- out, and a bare space separated query is read as OR and scans everything.
--------------------------------------------------------------------------------

local function has_whitespace(value)
	return value:find("%s") ~= nil
end

function M.plan_query(value)
	local v = trim(lower(value or ""))

	-- A quote would break out of the Solr term.
	v = v:gsub('"', "")

	if #v < M.MIN_CHARS then
		return nil
	end

	-- A coordinate being typed belongs to group completion.
	if Common.is_reverse_domain_qualified(v) then
		return nil
	end

	if has_whitespace(v) then
		local tokens =
			Common.split_tokens(v)

		if #tokens == 0 then
			return nil
		end

		return table.concat(
			tokens,
			" AND "
		)
	end

	return 'a:"' .. v .. '"'
end

--------------------------------------------------------------------------------
-- ITEMS
--------------------------------------------------------------------------------

local function build_item(
	context,
	ctx,
	doc,
	data_key
)
	local group = doc.g
	local artifact = doc.a

	local coordinate =
		group
		.. ":"
		.. artifact

	return {
		-- The whole point of discovery is that the user does not know the
		-- group yet, and the same artifact id is published under many of
		-- them. A label of just the artifact id renders as a column of
		-- identical rows, so the group has to be in the label itself.
		label = coordinate,
		kind = Common.KIND.Field,
		score_offset =
			Common.discovery_doc_score(
				doc,
				ctx.value
			),
		labelDetails = {
			description =
				doc.latestVersion,
		},
		textEdit = {
			range =
				make_range(
					context,
					ctx.value
				),
			newText =
				coordinate .. ":",
		},
		data = {
			[data_key] = {
				kind = "artifact",
				groupId = group,
				artifactId = artifact,
				latestVersion =
					doc.latestVersion
					or "unknown",
			},
		},
	}
end

--------------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------------

function M.complete(
	source,
	context,
	ctx,
	callback,
	opts
)
	opts = opts or {}

	local data_key =
		opts.data_key or "deps"

	local cancelled = false

	local query =
		M.plan_query(ctx.value)

	if not query then
		callback(
			response({}, true)
		)

		return function()
			cancelled = true
		end
	end

	callback(response({}, true))

	local function start_central()
		if cancelled then
			return
		end

		Central.search(
			source,
			"discovery:" .. query,
			{
				q = query,
				rows = tostring(M.ROWS),
				wt = "json",
			},
			function(docs, err)
				if err then
					Util.debug_log(
						source,
						"Discovery search failed %s: %s",
						query,
						err
					)

					return
				end

				if cancelled then
					return
				end

				local items = {}
				local seen = {}

				for _, doc in ipairs(
					docs or {}
				) do
					local group = doc.g
					local artifact = doc.a

					if type(group) == "string"
						and group ~= ""
						and type(artifact)
							== "string"
						and artifact ~= ""
					then
						local id =
							group
							.. ":"
							.. artifact

						if not seen[id] then
							seen[id] = true

							table.insert(
								items,
								build_item(
									context,
									ctx,
									doc,
									data_key
								)
							)
						end
					end
				end

				callback(
					response(
						items,
						true
					)
				)
			end
		)
	end

	-- Not aliased at the top of the file so tests can replace Util.defer
	-- after this module has already been loaded.
	Util.defer(
		Common.debounce_ms(source),
		start_central
	)

	return function()
		cancelled = true
	end
end

--------------------------------------------------------------------------------
-- DIAGNOSTICS
--------------------------------------------------------------------------------

function M.debug_query(value)
	return {
		value = value,
		central =
			M.plan_query(value),
	}
end

return M
