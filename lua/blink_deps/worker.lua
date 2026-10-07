--------------------------------------------------------------------------------
-- WORKER
--
-- Runs a function away from the main loop, for work that would otherwise
-- stall typing: decoding megabytes of JSON, reading a large lockfile.
--
-- A worker thread has a Lua state of its own. Only text may cross to it and
-- back, and the function it runs is copied there by itself, so it must be
-- self-contained:
--
--   it takes one string and returns one string
--   it refers to nothing outside itself: no upvalues, no modules of the
--   plugin, only what Neovim provides in every state
--
-- Callers mark a failure however they like in the returned text; this
-- module only carries it.
--------------------------------------------------------------------------------

local M = {}

-- callback(output) runs on the main loop. output is nil if the function
-- raised.
function M.run(fn, input, callback)
	if type(vim.uv.new_work) ~= "function" then
		local ok, output = pcall(fn, input)

		callback(ok and output or nil)

		return
	end

	local work = vim.uv.new_work(fn, function(output)
		vim.schedule(function()
			callback(type(output) == "string" and output or nil)
		end)
	end)

	work:queue(input)
end

return M
