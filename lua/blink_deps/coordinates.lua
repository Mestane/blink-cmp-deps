local Common = require("blink_deps.coordinates.common")
local Group = require("blink_deps.coordinates.group")
local Artifact = require("blink_deps.coordinates.artifact")
local Version = require("blink_deps.coordinates.version")

local M = {}

M.GROUP_MIN_CHARS = Common.GROUP_MIN_CHARS
M.GROUP_ROWS = Common.GROUP_ROWS
M.ARTIFACT_ROWS = Common.ARTIFACT_ROWS
M.VERSION_ROWS = Common.VERSION_ROWS

M.new_state = Common.new_state
M.resolve = Common.resolve
M.self_test = Common.self_test

M.is_reverse_domain_qualified =
	Group.is_reverse_domain_qualified

M.split_tokens =
	Group.split_tokens

M.plan_group_central_queries =
	Group.plan_central_queries

M.complete_group =
	Group.complete

M.debug_group_plan =
	Group.debug_plan

M.debug_seed_groups =
	Group.debug_seed_groups

M.artifact_target_seed =
	Artifact.target_seed

M.complete_artifact =
	Artifact.complete

M.debug_artifact_queries =
	Artifact.debug_queries

M.complete_version =
	Version.complete

return M
