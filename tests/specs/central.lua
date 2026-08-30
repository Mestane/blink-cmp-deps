local Central = require("blink_deps.central")
local DiskCache = require("blink_deps.disk_cache")

return function(test)
	local eq = test.eq

	--------------------------------------------------------------------------------
	-- DEFAULT / EXPLICIT ENABLED
	--------------------------------------------------------------------------------

	local function cached_source(central)
		return {
			opts = {
				central = central,
			},
			central_cache = {
				test = {
					{
						g = "org.example",
					},
				},
			},
			central_inflight = {},
		}
	end

	local function cached_result(central)
		local result

		Central.search(
			cached_source(central),
			"test",
			{
				q = "g:org.example",
			},
			function(docs)
				result = docs
			end
		)

		return result
	end

	eq(
		cached_result(nil),
		{
			{
				g = "org.example",
			},
		},
		"Maven Central must remain enabled by default"
	)

	eq(
		cached_result({}),
		{
			{
				g = "org.example",
			},
		},
		"An empty central configuration must keep Maven Central enabled"
	)

	eq(
		cached_result({
			enabled = true,
		}),
		{
			{
				g = "org.example",
			},
		},
		"central.enabled = true must keep Maven Central enabled"
	)

	--------------------------------------------------------------------------------
	-- DISABLED
	--------------------------------------------------------------------------------

	local original_disk_get = DiskCache.get
	local original_vim_system = vim.system

	local disk_calls = 0
	local system_calls = 0

	rawset(
		DiskCache,
		"get",
		function()
			disk_calls = disk_calls + 1
			return nil, "miss"
		end
	)

	rawset(
		vim,
		"system",
		function()
			system_calls = system_calls + 1
			error(
				"Maven Central HTTP must not run when disabled"
			)
		end
	)

	local disabled_result
	local disabled_error

	Central.search(
		{
			opts = {
				central = {
					enabled = false,
				},
				cache = {
					enabled = true,
				},
			},
			central_cache = {
				disabled = {
					{
						g = "cached.central",
					},
				},
			},
			central_inflight = {},
		},
		"disabled",
		{
			q = "g:org.example",
		},
		function(docs, err)
			disabled_result = docs
			disabled_error = err
		end
	)

	eq(
		disabled_result,
		{},
		"Disabled Maven Central must return no completion documents"
	)

	eq(
		disabled_error,
		nil,
		"Disabled Maven Central must not report a request error"
	)

	eq(
		disk_calls,
		0,
		"Disabled Maven Central must not read the persistent Central cache"
	)

	eq(
		system_calls,
		0,
		"Disabled Maven Central must not start an HTTP request"
	)

	rawset(
		DiskCache,
		"get",
		original_disk_get
	)

	rawset(
		vim,
		"system",
		original_vim_system
	)
end
