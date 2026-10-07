--------------------------------------------------------------------------------
-- TEST RUNNER
--
-- Runs every spec, each one in isolation, and reports all failures instead of
-- stopping at the first.
--
-- Isolation matters because specs replace things: vim.system, vim.schedule,
-- functions on the plugin's own modules. A spec that fails halfway never
-- reaches the lines that put them back, and without a reset every spec after
-- it would fail for a reason that has nothing to do with it.
--
-- Run one spec, or a few, with SPEC set to part of the file name:
--
--   SPEC=maven make test
--------------------------------------------------------------------------------

local Test = dofile("tests/helpers.lua")

local specs = {
	"tests/specs/source.lua",
	"tests/specs/manifests.lua",
	"tests/specs/diagnostics.lua",
	"tests/specs/maven.lua",
	"tests/specs/maven_context.lua",
	"tests/specs/cargo_context.lua",
	"tests/specs/cargo.lua",
	"tests/specs/gradle.lua",
	"tests/specs/gradle_kts.lua",
	"tests/specs/catalog.lua",
	"tests/specs/gradle_catalog_accessor.lua",
	"tests/specs/disk_cache.lua",
	"tests/specs/http.lua",
	"tests/specs/pipeline.lua",
	"tests/specs/local_repository.lua",
	"tests/specs/central.lua",
	"tests/specs/crates_io.lua",
	"tests/specs/cargo_index.lua",
	"tests/specs/cargo_home.lua",
	"tests/specs/nexus.lua",
	"tests/specs/repository.lua",
	"tests/specs/registries.lua",
	"tests/specs/coordinates.lua",
	"tests/specs/discovery.lua",
	"tests/specs/version_rank.lua",
	"tests/specs/semver.lua",
	"tests/specs/version_completion.lua",
	"tests/specs/util.lua",
	"tests/specs/relevance.lua",
}

--------------------------------------------------------------------------------
-- ISOLATION
--------------------------------------------------------------------------------

-- Everything a spec is known to replace outside the plugin's own modules.
local GLOBALS = {
	{ vim, "system" },
	{ vim, "schedule" },
	{ vim, "notify" },
	{ vim, "defer_fn" },
	{ os, "time" },
}

local originals = {}

for index, entry in ipairs(GLOBALS) do
	originals[index] = entry[1][entry[2]]
end

local function reset()
	for index, entry in ipairs(GLOBALS) do
		rawset(entry[1], entry[2], originals[index])
	end

	-- Dropping the plugin's modules discards whatever was replaced on them
	-- and whatever state they accumulated; the next spec loads them fresh.
	for name in pairs(package.loaded) do
		if name == "blink_deps" or name:match("^blink_deps%.") then
			package.loaded[name] = nil
		end
	end

	-- Specs name the buffer and fill it to drive file detection.
	vim.cmd("silent! enew!")
	vim.cmd("silent! %bwipeout!")
end

--------------------------------------------------------------------------------
-- RUN
--------------------------------------------------------------------------------

local filter = vim.env.SPEC

local total = 0
local ran = 0
local failures = {}

for _, path in ipairs(specs) do
	if not filter or filter == "" or path:find(filter, 1, true) then
		reset()

		local test = Test.new()

		local ok, failure = xpcall(function()
			dofile(path)(test)
		end, function(message)
			-- An assertion already says what is wrong. Anything else is a
			-- crash, and a crash needs to say where.
			if type(message) == "string" and message:find("FAILED: ", 1, true) then
				return message
			end

			return debug.traceback(tostring(message), 2)
		end)

		ran = ran + 1
		total = total + test.total

		if not ok then
			table.insert(failures, {
				path = path,
				message = failure,
				after = test.total,
			})
		end
	end
end

reset()

if ran == 0 then
	error("blink-cmp-deps: no spec matches SPEC=" .. tostring(filter), 0)
end

if #failures > 0 then
	local report = {}

	for _, failure in ipairs(failures) do
		table.insert(report, string.format(
			"%s (after %d passing assertions)\n%s",
			failure.path,
			failure.after - 1,
			failure.message
		))
	end

	error(string.format(
		"%s\n\nblink-cmp-deps: %d of %d specs failed",
		table.concat(report, "\n\n"),
		#failures,
		ran
	), 0)
end

-- Written directly so the line ends with a newline; print() in a headless
-- session leaves the shell prompt on the same line.
io.stdout:write(string.format(
	"blink-cmp-deps: %d tests passed\n",
	total
))
