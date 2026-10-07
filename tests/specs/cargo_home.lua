local CargoHome = require("blink_deps.cargo_home")
local Registries = require("blink_deps.registries")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A cargo home is built in a temporary directory, with cache files in the
	-- layout cargo writes. Nothing here reads the cargo home of whoever runs
	-- the suite.
	--------------------------------------------------------------------------------

	local root = vim.fn.tempname()

	local SPARSE = "index.crates.io-6f17d22bba15001f"
	local GIT = "github.com-1ecc6299db9ec823"

	-- cache version, index schema version as four bytes, then the index
	-- file version, each ending in a zero byte like every part after it.
	local HEADER = "\3\2\0\0\0" .. 'etag: W/"abc"' .. "\0"

	local function cache_bytes(entries)
		local parts = { HEADER }

		for _, entry in ipairs(entries) do
			table.insert(parts, entry.vers .. "\0" .. vim.json.encode(entry) .. "\0")
		end

		return table.concat(parts)
	end

	local function write(relative, bytes)
		local path = root .. "/" .. relative

		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

		local file = assert(io.open(path, "wb"))

		file:write(bytes)
		file:close()
	end

	local function write_cache(directory, index_path, entries)
		write(
			"registry/index/" .. directory .. "/.cache/" .. index_path,
			cache_bytes(entries)
		)
	end

	local function new_source(cargo_home)
		return {
			ecosystem = "cargo",
			opts = {
				cargo_home = cargo_home or {
					path = root,
				},
			},
		}
	end

	local registry = CargoHome.REGISTRY

	local function versions(source, name)
		local seen = {}

		registry:versions(source, { name = name }, function(list, err)
			seen.versions = list
			seen.err = err
		end)

		return seen
	end

	local function features(source, name)
		local seen = {}

		registry:features(source, { name = name }, function(list, err)
			seen.features = list
			seen.err = err
		end)

		return seen
	end

	write_cache(SPARSE, "de/mo/demo", {
		{ name = "demo", vers = "0.9.0", features = { old = {} }, yanked = false },
		{ name = "demo", vers = "1.0.0", features = { std = {}, derive = {} }, yanked = true },
		{
			name = "demo",
			vers = "1.1.0",
			features = { std = {} },
			features2 = { unstable = { "dep:helper" } },
			deps = {
				{ name = "helper", optional = true },
				{ name = "extra", optional = true },
			},
			yanked = false,
		},
	})

	--------------------------------------------------------------------------------
	-- CACHE FILES
	--------------------------------------------------------------------------------

	eq(
		CargoHome.parse_cache(cache_bytes({
			{ name = "x", vers = "1.0.0" },
			{ name = "x", vers = "1.1.0", yanked = true },
		})),
		{
			{ name = "x", value = "1.0.0", yanked = false, features = {} },
			{ name = "x", value = "1.1.0", yanked = true, features = {} },
		},
		"A cache file must yield the index entries it holds"
	)

	-- Other header layouts: only the JSON parts matter.
	eq(
		#CargoHome.parse_cache("\1" .. "abc123\0" .. '1.0.0\0{"name":"x","vers":"1.0.0"}\0'),
		1,
		"An older header layout must not prevent reading the entries"
	)

	eq(
		#CargoHome.parse_cache('{"name":"x","vers":"1.0.0"}'),
		1,
		"Entries must be found even without a header"
	)

	for _, bytes in ipairs({
		"",
		"\0\0\0\0",
		HEADER,
		HEADER .. "1.0.0\0{ not json\0",
		string.rep("\255", 64),
		"{\0{\0{",
	}) do
		eq(
			CargoHome.parse_cache(bytes),
			{},
			"A truncated or damaged cache file must yield nothing, not raise"
		)
	end

	eq(CargoHome.parse_cache(nil), {}, "A missing file must yield nothing")

	-- One damaged entry does not hide the others.
	eq(
		#CargoHome.parse_cache(
			HEADER
				.. '1.0.0\0{"name":"x","vers":"1.0.0"}\0'
				.. "1.1.0\0{ damaged\0"
				.. '1.2.0\0{"name":"x","vers":"1.2.0"}\0'
		),
		2,
		"A damaged entry must be skipped on its own"
	)

	--------------------------------------------------------------------------------
	-- REGISTRY
	--------------------------------------------------------------------------------

	eq(
		{ registry.id, registry.kind, registry.offline, registry.public },
		{ "cargo-home", "cargo-home", true },
		"The cargo home must describe itself as an offline registry"
	)

	for capability in pairs(registry.capabilities) do
		ok(
			type(registry[capability]) == "function",
			"The cargo home must implement its declared capability " .. capability
		)
	end

	eq(
		Registries.with(new_source(), "versions")[1],
		registry,
		"A Cargo source must ask the cargo home first"
	)

	--------------------------------------------------------------------------------
	-- VERSIONS AND FEATURES
	--------------------------------------------------------------------------------

	local source = new_source()

	eq(
		versions(source, "demo"),
		{
			versions = {
				{ value = "0.9.0", timestamp = 0 },
				{ value = "1.0.0", timestamp = 0, yanked = true },
				{ value = "1.1.0", timestamp = 0 },
			},
		},
		"Every version cargo knew of must be reported, with yanked releases marked"
	)

	eq(
		features(source, "demo"),
		{ features = { "extra", "std", "unstable" } },
		"Features must be those of the newest release that is not yanked"
	)

	eq(
		versions(source, "Demo").versions,
		versions(source, "demo").versions,
		"A name differing only in case is the same crate"
	)

	eq(
		versions(source, "never-resolved"),
		{ versions = {} },
		"A crate cargo has never resolved has no versions and is not an error"
	)

	eq(
		features(source, "never-resolved"),
		{ features = {} },
		"A crate cargo has never resolved has no features and is not an error"
	)

	eq(
		versions(source, "../../etc/passwd"),
		{ versions = {} },
		"Text that cannot be a crate name must not become a file path"
	)

	eq(
		source.cargo_home_pipeline:stats().network,
		2,
		"Each crate's cache file must be read once per session"
	)

	--------------------------------------------------------------------------------
	-- WHICH DIRECTORIES
	--------------------------------------------------------------------------------

	-- Another registry's directory holds other crates under the same names.
	write_cache("my-company.example-0123456789abcdef", "de/mo/demo", {
		{ name = "demo", vers = "99.0.0" },
	})

	-- The git index older versions of cargo used.
	write_cache(GIT, "le/ga/legacy", {
		{ name = "legacy", vers = "0.1.0" },
	})

	-- Both copies of the same crate: the one knowing more versions wins.
	write_cache(GIT, "bo/th/both", {
		{ name = "both", vers = "1.0.0" },
	})

	write_cache(SPARSE, "bo/th/both", {
		{ name = "both", vers = "1.0.0" },
		{ name = "both", vers = "1.1.0" },
	})

	source = new_source()

	eq(
		CargoHome.debug_directories(source),
		{
			root .. "/registry/index/" .. GIT,
			root .. "/registry/index/" .. SPARSE,
		},
		"Only the crates.io index directories must be read"
	)

	eq(
		#versions(source, "demo").versions,
		3,
		"Another registry's cache must not be mixed into crates.io's"
	)

	eq(
		versions(source, "legacy").versions,
		{ { value = "0.1.0", timestamp = 0 } },
		"The git index cache must be read too"
	)

	eq(
		#versions(source, "both").versions,
		2,
		"With two copies of a crate, the one knowing more versions must be used"
	)

	--------------------------------------------------------------------------------
	-- DOWNLOADED CRATES
	--------------------------------------------------------------------------------

	local function parsed(file)
		local name, version = CargoHome.parse_crate_file(file)

		return { name, version }
	end

	eq(parsed("serde-1.0.200.crate"), { "serde", "1.0.200" }, "A plain archive name must be split")
	eq(parsed("tokio-util-0.7.10.crate"), { "tokio-util", "0.7.10" }, "A hyphenated crate name must be kept whole")
	eq(parsed("base64-0.21.7.crate"), { "base64", "0.21.7" }, "Digits in a crate name are part of the name")
	eq(parsed("sha2-0.10.8.crate"), { "sha2", "0.10.8" }, "A name ending in a digit must be kept whole")
	eq(parsed("x-1.0.0-rc.1.crate"), { "x", "1.0.0-rc.1" }, "A prerelease belongs to the version")
	eq(parsed("toml-1.1.6+spec-1.1.0.crate"), { "toml", "1.1.6+spec-1.1.0" }, "Build metadata belongs to the version")
	eq(
		parsed("windows_x86_64_msvc-0.52.6.crate"),
		{ "windows_x86_64_msvc", "0.52.6" },
		"Underscores and digits together must not confuse the split"
	)

	for _, file in ipairs({
		"serde-1.0.200.crate.tmp",
		"serde-1.0.crate",
		"serde.crate",
		"-1.0.0.crate",
		".package-cache",
		"serde-1.0.200",
		"",
	}) do
		eq(parsed(file), {}, "'" .. file .. "' is not a crate archive")
	end

	eq(parsed(nil), {}, "A missing file name is not a crate archive")

	for _, file in ipairs({
		"tokio-1.38.0.crate",
		"tokio-1.40.0.crate",
		"tokio-1.9.0.crate",
		"tokio-2.0.0-alpha.1.crate",
		"tokio-util-0.7.10.crate",
		"tokio_stream-0.1.15.crate",
		"mio-0.8.11.crate",
		"only-pre-0.1.0-beta.2.crate",
		"only-pre-0.1.0-beta.10.crate",
		"not-an-archive.txt",
	}) do
		write("registry/cache/" .. SPARSE .. "/" .. file, "")
	end

	write("registry/cache/" .. GIT .. "/legacy-0.1.0.crate", "")
	write("registry/cache/my-company.example-0123456789abcdef/internal-9.9.9.crate", "")

	source = new_source()

	local downloaded

	CargoHome.downloaded(source, function(crates)
		downloaded = crates
	end)

	eq(
		downloaded,
		{
			{ name = "legacy", latest_version = "0.1.0" },
			{ name = "mio", latest_version = "0.8.11" },
			{ name = "only-pre", latest_version = "0.1.0-beta.10" },
			{ name = "tokio", latest_version = "1.40.0" },
			{ name = "tokio-util", latest_version = "0.7.10" },
			{ name = "tokio_stream", latest_version = "0.1.15" },
		},
		"Each downloaded crate must be listed once, with the newest release downloaded"
	)

	--------------------------------------------------------------------------------
	-- SEARCH
	--------------------------------------------------------------------------------

	local function search(text)
		local seen = {}

		registry:search(source, text, function(packages, err)
			seen.err = err
			seen.names = {}

			for _, package in ipairs(packages) do
				table.insert(seen.names, package.name .. "@" .. package.latest_version)
			end
		end)

		return seen
	end

	eq(
		search("tok"),
		{ names = { "tokio@1.40.0", "tokio-util@0.7.10", "tokio_stream@0.1.15" } },
		"A search must find the crates in use whose name starts with the text"
	)

	eq(
		search("io"),
		{ names = { "mio@0.8.11", "tokio@1.40.0", "tokio-util@0.7.10", "tokio_stream@0.1.15" } },
		"Names merely containing the text follow, and all are found"
	)

	eq(
		search("util"),
		{ names = { "tokio-util@0.7.10" } },
		"A match in the middle of a name must be found"
	)

	eq(
		search("tokio-s"),
		{ names = { "tokio_stream@0.1.15" } },
		"A hyphen must match an underscore"
	)

	eq(
		search("TOKIO_U"),
		{ names = { "tokio-util@0.7.10" } },
		"An underscore must match a hyphen, whatever the case"
	)

	eq(search("internal"), { names = {} }, "Another registry's crates must not be found")
	eq(search("zzz"), { names = {} }, "No match is an empty answer, not an error")
	eq(search("  "), { names = {} }, "An empty search matches nothing")

	eq(
		source.cargo_home_crates_pipeline:stats().network,
		1,
		"The downloaded crates must be listed once per session"
	)

	-- A result handed out must not be a way to alter the session's list.
	registry:search(source, "mio", function(packages)
		packages[1].latest_version = "tampered"
	end)

	eq(search("mio"), { names = { "mio@0.8.11" } }, "A consumer must not be able to corrupt the list")

	--------------------------------------------------------------------------------
	-- LOCATION
	--------------------------------------------------------------------------------

	local original_cargo_home = vim.env.CARGO_HOME

	vim.env.CARGO_HOME = root

	eq(
		CargoHome.root({ opts = {} }),
		root,
		"CARGO_HOME must be honoured as cargo honours it"
	)

	eq(
		CargoHome.root(new_source({ path = "/configured/elsewhere" })),
		"/configured/elsewhere",
		"A configured path must win over CARGO_HOME"
	)

	vim.env.CARGO_HOME = nil

	eq(
		CargoHome.root({ opts = {} }),
		vim.fn.expand("~/.cargo"),
		"Without either, the default cargo home must be used"
	)

	vim.env.CARGO_HOME = original_cargo_home

	--------------------------------------------------------------------------------
	-- NOTHING THERE
	--------------------------------------------------------------------------------

	local empty = new_source({
		path = root .. "/does-not-exist",
	})

	eq(
		versions(empty, "demo"),
		{ versions = {} },
		"A machine without a cargo home must simply have nothing to offer"
	)

	eq(CargoHome.debug_directories(empty), {}, "A missing cargo home has no directories")

	eq(
		CargoHome.is_enabled(new_source({ enabled = false })),
		false,
		"The cargo home must be switchable off"
	)

	eq(CargoHome.is_enabled({ opts = {} }), true, "The cargo home must be enabled by default")

	vim.fn.delete(root, "rf")
end
