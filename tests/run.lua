local Util = require("blink_deps.util")
local Central = require("blink_deps.central")
local Maven = require("blink_deps.maven")

local total = 0

local function fail(message)
	error(message, 2)
end

local function ok(condition, message)
	total = total + 1
	if not condition then
		fail("FAILED: " .. message)
	end
end

local function eq(actual, expected, message)
	total = total + 1
	if not vim.deep_equal(actual, expected) then
		fail(string.format(
			"FAILED: %s\nexpected: %s\nactual:   %s",
			message,
			vim.inspect(expected),
			vim.inspect(actual)
		))
	end
end

local function contains(values, expected)
	for _, value in ipairs(values) do
		if value == expected then
			return true
		end
	end
	return false
end

-- Public defaults -------------------------------------------------------------

local source = Maven.new({})
eq(source.opts.jdtls.enabled, false, "JDTLS must be disabled by default")

local self_test = Maven.self_test()
eq(self_test.jdtls_default, false, "self-test must report JDTLS disabled by default")
eq(self_test.central_url, Central.URL, "Maven source must use the shared Central backend URL")
ok(self_test.kafka, "Spring Kafka cold-start group must exist")
ok(self_test.apache_kafka, "Apache Kafka cold-start group must exist")
ok(self_test.google_guava, "Google Guava cold-start group must exist")

-- Group query planning --------------------------------------------------------

local qualified = Maven.debug_group_plan("org.springframework.ka")
ok(
	contains(qualified.central, "g:org.springframework.ka*"),
	"qualified group search must use an unquoted Maven Central query"
)

local broad = Maven.debug_group_plan("spring")
ok(#broad.central > 0, "plain group search must produce at least one Central query")

local seeds = Maven.debug_seed_groups("org.springframework.ka")
ok(contains(seeds, "org.springframework.kafka"), "qualified cold-start filtering must keep Spring Kafka")

-- Artifact/version query planning --------------------------------------------

local artifact = Maven.debug_artifact_queries(
	"org.springframework.kafka",
	"spri",
	"spring-kafka"
)

eq(
	artifact.group_catalog,
	"g:org.springframework.kafka",
	"artifact catalog query must remain unquoted"
)
eq(
	artifact.target,
	"g:org.springframework.kafka AND a:*spri*",
	"targeted artifact query must remain unquoted"
)
eq(
	artifact.version_query,
	"g:org.springframework.kafka AND a:spring-kafka",
	"version query must remain unquoted"
)

-- Shared result helpers -------------------------------------------------------

local docs = Util.dedupe_docs({
	{ g = "org.example", a = "demo", latestVersion = "1.0.0" },
	{ g = "org.example", a = "demo", latestVersion = "1.0.0" },
	{ g = "org.example", a = "other", latestVersion = "2.0.0" },
})
eq(#docs, 2, "duplicate Central/JDTLS documents must be removed")

local artifacts = Util.extract_artifacts(docs, "org.example")
eq(#artifacts, 2, "artifact extraction must preserve distinct artifacts")
eq(artifacts[1].artifact, "demo", "artifacts must be sorted by artifactId")
eq(artifacts[2].artifact, "other", "artifacts must be sorted by artifactId")

print(string.format("blink-cmp-deps: %d tests passed", total))
