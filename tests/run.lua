local Test = dofile("tests/helpers.lua")

local test = Test.new()

local specs = {
	"tests/specs/maven.lua",
	"tests/specs/gradle.lua",
	"tests/specs/gradle_kts.lua",
	"tests/specs/catalog.lua",
	"tests/specs/gradle_catalog_accessor.lua",
	"tests/specs/disk_cache.lua",
	"tests/specs/nexus.lua",
	"tests/specs/repository.lua",
	"tests/specs/coordinates.lua",
	"tests/specs/version_rank.lua",
	"tests/specs/util.lua",
}

for _, path in ipairs(specs) do
	dofile(path)(test)
end

print(string.format(
	"blink-cmp-deps: %d tests passed",
	test.total
))
