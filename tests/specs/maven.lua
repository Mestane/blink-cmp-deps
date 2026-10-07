local Central = require("blink_deps.central")
local Maven = require("blink_deps.maven")

return function(test)
	local eq = test.eq
	local ok = test.ok
	local contains = test.contains

	--------------------------------------------------------------------------------
	-- MAVEN
	--------------------------------------------------------------------------------

	local maven_source = Maven.new({})
	eq(maven_source.opts.jdtls.enabled, false, "JDTLS must be disabled by default")

	local maven_self_test = Maven.self_test()

	eq(maven_self_test.jdtls_default, false, "self-test must report JDTLS disabled by default")
	eq(maven_self_test.central_url, Central.URL, "Maven source must use the shared Central backend URL")

	local maven_qualified = Maven.debug_group_plan("org.springframework.ka")

	ok(
		contains(maven_qualified.central, "g:org.springframework.ka*"),
		"qualified Maven group search must use an unquoted Maven Central query"
	)

	local maven_broad = Maven.debug_group_plan("spring")

	ok(
		#maven_broad.central > 0,
		"plain Maven group search must produce at least one Central query"
	)


	local maven_artifact = Maven.debug_artifact_queries(
		"org.springframework.kafka",
		"spri",
		"spring-kafka"
	)

	eq(
		maven_artifact.group_catalog,
		"g:org.springframework.kafka",
		"Maven artifact catalog query must remain unquoted"
	)

	-- A leading wildcard on the a field is rejected or times out, and the
	-- catalog query already returns the whole group.
	eq(
		maven_artifact.target,
		nil,
		"Maven artifact completion must not plan a leading wildcard query"
	)

	eq(
		maven_artifact.version_query,
		"g:org.springframework.kafka AND a:spring-kafka",
		"Maven version query must remain unquoted"
	)

	--------------------------------------------------------------------------------
	-- MAVEN DEPENDENCY DISCOVERY
	--
	-- Maven splits a coordinate across two elements, so accepting a search
	-- result has to fill both. Only the immediately following line is touched,
	-- and only when it already holds an <artifactId>.
	--------------------------------------------------------------------------------

	local function maven_discovery_ctx(lines, row)
		local value = "jackson-databind"
		local start_index = lines[row]:find(value, 1, true)

		return {
			tag = "groupId",
			value = value,
			row = row,
			col = start_index - 1 + #value,
		},
			{
				start_row = row - 1,
				end_row = row + 2,
				lines = lines,
			}
	end

	local maven_filled_ctx, maven_filled_block =
		maven_discovery_ctx({
			"        <dependency>",
			"            <groupId>jackson-databind</groupId>",
			"            <artifactId></artifactId>",
			"        </dependency>",
		}, 2)

	local maven_filled_edit = Maven.debug_discovery_edit(
		maven_filled_ctx,
		maven_filled_block
	)

	eq(
		maven_filled_edit.newText,
		"com.fasterxml.jackson.core</groupId>\n            <artifactId>jackson-databind</artifactId>",
		"Maven discovery must fill groupId and artifactId in one edit"
	)

	eq(
		{
			maven_filled_edit.range["end"].line,
			maven_filled_edit.range["end"].character,
		},
		{
			2,
			#"            <artifactId></artifactId>",
		},
		"Maven discovery must replace the whole artifactId line"
	)

	-- Measuring where the existing content ends is fragile, so the closing tag
	-- is rewritten instead.
	local maven_occupied_ctx, maven_occupied_block =
		maven_discovery_ctx({
			"        <dependency>",
			"            <groupId>jackson-databind</groupId>",
			"            <artifactId>kafka-metadata</artifactId>   ",
			"        </dependency>",
		}, 2)

	local maven_occupied_edit = Maven.debug_discovery_edit(
		maven_occupied_ctx,
		maven_occupied_block
	)

	eq(
		maven_occupied_edit.newText,
		"com.fasterxml.jackson.core</groupId>\n            <artifactId>jackson-databind</artifactId>",
		"An artifactId that already holds a value must be rewritten whole"
	)

	eq(
		maven_occupied_edit.range["end"].character,
		#"            <artifactId>kafka-metadata</artifactId>   ",
		"The replaced range must reach the end of the artifactId line"
	)

	--------------------------------------------------------------------------------
	-- MAVEN DISCOVERY ROUTING
	--
	-- Discovery offers whole coordinates, so it only runs when both halves can
	-- be written. Otherwise the artifact half of every suggestion would be
	-- silently dropped and group completion is the honest answer.
	--------------------------------------------------------------------------------

	ok(
		Maven.debug_discovery_context(
			maven_filled_ctx,
			maven_filled_block
		),
		"A fillable artifactId line must enable discovery"
	)

	local maven_gap_ctx, maven_gap_block =
		maven_discovery_ctx({
			"        <dependency>",
			"            <groupId>jackson-databind</groupId>",
			"            <!-- note -->",
			"            <artifactId></artifactId>",
		}, 2)

	eq(
		Maven.debug_discovery_context(
			maven_gap_ctx,
			maven_gap_block
		),
		false,
		"An intervening line must fall back to group completion"
	)

	local maven_missing_ctx, maven_missing_block =
		maven_discovery_ctx({
			"        <dependency>",
			"            <groupId>jackson-databind</groupId>",
			"        </dependency>",
		}, 2)

	eq(
		Maven.debug_discovery_context(
			maven_missing_ctx,
			maven_missing_block
		),
		false,
		"A missing artifactId element must fall back to group completion"
	)

	local maven_qualified_ctx, maven_qualified_block =
		maven_discovery_ctx({
			"        <dependency>",
			"            <groupId>jackson-databind</groupId>",
			"            <artifactId></artifactId>",
			"        </dependency>",
		}, 2)

	maven_qualified_ctx.value = "org.springframework."

	eq(
		Maven.debug_discovery_context(
			maven_qualified_ctx,
			maven_qualified_block
		),
		false,
		"A qualified namespace must stay with group completion"
	)

	--------------------------------------------------------------------------------

	--------------------------------------------------------------------------------
	-- COORDINATE RESOLUTION
	--
	-- The structural cases are covered by tests/specs/maven_context.lua. These
	-- cover what Maven adds: which coordinate a lookup is made for.
	--------------------------------------------------------------------------------

	local function context(fixture)
		local lines = vim.split(fixture, "\n", { plain = true })

		for row, line in ipairs(lines) do
			local column = line:find("|", 1, true)

			if column then
				lines[row] = line:sub(1, column - 1) .. line:sub(column + 1)

				return Maven.debug_context(lines, row, column - 1), lines, row, column - 1
			end
		end

		error("fixture has no cursor")
	end

	eq(
		context([[
<dependency>
  <groupId>org.example</groupId>
  <artifactId>demo</artifactId>
  <version>1.|</version>
</dependency>]]),
		{
			tag = "version",
			value = "1.",
			block = "dependency",
			group_id = "org.example",
			artifact_id = "demo",
		},
		"A dependency version must be looked up for the dependency's coordinate"
	)

	local PLUGIN_WITH_DEPENDENCIES = [[
<project>
  <build>
    <plugins>
      <plugin>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>|</version>
        <dependencies>
          <dependency>
            <groupId>org.ow2.asm</groupId>
            <artifactId>asm</artifactId>
            <version>9.7</version>
          </dependency>
        </dependencies>
      </plugin>
    </plugins>
  </build>
</project>]]

	eq(
		context(PLUGIN_WITH_DEPENDENCIES),
		{
			tag = "version",
			value = "",
			block = "plugin",
			group_id = "org.apache.maven.plugins",
			artifact_id = "maven-compiler-plugin",
		},
		"A plugin without a groupId must use the default group, not a nested dependency's"
	)

	eq(
		context([[
<plugin>
  <groupId>org.springframework.boot</groupId>
  <artifactId>|</artifactId>
</plugin>]]).group_id,
		"org.springframework.boot",
		"A plugin with a groupId must use it"
	)

	eq(
		context([[
<dependency>
  <artifactId>demo</artifactId>
  <version>|</version>
</dependency>]]).group_id,
		nil,
		"A dependency without a groupId has no default group"
	)

	eq(
		context([[
<plugin>
  <artifactId>maven-compiler-plugin</artifactId>
  <configuration>
    <version>|</version>
  </configuration>
</plugin>]]),
		{ tag = "version", value = "" },
		"A version inside plugin configuration is not the plugin's version"
	)

	eq(
		context("<dependency>\n  <!-- <groupId>|</groupId> -->\n</dependency>"),
		nil,
		"A commented out element must not be completed"
	)

	--------------------------------------------------------------------------------
	-- END TO END
	--
	-- A real buffer and a real cursor, down to the registry being asked. The
	-- registry is hand written, so no network is involved.
	--------------------------------------------------------------------------------

	do
		local Util = require("blink_deps.util")
		local original_defer = Util.defer

		rawset(Util, "defer", function(_, fn)
			fn()
		end)

		local _, lines, row, col = context(PLUGIN_WITH_DEPENDENCIES)

		local original_name = vim.api.nvim_buf_get_name(0)
		local original_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

		vim.api.nvim_buf_set_name(0, "/tmp/blink-cmp-deps-maven-e2e/pom.xml")
		vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
		vim.api.nvim_win_set_cursor(0, { row, col })

		local asked = {}

		local source = Maven.new({})

		source.registry_list = {
			{
				id = "test",
				name = "Test",
				kind = "test",
				capabilities = { versions = true },
				versions = function(_, _, package, callback)
					table.insert(asked, vim.deepcopy(package))

					callback({
						{ value = "3.13.0", timestamp = 0 },
					}, nil)
				end,
			},
		}

		local responses = {}

		source:get_completions({
			get_pos = function()
				return {
					row = row - 1,
					col = col,
				}
			end,
		}, function(result)
			table.insert(responses, result)
		end)

		eq(
			asked,
			{
				{
					namespace = "org.apache.maven.plugins",
					name = "maven-compiler-plugin",
				},
			},
			"Version completion in a real buffer must ask for the plugin's own coordinate"
		)

		eq(
			responses[#responses].items[1].label,
			"3.13.0",
			"The registry's versions must reach the completion menu"
		)

		eq(
			responses[#responses].items[1].textEdit.range,
			{
				start = { line = row - 1, character = col },
				["end"] = { line = row - 1, character = col },
			},
			"The edit must replace exactly what was typed"
		)

		vim.api.nvim_buf_set_lines(0, 0, -1, false, original_lines)
		vim.api.nvim_buf_set_name(0, original_name)

		rawset(Util, "defer", original_defer)
	end
end
