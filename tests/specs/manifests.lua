local Manifests = require("blink_deps.manifests")
local Source = require("blink_deps")

return function(test)
	local eq = test.eq
	local ok = test.ok

	local function ids(list)
		local result = {}

		for _, entry in ipairs(list) do
			table.insert(result, entry.id)
		end

		return result
	end

	--------------------------------------------------------------------------------
	-- BUILT IN MANIFESTS
	--------------------------------------------------------------------------------

	eq(
		Manifests.ids(),
		{ "gradle", "gradle_kts", "maven", "version_catalog" },
		"The built in manifests must be registered"
	)

	for _, entry in ipairs(Manifests.list()) do
		eq(
			entry.ecosystem,
			"maven",
			entry.id .. " declares Maven packages"
		)

		ok(
			type(entry.description) == "string" and entry.description ~= "",
			entry.id .. " must describe the file it handles"
		)

		for _, delegate in ipairs(entry.delegates) do
			ok(
				pcall(require, delegate.module),
				"The module of delegate " .. delegate.id .. " must load"
			)
		end
	end

	--------------------------------------------------------------------------------
	-- MATCHING
	--------------------------------------------------------------------------------

	local cases = {
		{ "/project/pom.xml", { "maven" } },
		{ "pom.xml", { "maven" } },
		{ "C:\\project\\pom.xml", { "maven" } },
		{ "/project/build.gradle", { "gradle" } },
		{ "/project/build.gradle.kts", { "gradle_kts" } },
		{ "/project/gradle/libs.versions.toml", { "version_catalog" } },
		{ "/project/gradle/test.versions.toml", { "version_catalog" } },

		-- Near misses.
		{ "/project/pom.xml.bak", {} },
		{ "/project/my-pom.xml", {} },
		{ "/project/settings.gradle", {} },
		{ "/project/build.gradle.kts.orig", {} },
		{ "/project/versions.toml", {} },
		{ "/project/pom.xml/", {} },
		{ "/project/README.md", {} },
		{ "", {} },
	}

	for _, case in ipairs(cases) do
		eq(
			ids(Manifests.for_path(case[1])),
			case[2],
			"'" .. case[1] .. "' must be matched correctly"
		)
	end

	eq(Manifests.for_path(nil), {}, "A missing path must match nothing")

	--------------------------------------------------------------------------------
	-- DELEGATES
	--------------------------------------------------------------------------------

	eq(
		ids(Manifests.delegates_for_path("/project/build.gradle.kts")),
		{ "gradle_kts", "gradle_catalog_accessor" },
		"A Kotlin build file is completed by coordinates and by catalog accessors, in that order"
	)

	eq(
		ids(Manifests.delegates_for_path("/project/gradle/libs.versions.toml")),
		{ "catalog" },
		"A delegate id may differ from the public manifest id"
	)

	eq(
		Manifests.delegate("gradle_catalog_accessor").module,
		"blink_deps.gradle_catalog_accessor",
		"A delegate must be found by its id"
	)

	eq(Manifests.delegate("nothing"), nil, "An unknown delegate must not be found")
	eq(Manifests.get("nothing"), nil, "An unknown manifest must not be found")

	--------------------------------------------------------------------------------
	-- ENABLED FILTER
	--------------------------------------------------------------------------------

	eq(
		ids(Manifests.for_path("/project/pom.xml", { gradle = true })),
		{},
		"A manifest that is not enabled must not match"
	)

	eq(
		ids(Manifests.for_path("/project/pom.xml", { maven = true })),
		{ "maven" },
		"An enabled manifest must match"
	)

	eq(
		ids(Manifests.for_path("/project/pom.xml", {})),
		{},
		"An empty enabled set must match nothing"
	)

	--------------------------------------------------------------------------------
	-- ITEM ROUTING
	--------------------------------------------------------------------------------

	eq(
		Manifests.delegate_for_item({ data = { gradle_kts = { kind = "artifact" } } }),
		"gradle_kts",
		"An item must be routed back by its data key"
	)

	eq(
		Manifests.delegate_for_item({ data = { catalog = {} } }),
		"catalog",
		"An empty data table still identifies its delegate"
	)

	eq(
		Manifests.delegate_for_item({ data = { unrelated = true } }),
		nil,
		"An item no delegate claims must not be routed"
	)

	eq(Manifests.delegate_for_item({ label = "x" }), nil, "An item without data must not be routed")
	eq(Manifests.delegate_for_item(nil), nil, "A missing item must not raise")

	--------------------------------------------------------------------------------
	-- VALIDATION
	--------------------------------------------------------------------------------

	local function rejected(entry)
		local registered, message = pcall(Manifests.register, entry)

		return not registered and tostring(message) or nil
	end

	local valid_delegates = {
		{ id = "x", module = "blink_deps_spec.x" },
	}

	ok(rejected(nil), "A missing entry must be rejected")
	ok(rejected({ ecosystem = "e", match = print, delegates = valid_delegates }), "A missing id must be rejected")

	ok(
		rejected({ id = "a", match = print, delegates = valid_delegates }),
		"A missing ecosystem must be rejected"
	)

	ok(
		rejected({ id = "a", ecosystem = "e", match = "pom.xml", delegates = valid_delegates }),
		"A match that is not a function must be rejected"
	)

	ok(
		rejected({ id = "a", ecosystem = "e", match = print, delegates = {} }),
		"A manifest without delegates must be rejected"
	)

	ok(
		rejected({ id = "a", ecosystem = "e", match = print, delegates = { { id = "x" } } }),
		"A delegate without a module must be rejected"
	)

	ok(
		rejected({ id = "maven", ecosystem = "e", match = print, delegates = valid_delegates })
			:find("duplicate id maven", 1, true),
		"A duplicate manifest id must be rejected by name"
	)

	ok(
		rejected({
			id = "a",
			ecosystem = "e",
			match = print,
			delegates = {
				{ id = "maven", module = "somewhere.else" },
			},
		}),
		"A delegate id already used by another module must be rejected"
	)

	eq(
		Manifests.ids(),
		{ "gradle", "gradle_kts", "maven", "version_catalog" },
		"A rejected entry must leave nothing behind"
	)

	--------------------------------------------------------------------------------
	-- A NEW MANIFEST, END TO END
	--
	-- What adding support for another file takes: one registered entry. The
	-- unified source is not touched. The delegate is a stand in, so this
	-- covers the wiring and nothing ecosystem specific.
	--------------------------------------------------------------------------------

	local created = {}

	package.loaded["blink_deps_spec.cargo"] = {
		new = function(opts, _, shared)
			local delegate = {
				opts = opts,
				shared = shared,
			}

			function delegate:get_trigger_characters()
				return { '"', "=" }
			end

			function delegate:get_completions(_, callback)
				callback({
					items = {
						{
							label = "serde",
							data = {
								cargo = { kind = "crate" },
							},
						},
					},
					is_incomplete_forward = false,
					is_incomplete_backward = false,
				})
			end

			function delegate:resolve(item, callback)
				local resolved = vim.deepcopy(item)

				resolved.detail = "resolved by cargo"

				callback(resolved)
			end

			table.insert(created, delegate)

			return delegate
		end,
	}

	Manifests.register({
		id = "cargo",
		ecosystem = "cargo",
		description = "Cargo.toml",

		match = function(name)
			return name == "Cargo.toml"
		end,

		delegates = {
			{
				id = "cargo",
				module = "blink_deps_spec.cargo",
				data_key = "cargo",
			},
		},
	})

	eq(
		Manifests.ids(),
		{ "cargo", "gradle", "gradle_kts", "maven", "version_catalog" },
		"A registered manifest must be listed"
	)

	vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-manifests/Cargo.toml")

	local source = Source.new({
		debug = true,
	})

	ok(source:enabled(), "The unified source must enable itself for a registered file")

	eq(
		source:get_trigger_characters(),
		{ '"', "=" },
		"Trigger characters must come from the registered delegate"
	)

	local responses = {}

	source:get_completions({}, function(result)
		table.insert(responses, result)
	end)

	eq(
		responses[1].items[1].label,
		"serde",
		"Completion must be routed to the registered delegate"
	)

	local resolved

	source:resolve(responses[1].items[1], function(item)
		resolved = item
	end)

	eq(
		resolved.detail,
		"resolved by cargo",
		"Resolve must be routed back through the registered data key"
	)

	eq(#created, 1, "The delegate must be created once and reused")
	eq(created[1].opts.debug, true, "The delegate must receive the user's options")

	ok(
		created[1].shared == source.shared_state,
		"The delegate must be offered the shared state like any other"
	)

	-- The new id is a valid enabled source, and can be switched off.
	local without_cargo = Source.new({
		enabled_sources = { "maven" },
	})

	ok(
		not without_cargo:enabled(),
		"A registered manifest must respect enabled_sources"
	)

	local only_cargo = Source.new({
		enabled_sources = { "cargo" },
	})

	ok(only_cargo:enabled(), "A registered manifest must be accepted in enabled_sources")

	local unknown_ok, unknown_message = pcall(Source.new, {
		enabled_sources = { "nope" },
	})

	ok(
		not unknown_ok
			and tostring(unknown_message):find(
				"cargo, gradle, gradle_kts, maven, version_catalog",
				1,
				true
			),
		"The error for an unknown source must list every registered manifest"
	)

	package.loaded["blink_deps_spec.cargo"] = nil
end
