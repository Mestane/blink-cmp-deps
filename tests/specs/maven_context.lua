local Context = require("blink_deps.maven_context")

return function(test)
	local eq = test.eq

	local BLOCK_TYPES = {
		dependency = true,
		exclusion = true,
		plugin = true,
		parent = true,
		extension = true,
	}

	--------------------------------------------------------------------------------
	-- HARNESS
	--
	-- A fixture is a pom fragment with | where the cursor is.
	--------------------------------------------------------------------------------

	local function at(fixture)
		local lines = vim.split(fixture, "\n", { plain = true })

		for row, line in ipairs(lines) do
			local column = line:find("|", 1, true)

			if column then
				lines[row] = line:sub(1, column - 1) .. line:sub(column + 1)

				return Context.at(lines, row, column - 1, BLOCK_TYPES), lines
			end
		end

		error("fixture has no cursor")
	end

	-- The parts of a context a spec usually cares about.
	local function summary(fixture)
		local ctx = at(fixture)

		if not ctx then
			return nil
		end

		return {
			tag = ctx.tag,
			value = ctx.value,
			block = ctx.block and ctx.block.type or nil,
			fields = ctx.block and ctx.block.fields or nil,
		}
	end

	--------------------------------------------------------------------------------
	-- THE ELEMENT UNDER THE CURSOR
	--------------------------------------------------------------------------------

	eq(
		summary([[
<project>
  <dependencies>
    <dependency>
      <groupId>org.spring|</groupId>
      <artifactId></artifactId>
    </dependency>
  </dependencies>
</project>]]),
		{
			tag = "groupId",
			value = "org.spring",
			block = "dependency",
			fields = { groupId = "org.spring" },
		},
		"The element, the typed value and the enclosing coordinate must be found"
	)

	eq(
		summary("<project><packaging>|</packaging></project>"),
		{ tag = "packaging", value = "" },
		"An element outside any coordinate must be found without a block"
	)

	eq(
		summary("<project><packaging>ja|r</packaging></project>"),
		{ tag = "packaging", value = "ja" },
		"Only what precedes the cursor is the typed value"
	)

	eq(
		summary("<dependency><version>1.0|"),
		{
			tag = "version",
			value = "1.0",
			block = "dependency",
			fields = {},
		},
		"An element that is not closed yet must still be found"
	)

	eq(
		at("<a><b>x|</b></a>").path,
		{ "a", "b" },
		"The path must run from the root to the element"
	)

	eq(
		summary(
			'<project xmlns="http://maven.apache.org/POM/4.0.0">'
				.. '<m:packaging xml:space="preserve">w|</m:packaging>'
				.. "</project>"
		),
		{ tag = "packaging", value = "w" },
		"Attributes and namespace prefixes must not hide an element"
	)

	eq(
		summary('<plugin note="a > b"><version>3|</version></plugin>').block,
		"plugin",
		"A > inside an attribute value must not end the tag"
	)

	--------------------------------------------------------------------------------
	-- NOT IN ELEMENT TEXT
	--------------------------------------------------------------------------------

	eq(
		at("<dependency><groupId>a</groupId>|</dependency>"),
		nil,
		"Between children there is no element text to complete"
	)

	eq(at("<dependency><grou|pId>"), nil, "Inside a tag there is nothing to complete")
	eq(at("<dependency>\n  <!-- <groupId>or|g -->\n</dependency>"), nil, "Inside a comment there is nothing to complete")
	eq(at("<dependency><!-- unterminated <groupId>|"), nil, "An unterminated comment swallows the cursor")
	eq(at("|<project></project>"), nil, "Before the document there is nothing to complete")
	eq(at("<project></project>|"), nil, "After the document there is nothing to complete")
	eq(at("<project><br/>|</project>"), nil, "After a self closing child there is no element text")
	eq(at("|"), nil, "An empty buffer has no context")

	eq(
		Context.at({ "<a>" }, 5, 0, BLOCK_TYPES),
		nil,
		"A cursor beyond the buffer must not raise"
	)

	eq(Context.at(nil, 1, 0, BLOCK_TYPES), nil, "A missing buffer must not raise")

	--------------------------------------------------------------------------------
	-- COMMENTS AND OTHER SKIPPED CONSTRUCTS
	--------------------------------------------------------------------------------

	eq(
		summary([[
<project>
  <!--
  <dependency>
    <groupId>commented.out</groupId>
  -->
  <packaging>|</packaging>
</project>]]),
		{ tag = "packaging", value = "" },
		"An element opened inside a comment must not become the enclosing coordinate"
	)

	eq(
		summary([[
<dependency>
  <!-- <groupId>old.group</groupId> -->
  <groupId>new.group</groupId>
  <artifactId>demo</artifactId>
  <version>|</version>
</dependency>]]).fields,
		{ groupId = "new.group", artifactId = "demo" },
		"A commented out sibling must not supply a field value"
	)

	eq(
		summary([=[
<?xml version="1.0"?>
<!DOCTYPE project>
<project>
  <description><![CDATA[ <dependency> not markup ]]></description>
  <packaging>p|</packaging>
</project>]=]),
		{ tag = "packaging", value = "p" },
		"Declarations, processing instructions and CDATA must be skipped"
	)

	eq(
		summary("<project><description>a < b</description><packaging>|</packaging></project>"),
		{ tag = "packaging", value = "" },
		"A stray < in text must not derail the scan"
	)

	--------------------------------------------------------------------------------
	-- FIELDS BELONG TO THEIR OWN COORDINATE
	--------------------------------------------------------------------------------

	-- The reported case: a plugin that omits its groupId and carries its own
	-- dependencies. The plugin has no groupId; the nested one is not its.
	eq(
		summary([[
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
</plugin>]]),
		{
			tag = "version",
			value = "",
			block = "plugin",
			fields = { artifactId = "maven-compiler-plugin" },
		},
		"A nested dependency must not lend its coordinates to the plugin around it"
	)

	eq(
		summary([[
<plugin>
  <artifactId>maven-compiler-plugin</artifactId>
  <dependencies>
    <dependency>
      <groupId>org.ow2.asm</groupId>
      <artifactId>asm</artifactId>
      <version>|</version>
    </dependency>
  </dependencies>
</plugin>]]),
		{
			tag = "version",
			value = "",
			block = "dependency",
			fields = { groupId = "org.ow2.asm", artifactId = "asm" },
		},
		"Inside the nested dependency its own coordinates must be used"
	)

	eq(
		summary([[
<dependency>
  <groupId>org.example</groupId>
  <artifactId>demo</artifactId>
  <exclusions>
    <exclusion>
      <groupId>commons-logging</groupId>
      <artifactId>|</artifactId>
    </exclusion>
  </exclusions>
  <version>1.0</version>
</dependency>]]),
		{
			tag = "artifactId",
			value = "",
			block = "exclusion",
			fields = { groupId = "commons-logging" },
		},
		"An exclusion is its own coordinate"
	)

	eq(
		summary([[
<dependency>
  <exclusions>
    <exclusion>
      <groupId>commons-logging</groupId>
      <artifactId>commons-logging</artifactId>
    </exclusion>
  </exclusions>
  <groupId>org.example</groupId>
  <artifactId>demo</artifactId>
  <version>|</version>
</dependency>]]).fields,
		{ groupId = "org.example", artifactId = "demo" },
		"Exclusions written first must not supply the dependency's coordinates"
	)

	-- Fields are read from the whole block, not only from above the cursor.
	eq(
		summary([[
<dependency>
  <version>|</version>
  <artifactId>demo</artifactId>
  <groupId>org.example</groupId>
</dependency>]]).fields,
		{ groupId = "org.example", artifactId = "demo" },
		"Siblings after the cursor must be read too"
	)

	-- Not a direct child: this version configures the plugin, it is not the
	-- plugin's version.
	eq(
		summary([[
<plugin>
  <artifactId>maven-compiler-plugin</artifactId>
  <configuration>
    <version>|</version>
  </configuration>
</plugin>]]),
		{ tag = "version", value = "" },
		"An element nested deeper is not a field of the coordinate around it"
	)

	-- Two coordinates in a row do not bleed into each other.
	eq(
		summary([[
<dependencies>
  <dependency>
    <groupId>first.group</groupId>
    <artifactId>first</artifactId>
  </dependency>
  <dependency>
    <artifactId>|</artifactId>
  </dependency>
</dependencies>]]).fields,
		{},
		"A previous coordinate must not supply fields to the next one"
	)

	--------------------------------------------------------------------------------
	-- LAYOUT
	--------------------------------------------------------------------------------

	eq(
		summary("<dependency><groupId>g</groupId><artifactId>a</artifactId><version>|</version></dependency>"),
		{
			tag = "version",
			value = "",
			block = "dependency",
			fields = { groupId = "g", artifactId = "a" },
		},
		"A coordinate written on one line must be understood"
	)

	eq(
		summary([[
<dependency>
  <groupId>
    org.example
  </groupId>
  <artifactId>demo</artifactId>
  <version>
    1.|
  </version>
</dependency>]]),
		{
			tag = "version",
			value = "1.",
			block = "dependency",
			fields = { groupId = "org.example", artifactId = "demo", version = "1." },
		},
		"A value on its own line must be read without its indentation"
	)

	eq(
		at("<description>first line\n  second|</description>"),
		nil,
		"A value already spanning several lines of text is not completed"
	)

	eq(
		summary("<dependency>\n  <version\n      >2|</version>\n</dependency>").tag,
		"version",
		"A tag broken across lines must be understood"
	)

	--------------------------------------------------------------------------------
	-- MALFORMED INPUT
	--------------------------------------------------------------------------------

	eq(
		summary([[
<dependency>
  <groupId>org.example</groupId>
  <artifactId>demo</artifactId>
  <version>1.|
</dependency>
<dependency>
  <groupId>other</groupId>
</dependency>]]),
		{
			tag = "version",
			value = "1.",
			block = "dependency",
			fields = { groupId = "org.example", artifactId = "demo" },
		},
		"An unclosed element under the cursor must not pull in the next coordinate"
	)

	eq(
		summary("<project></stray><dependency><scope>t|"),
		{ tag = "scope", value = "t", block = "dependency", fields = {} },
		"A closing tag that closes nothing must be ignored"
	)

	eq(
		summary("<dependency><scope></dependency><plugin><version>|"),
		{ tag = "version", value = "", block = "plugin", fields = {} },
		"An element left open inside a closed coordinate must be abandoned with it"
	)

	--------------------------------------------------------------------------------
	-- BLOCK EXTENT
	--------------------------------------------------------------------------------

	local extent, extent_lines = at([[
<project>
  <dependencies>
    <dependency>
      <groupId>|</groupId>
      <artifactId></artifactId>
    </dependency>
  </dependencies>
</project>]])

	eq(
		{ extent.block.start_row, extent.block.end_row, extent.row, extent.col },
		{ 3, 6, 4, #"      <groupId>" },
		"A block must report the lines of its opening and closing tags"
	)

	eq(extent.block.lines, extent_lines, "A block must expose the buffer lines")

	local open_ended = at("<dependency>\n  <groupId>|\n  <artifactId>x")

	eq(
		open_ended.block.end_row,
		3,
		"A block that is never closed must end at the last line"
	)

	--------------------------------------------------------------------------------
	-- ROBUSTNESS
	--
	-- Whatever is in the buffer, asking about any position must not raise.
	--------------------------------------------------------------------------------

	local hostile = {
		"<<<>>><//><!---->",
		"<a b='",
		"<a><![CDATA[",
		"</a></b></c>",
		"<?xml",
		"<a>\n<\n>\n</a>",
		string.rep("<a>", 200),
		"\0<a>\255</a>",
	}

	local raised

	for _, fixture in ipairs(hostile) do
		local lines = vim.split(fixture, "\n", { plain = true })

		for row, line in ipairs(lines) do
			for col = 0, #line do
				local ok = pcall(Context.at, lines, row, col, BLOCK_TYPES)

				if not ok then
					raised = fixture
				end
			end
		end
	end

	eq(raised, nil, "No position in a malformed buffer may raise")
end
