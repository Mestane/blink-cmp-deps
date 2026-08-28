local M = {}

function M.new()
	local test = {
		total = 0,
	}

	local function fail(message)
		error(message, 2)
	end

	function test.ok(condition, message)
		test.total = test.total + 1

		if not condition then
			fail("FAILED: " .. message)
		end
	end

	function test.eq(actual, expected, message)
		test.total = test.total + 1

		if not vim.deep_equal(actual, expected) then
			fail(string.format(
				"FAILED: %s\nexpected: %s\nactual:   %s",
				message,
				vim.inspect(expected),
				vim.inspect(actual)
			))
		end
	end

	function test.contains(values, expected)
		for _, value in ipairs(values) do
			if value == expected then
				return true
			end
		end

		return false
	end

	return test
end

return M
