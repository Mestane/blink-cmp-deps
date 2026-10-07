local Declared = require("blink_deps.declared")

return function(test)
	local eq = test.eq
	local ok = test.ok

	--------------------------------------------------------------------------------
	-- HARNESS
	--------------------------------------------------------------------------------

	-- Each declared dependency as "row:col label operator version".
	local function scan(manifest, text)
		local lines = vim.split(text, "\n", { plain = true })
		local list = {}

		for _, entry in ipairs(Declared.scan(manifest, lines)) do
			-- The position must point at exactly the version.
			eq(
				lines[entry.row]:sub(entry.col + 1, entry.end_col),
				entry.version,
				"The reported range must cover the version and nothing else"
			)

			table.insert(
				list,
				string.format("%d:%d %s %s%s", entry.row, entry.col, entry.label, entry.operator, entry.version)
			)
		end

		return list
	end

	--------------------------------------------------------------------------------
	-- REQUIREMENTS FILES
	--------------------------------------------------------------------------------

	eq(
		scan(
			"requirements",
			table.concat({
				"# pinned",
				"requests==2.31.0",
				"Django>=4.2,<5.0  # LTS",
				'typing_extensions ~= 4.9 ; python_version < "3.12"',
				"flask",
				"numpy[extra]==1.26.4 \\",
				"    --hash=sha256:abc123",
				"-r other-1.0.txt",
				"pkg @ https://example.test/pkg-2.0.0.whl",
				"urllib3!=2.0.0,>=1.26.5",
				"wild==2.*",
			}, "\n")
		),
		{
			"2:10 requests ==2.31.0",
			"3:8 Django >=4.2",
			"4:21 typing_extensions ~=4.9",
			"6:14 numpy ==1.26.4",
			"10:17 urllib3 >=1.26.5",
		},
		"Pinned and lower bound versions are declared; bounds, exclusions, markers, hashes, URLs and wildcards are not"
	)

	local requirement = Declared.scan("requirements", { "Typing_Extensions==4.9.0" })[1]

	eq(
		requirement,
		{
			ecosystem = "pypi",
			package = { name = "typing-extensions" },
			label = "Typing_Extensions",
			version = "4.9.0",
			operator = "==",
			row = 1,
			col = 19,
			end_col = 24,
		},
		"An entry must name the package as a registry takes it and as the file writes it"
	)

	--------------------------------------------------------------------------------
	-- PACKAGE.JSON
	--------------------------------------------------------------------------------

	eq(
		scan(
			"npm",
			table.concat({
				"{",
				'  "name": "demo", "version": "1.0.0",',
				'  "dependencies": {',
				'    "react": "^18.2.0",',
				'    "@types/node": ">=18.0.0 <21.0.0",',
				'    "old": "npm:react@^17.0.2",',
				'    "local": "workspace:*",',
				'    "any": "*",',
				'    "tagged": "latest"',
				"  },",
				'  "overrides": { "foo": { "bar@1": "2.0.0" } },',
				'  "engines": { "node": ">=18.0.0" }',
				"}",
			}, "\n")
		),
		{
			"4:15 react ^18.2.0",
			"5:22 @types/node >=18.0.0",
			"6:23 react ^17.0.2",
			"11:36 bar 2.0.0",
		},
		"Ranges, aliases and overrides are declared; the package's own version, engines, tags and references are not"
	)

	--------------------------------------------------------------------------------
	-- CARGO.TOML
	--------------------------------------------------------------------------------

	eq(
		scan(
			"cargo",
			table.concat({
				"[package]",
				'name = "demo"',
				'version = "0.1.0"',
				'edition = "2021"',
				"",
				"[dependencies]",
				'serde = "1.0.200"',
				'tokio = { version = "1.38", features = ["full"] }',
				'log4rs2 = ">=1.2, <2"',
				'json = { package = "serde_json", version = "1.0.117" }',
				'local = { path = "../local-1.0" }',
				"",
				"[dependencies.clap]",
				'version = "4.5.4"',
			}, "\n")
		),
		{
			"7:9 serde 1.0.200",
			"8:21 tokio 1.38",
			"9:13 log4rs2 >=1.2",
			"10:44 serde_json 1.0.117",
			"14:11 clap 4.5.4",
		},
		"Every spelling of a dependency is declared, a renamed one under its real name; the package's own version is not"
	)

	--------------------------------------------------------------------------------
	-- PYPROJECT.TOML
	--------------------------------------------------------------------------------

	eq(
		scan(
			"pyproject",
			table.concat({
				"[project]",
				'version = "1.0.0"',
				'requires-python = ">=3.10"',
				"dependencies = [",
				'    "requests>=2.31.0",',
				'    "rich",',
				"]",
				"",
				"[tool.poetry.dependencies]",
				'python = "^3.12"',
				'pydantic = "^2.7.1"',
				'httpx = { version = "~0.27.0", extras = ["http2"] }',
			}, "\n")
		),
		{
			"5:15 requests >=2.31.0",
			"11:13 pydantic ^2.7.1",
			"12:22 httpx ~0.27.0",
		},
		"Requirement strings and Poetry entries are declared; the interpreter and the project's own version are not"
	)

	--------------------------------------------------------------------------------
	-- POM.XML
	--------------------------------------------------------------------------------

	eq(
		scan(
			"maven",
			table.concat({
				"<project>",
				"  <version>1.0.0</version>",
				"  <parent>",
				"    <groupId>org.springframework.boot</groupId>",
				"    <artifactId>spring-boot-starter-parent</artifactId>",
				"    <version>3.2.5</version>",
				"  </parent>",
				"  <properties><log4j.version>2.17.1</log4j.version></properties>",
				"  <dependencies>",
				"    <dependency>",
				"      <groupId>org.apache.logging.log4j</groupId>",
				"      <artifactId>log4j-core</artifactId>",
				"      <version>2.14.1</version>",
				"    </dependency>",
				"    <dependency>",
				"      <groupId>com.example</groupId>",
				"      <artifactId>managed</artifactId>",
				"    </dependency>",
				"    <dependency>",
				"      <groupId>com.example</groupId>",
				"      <artifactId>by-property</artifactId>",
				"      <version>${log4j.version}</version>",
				"    </dependency>",
				"    <!-- <dependency><groupId>x</groupId><artifactId>y</artifactId><version>9.9.9</version></dependency> -->",
				"  </dependencies>",
				"  <build><plugins><plugin>",
				"    <artifactId>maven-compiler-plugin</artifactId>",
				"    <version>3.13.0</version>",
				"    <configuration><release>21</release><version>8.8.8</version></configuration>",
				"  </plugin></plugins></build>",
				"</project>",
			}, "\n")
		),
		{
			"6:13 org.springframework.boot:spring-boot-starter-parent 3.2.5",
			"13:15 org.apache.logging.log4j:log4j-core 2.14.1",
			"28:13 org.apache.maven.plugins:maven-compiler-plugin 3.13.0",
		},
		"Dependencies, the parent and plugins are declared, a plugin under Maven's default group; "
			.. "the project's own version, properties, property references, comments and configuration are not"
	)

	eq(
		Declared.scan("maven", {
			"<dependency><groupId>g</groupId><artifactId>a</artifactId><version>1.2.3</version></dependency>",
		})[1],
		{
			ecosystem = "maven",
			package = { namespace = "g", name = "a" },
			label = "g:a",
			version = "1.2.3",
			operator = "",
			row = 1,
			col = 67,
			end_col = 72,
		},
		"The > that closes a tag is not an operator"
	)

	--------------------------------------------------------------------------------
	-- SEVERAL ON ONE LINE
	--------------------------------------------------------------------------------

	eq(
		scan("npm", '{ "dependencies": { "a": "1.0.0", "b": "^2.0.0", "c": "1.0.0 || 3.0.0" } }'),
		{
			"1:26 a 1.0.0",
			"1:41 b ^2.0.0",
			"1:55 c 1.0.0",
			"1:64 c 3.0.0",
		},
		"Several dependencies on a line are each found, and each alternative of a range"
	)

	--------------------------------------------------------------------------------
	-- EDGES
	--------------------------------------------------------------------------------

	ok(Declared.supports("npm"), "A manifest with a reader is supported")
	ok(not Declared.supports("gradle"), "A manifest without a reader is not")
	ok(not Declared.supports(nil), "No manifest is not supported")

	eq(Declared.scan("gradle", { 'implementation "g:a:1.0"' }), {}, "An unsupported manifest declares nothing")
	eq(Declared.scan("npm", {}), {}, "An empty file declares nothing")
	eq(Declared.scan("npm", nil), {}, "A missing file declares nothing")
	eq(Declared.scan("requirements", { "", "   ", "# 1.0.0" }), {}, "Blank and comment lines declare nothing")

	-- Digits inside a name are not versions.
	eq(
		scan("requirements", "log4j2==2.17.1\npython3-openid==3.2.0\nh2==4.1.0"),
		{
			"1:8 log4j2 ==2.17.1",
			"2:16 python3-openid ==3.2.0",
			"3:4 h2 ==4.1.0",
		},
		"A digit inside a package name must not be taken for a version"
	)

	--------------------------------------------------------------------------------
	-- ROBUSTNESS AND COST
	--------------------------------------------------------------------------------

	local raised

	for _, manifest in ipairs({ "maven", "cargo", "npm", "requirements", "pyproject" }) do
		for _, text in ipairs({
			'{{{{ "1.0.0": "1.0.0" ]]]] 1.0.0',
			"[[[[1.0.0]]]]\n= = 1.0.0 \"1.0.0",
			"<version>1.0.0<version>1.0.0</a></b>",
			"1.0.0==1.0.0==1.0.0",
			"\0001.0.0\255 2.0.0",
			string.rep("1.0.0 ", 300),
		}) do
			if not pcall(Declared.scan, manifest, vim.split(text, "\n", { plain = true })) then
				raised = manifest .. ": " .. text:sub(1, 20)
			end
		end
	end

	eq(raised, nil, "No input may raise, whatever reader it is given to")

	-- A large manifest must be scanned quickly enough to do on opening it.
	local large = { "{", '  "dependencies": {' }

	for index = 1, 400 do
		table.insert(large, string.format('    "package-%d": "^%d.%d.0",', index, index % 9, index % 20))
	end

	table.insert(large, '    "last": "1.0.0"')
	table.insert(large, "  }")
	table.insert(large, "}")

	local started = vim.uv.hrtime()
	local found = Declared.scan("npm", large)
	local elapsed = (vim.uv.hrtime() - started) / 1e6

	eq(#found, 401, "Every dependency of a large manifest must be found")

	ok(
		elapsed < 2000,
		string.format("Scanning 401 dependencies took %.0f ms", elapsed)
	)
end
