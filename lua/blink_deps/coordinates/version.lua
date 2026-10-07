local Util = require("blink_deps.util")
local VersionCompletion = require("blink_deps.version_completion")
local VersionRank = require("blink_deps.version_rank")

--------------------------------------------------------------------------------
-- MAVEN VERSION COMPLETION
--
-- Gathering and offering versions is the same in every ecosystem and lives
-- in blink_deps.version_completion. What is Maven's own is here: a package
-- is a groupId and an artifactId, and versions are ordered by Maven's rules.
--------------------------------------------------------------------------------

local M = {}

function M.complete(source, context, ctx, group_id, artifact_id, callback)
	if not group_id
		or group_id == ""
		or not artifact_id
		or artifact_id == ""
	then
		callback(Util.response({}, true))

		return nil
	end

	return VersionCompletion.complete(source, context, ctx, callback, {
		package = {
			namespace = group_id,
			name = artifact_id,
		},

		key = group_id .. ":" .. artifact_id,
		catalog = source.version_catalog,
		sort = VersionRank.sort,
	})
end

return M
