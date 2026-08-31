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
end
