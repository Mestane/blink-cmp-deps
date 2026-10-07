local Util = require("blink_deps.util")

--------------------------------------------------------------------------------
-- RELEVANCE
--
-- How typed text relates to a package. Pure functions with no dependency on
-- any registry, so both the registries and the completion code can use them.
--------------------------------------------------------------------------------

local M = {}

local lower = Util.lower
local trim = Util.trim
local starts_with = Util.starts_with

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

-- A reverse domain prefix means the user is typing a coordinate, not
-- searching. Discovery and group completion split on exactly this.
function M.is_reverse_domain_qualified(value)
	local v = lower(value)

	for _, prefix in ipairs(REVERSE_DOMAIN_PREFIXES) do
		if starts_with(v, prefix) then
			return true
		end
	end

	return false
end

-- How strongly one package answers a piece of typed text. Zero for empty
-- text, at least one for any package offered as a match.
function M.package_score(namespace, name, text)
	local group = lower(namespace or "")
	local artifact = lower(name or "")
	local v = lower(trim(text))

	if v == "" then
		return 0
	end

	local score = 1

	if group == v then
		score = score + 50
	elseif starts_with(group, v) then
		score = score + 30
	elseif group:find(v, 1, true) then
		score = score + 15
	end

	if artifact == v then
		score = score + 50
	elseif starts_with(artifact, v) then
		score = score + 30
	elseif artifact:find(v, 1, true) then
		score = score + 15
	end

	for _, token in ipairs(Util.split_tokens(v)) do
		if #token >= 2 then
			if starts_with(artifact, token) then
				score = score + 10
			elseif artifact:find(token, 1, true) then
				score = score + 5
			end

			if starts_with(group, token) then
				score = score + 6
			elseif group:find(token, 1, true) then
				score = score + 3
			end
		end
	end

	return score
end

return M
