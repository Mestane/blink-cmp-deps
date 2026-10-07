local Semver = require("blink_deps.semver")
local Util = require("blink_deps.util")

--------------------------------------------------------------------------------
-- CARGO INDEX FORMAT
--
-- A cargo registry describes its crates through an index: one file per
-- crate, one JSON object per published version. crates.io serves it over
-- HTTP, alternate registries serve the same thing, and cargo keeps a copy
-- of what it has read under ~/.cargo.
--
-- This module knows that format and nothing about where the bytes came
-- from. Pure functions.
--------------------------------------------------------------------------------

local M = {}

--------------------------------------------------------------------------------
-- INDEX PATHS
--
-- The index spreads crates over directories by name length, so that no
-- directory grows unbounded:
--
--   a        1/a
--   ab       2/ab
--   abc      3/a/abc
--   serde    se/rd/serde
--
-- Names are lowercased in the path. Returns nil for something that cannot be
-- a crate name, which also keeps arbitrary text out of a URL or a file path.
--------------------------------------------------------------------------------

function M.path(name)
	if type(name) ~= "string" or not name:match("^[%w_%-]+$") then
		return nil
	end

	local lowered = name:lower()
	local length = #lowered

	if length == 1 then
		return "1/" .. lowered
	end

	if length == 2 then
		return "2/" .. lowered
	end

	if length == 3 then
		return "3/" .. lowered:sub(1, 1) .. "/" .. lowered
	end

	return lowered:sub(1, 2) .. "/" .. lowered:sub(3, 4) .. "/" .. lowered
end

--------------------------------------------------------------------------------
-- INDEX ENTRIES
--
-- One line per published version. A line that cannot be read is skipped: one
-- damaged entry must not hide every other version of the crate.
--
-- Features come from two fields. features2 was added for syntax that older
-- versions of cargo could not parse, and holds entries of the same kind.
--------------------------------------------------------------------------------

function M.parse(body)
	local entries = {}

	for line in (body or ""):gmatch("[^\n]+") do
		local ok, decoded = pcall(vim.json.decode, line)

		if ok
			and type(decoded) == "table"
			and type(decoded.vers) == "string"
			and decoded.vers ~= ""
		then
			local features = {}

			-- Dependencies a feature enables explicitly, as "dep:name".
			local explicit = {}

			for _, field in ipairs({ "features", "features2" }) do
				if type(decoded[field]) == "table" then
					for feature, enables in pairs(decoded[field]) do
						if type(feature) == "string" then
							features[feature] = true
						end

						if type(enables) == "table" then
							for _, enabled in ipairs(enables) do
								if type(enabled) == "string" then
									local dependency = enabled:match("^dep:(.+)$")

									if dependency then
										explicit[dependency] = true
									end
								end
							end
						end
					end
				end
			end

			-- An optional dependency is itself a feature of the same
			-- name, unless some feature names it with dep:, which is how
			-- a crate says the dependency is not to be enabled directly.
			if type(decoded.deps) == "table" then
				for _, dependency in ipairs(decoded.deps) do
					if type(dependency) == "table"
						and dependency.optional == true
						and type(dependency.name) == "string"
						and not explicit[dependency.name]
					then
						features[dependency.name] = true
					end
				end
			end

			table.insert(entries, {
				-- As published. The path it is found under is
				-- lowercased; this is how the crate spells itself.
				name = type(decoded.name) == "string" and decoded.name or nil,
				value = decoded.vers,
				yanked = decoded.yanked == true,
				features = Util.sorted_keys(features),
			})
		end
	end

	return entries
end

--------------------------------------------------------------------------------
-- CURRENT RELEASE
--
-- The release a new dependency would get: the newest that is neither yanked
-- nor a prerelease, or failing that the newest that is not yanked, or
-- failing that the newest of all.
--------------------------------------------------------------------------------

local function newest(entries, acceptable)
	local best

	for _, entry in ipairs(entries) do
		if acceptable(entry)
			and (not best or Semver.compare(entry.value, best.value) > 0)
		then
			best = entry
		end
	end

	return best
end

function M.current_release(entries)
	return newest(entries, function(entry)
		return not entry.yanked and not Semver.is_prerelease(entry.value)
	end) or newest(entries, function(entry)
		return not entry.yanked
	end) or newest(entries, function()
		return true
	end)
end

return M
