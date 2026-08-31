<div align="center">

# blink-cmp-deps

Dependency completion for [`blink.cmp`](https://github.com/Saghen/blink.cmp).

Maven · Gradle Groovy DSL · Gradle Kotlin DSL · Gradle Version Catalogs

[![Tests](https://github.com/Mestane/blink-cmp-deps/actions/workflows/test.yml/badge.svg)](https://github.com/Mestane/blink-cmp-deps/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

https://github.com/user-attachments/assets/ae694858-a4c8-4c54-b921-d886db63b21a

## Features

| Source | File | Completion |
| --- | --- | --- |
| Maven | `pom.xml` | group, artifact, version, scope, packaging, classifier, type, lifecycle and common POM values |
| Gradle Groovy DSL | `build.gradle` | dependency coordinates, map notation, platform notation and multiline declarations |
| Gradle Kotlin DSL | `build.gradle.kts` | dependency coordinates **and `libs.*` Version Catalog accessors** |
| Gradle Version Catalog | `*.versions.toml` | modules, groups, artifacts, versions and `version.ref` |

Also included:

- Maven Central support out of the box
- semantic version ranking (`2.10.0` > `2.9.0`)
- Maven qualifier handling (`alpha`, `beta`, `M`, `RC`, `SNAPSHOT`, `Final`, `RELEASE`, `SP`)
- persistent cache across Neovim sessions
- generic Maven repository version resolution
- Nexus group, artifact and version completion
- async requests, in-flight request coalescing and result deduplication
- optional JDTLS-backed Maven search

## Requirements

- Neovim with `vim.system`
- [`blink.cmp`](https://github.com/Saghen/blink.cmp)
- `curl`

JDTLS is **not required**.

After installation:

```vim
:checkhealth blink_deps
```

## Installation

### lazy.nvim

Add `blink-cmp-deps` as a dependency of `blink.cmp` and register a single provider:

```lua
{
    "saghen/blink.cmp",

    dependencies = {
        "Mestane/blink-cmp-deps",
    },

    opts = {
        sources = {
            default = {
                "lsp",
                "path",
                "snippets",
                "buffer",
                "deps",
            },

            providers = {
                deps = {
                    name = "Dependencies",
                    module = "blink_deps",
                    async = true,
                },
            },
        },
    },
}
```

That's it.

No `require("blink_deps").setup()` call is needed, and you do not need separate Blink providers for Maven, Gradle, Kotlin DSL or Version Catalogs.

`blink-cmp-deps` detects the current file and routes completion internally.

## Source selection

All supported sources are enabled by default.

If you only want some of them, use `enabled_sources`:

```lua
deps = {
    name = "Dependencies",
    module = "blink_deps",
    async = true,

    opts = {
        enabled_sources = {
            "maven",
            "gradle_kts",
        },
    },
},
```

Available values:

| Name | Enables |
| --- | --- |
| `maven` | `pom.xml` |
| `gradle` | `build.gradle` |
| `gradle_kts` | `build.gradle.kts` dependency coordinates **and `libs.*` accessors** |
| `version_catalog` | `*.versions.toml` |

The sources are independent. For example:

```lua
enabled_sources = { "maven" }
```

enables only Maven support.

An empty list disables all dependency sources:

```lua
enabled_sources = {}
```

## Usage

### Maven

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
    <version></version>
</dependency>
```

Completion is available for dependency coordinates and common Maven values such as scopes, packaging, classifiers, dependency types, lifecycle phases and repository policies.

### Gradle Groovy DSL

```groovy
dependencies {
    implementation "org.springframework.kafka:spring-kafka:"
}
```

Function, platform, map and multiline notation are supported:

```groovy
implementation("org.springframework.kafka:spring-kafka:")

implementation platform("org.springframework.boot:spring-boot-dependencies:")

implementation group: "org.springframework.kafka",
               name: "spring-kafka",
               version: ""
```

### Gradle Kotlin DSL

```kotlin
dependencies {
    implementation("org.springframework.kafka:spring-kafka:")
}
```

Platform notation is also supported:

```kotlin
implementation(platform("org.springframework.boot:spring-boot-dependencies:"))
implementation(enforcedPlatform("org.springframework.boot:spring-boot-dependencies:"))
```

The same `gradle_kts` source also completes Gradle Version Catalog accessors from `gradle/libs.versions.toml`:

```kotlin
dependencies {
    implementation(libs.spring.kafka)
    implementation(libs.bundles.spring.stack)
}

val version = libs.versions.spring.kafka
```

Plugin aliases are supported inside `alias(...)`:

```kotlin
plugins {
    alias(libs.plugins.spring.boot)
}
```

Catalog accessor completion is context-aware, so dependency, bundle, version and plugin namespaces are suggested only where they make sense.

### Gradle Version Catalog

```toml
[versions]
spring = "7.0.0"

[libraries]
spring-kafka = "org.springframework.kafka:spring-kafka:"
spring-web = {
    module = "org.springframework:spring-web",
    version.ref = "spring"
}
```

Supported library fields include:

```text
module
group
name
version
version.ref
```

Inline, shorthand and dotted TOML declarations are supported.

Aliases such as:

```toml
spring-kafka = "org.springframework.kafka:spring-kafka:4.0.0"
```

are exposed in Kotlin DSL as:

```kotlin
libs.spring.kafka
```

## Configuration

All plugin options are passed through the Blink provider's `opts` table:

```lua
deps = {
    name = "Dependencies",
    module = "blink_deps",
    async = true,

    opts = {
        -- blink-cmp-deps options
    },
},
```

### Network and debugging

```lua
opts = {
    debug = false,
    connect_timeout = 3,
    max_time = 3,
    debounce_ms = 250,
    retries = 1,
}
```

`debug = true` enables diagnostic notifications for repository/search requests.

`debounce_ms` controls how long completion waits after the last keystroke before
querying Maven Central. Blink issues a completion request per keystroke, so
without a delay every intermediate prefix would reach the network. Lower it for
a snappier feel, raise it if you hit rate limits. Cached and already discovered
results are always shown immediately, regardless of this setting.

`retries` is how many extra attempts a request gets after a transport failure
such as a timeout or a dropped connection. Maven Central occasionally stalls on
a request that succeeds immediately when repeated, so one retry is the default.
Rejected queries are never retried, since the answer would not change.

`max_time` is deliberately short. A healthy Maven Central request answers in well
under a second, and one that has not answered in three seconds does not answer in
seven either, so failing fast and retrying is quicker than waiting. `max_time`
and `connect_timeout` apply to every backend; Nexus and generic Maven
repositories keep a longer default of 7 seconds, since they are often on slower
internal networks.

### Maven Central

Maven Central is enabled by default.

If your environment uses a private repository or mirror and does not allow direct access to Maven Central, disable it with:

```lua
opts = {
    central = {
        enabled = false,
    },

    repositories = {
        {
            name = "Company Nexus",
            type = "nexus",
            url = "https://nexus.company.com",
            repository = "maven-releases",
        },
    },
}
```
When disabled, blink-cmp-deps does not make requests to Maven Central or read Maven Central cache entries.

Configured repositories continue to work normally. Nexus repositories can provide group,

artifact and version completion, while generic Maven repositories provide version completion for known coordinates.

### Persistent cache

Persistent caching is enabled by default:

```lua
opts = {
    cache = {
        enabled = true,
        ttl = 86400,
    },
}
```

Disable it with:

```lua
opts = {
    cache = {
        enabled = false,
    },
}
```

The cache lives under Neovim's standard cache directory:

```text
stdpath("cache")/blink-cmp-deps
```

In-memory caching is still used during the current Neovim session.

### Generic Maven repositories

Generic Maven repositories can contribute **version completion for known coordinates**.

`url` must point directly to the Maven content root:

```lua
opts = {
    repositories = {
        {
            name = "Company Releases",
            url = "https://repo.company.com/maven/releases",
        },
    },
}
```

For:

```text
com.company.payment:payment-client
```

the plugin reads:

```text
https://repo.company.com/maven/releases/
└── com/company/payment/payment-client/maven-metadata.xml
```

Generic Maven repositories do not provide generic group or artifact discovery.

### Nexus repositories

Nexus repositories can provide group, artifact and version completion:

```lua
opts = {
    repositories = {
        {
            name = "Company Nexus",
            type = "nexus",
            url = "https://nexus.company.com",
            repository = "maven-releases",
        },
    },
}
```

For Nexus:

- `url` is the Nexus instance root
- `repository` is the Nexus repository name
- group and artifact discovery use the Nexus Search API
- version completion uses Maven `maven-metadata.xml`
- group search starts after three typed characters
- results are merged with Maven Central and deduplicated when Maven Central is enabled

Multiple repositories can be configured at the same time.

### Optional JDTLS Maven search

The Maven source can optionally use Maven search commands exposed through a compatible JDTLS / vscode-maven setup:

```lua
opts = {
    jdtls = {
        enabled = true,
        -- index_path = "/path/to/vscode-maven/extension/resources/IndexData",
    },
}
```

This is disabled by default and is not needed for normal Maven Central completion.

## How it works

```text
                         blink_deps
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
       pom.xml         build.gradle     build.gradle.kts
          │                 │                 │
        Maven             Gradle          Gradle Kotlin DSL
                                              │
                                              └── libs.* accessors

   *.versions.toml
          │
   Version Catalog

Coordinate completion
          │
          ▼
 blink_deps.coordinates
          │
   ┌──────┼──────────────┐
   │      │              │
Central  Nexus     Maven repositories
```

Maven, Gradle and Kotlin DSL coordinate sources share the same completion layer.

Maven Central is used by default. Configured repositories can contribute additional results, while Gradle Version Catalog accessors are read locally from `gradle/libs.versions.toml`.

## Development

Run the offline test suite with:

```bash
make test
```

The tests do not contact Maven Central or Nexus.

Coverage includes:

- unified provider routing and source selection
- Maven, Gradle Groovy DSL and Gradle Kotlin DSL
- Gradle Version Catalog editing and generated accessors
- semantic version ranking
- persistent cache behavior
- custom Maven repositories
- Nexus search, pagination, caching and version resolution
- request deduplication and cancellation

### Internal source modules

The recommended public provider is:

```lua
module = "blink_deps"
```

Internally it delegates to:

```text
blink_deps.maven
blink_deps.gradle
blink_deps.gradle_kts
blink_deps.catalog
blink_deps.gradle_catalog_accessor
```

These modules remain separate so each syntax can own its parser and completion behavior, while users configure only one Blink source.

When adding a new supported build format, prefer wiring it through the unified `blink_deps` provider instead of requiring users to register another Blink source manually.

## Roadmap

- [x] Maven completion
- [x] Gradle Groovy DSL completion
- [x] Gradle Kotlin DSL completion
- [x] Gradle Version Catalog editing
- [x] `libs.*`, bundle, version and plugin accessors
- [x] persistent cache
- [x] generic Maven repositories
- [x] Nexus repository support
- [x] semantic version ranking
- [ ] richer dependency metadata

## License

MIT
