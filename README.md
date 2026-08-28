<div align="center">

# blink-cmp-deps

Dependency completion for
[`blink.cmp`](https://github.com/Saghen/blink.cmp).

Maven, Gradle Groovy DSL, Gradle Kotlin DSL, and Gradle Version Catalog support.

[![Tests](https://github.com/Mestane/blink-cmp-deps/actions/workflows/test.yml/badge.svg)](https://github.com/Mestane/blink-cmp-deps/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

https://github.com/user-attachments/assets/ae694858-a4c8-4c54-b921-d886db63b21a

## Features

| Source | File | Completion |
| --- | --- | --- |
| Maven | `pom.xml` | group, artifact, version, scope, packaging, classifier, type, and common POM values |
| Gradle Groovy DSL | `build.gradle` | string, function, map, platform, and multiline dependency notation |
| Gradle Kotlin DSL | `build.gradle.kts` | dependency coordinates, platform notation, and multiline declarations |
| Gradle Version Catalog | `libs.versions.toml` | libraries, modules, groups, artifacts, versions, and version references |
| Gradle Catalog Accessors | `build.gradle.kts` | `libs.*`, `libs.versions.*`, `libs.bundles.*`, and `libs.plugins.*` |

- Semantic version ranking for dependency versions
  - numeric ordering (`2.10.0` > `2.9.0`)
  - Maven qualifiers such as `SNAPSHOT`, `RC`, `M`, `beta`, and `alpha`
  - stable aliases such as `GA`, `Final`, and `RELEASE`
  - consistent ordering across Maven Central and custom repositories

Dependency coordinates are resolved through Maven Central and optional
repository backends.

Generic Maven repositories provide version completion for known coordinates.
Nexus repositories additionally provide group and artifact discovery through
the Nexus Search API.

Gradle Version Catalog accessors are discovered directly from
`gradle/libs.versions.toml`.

## Requirements

- Neovim with `vim.system`
- [`blink.cmp`](https://github.com/Saghen/blink.cmp)
- `curl`

JDTLS is **not required**.

After installation, run:

```vim
:checkhealth blink_deps
```

## Installation

### lazy.nvim

```lua
{
    "Mestane/blink-cmp-deps",
    dependencies = {
        "saghen/blink.cmp",
    },
}
```

Register the sources in your `blink.cmp` configuration:

```lua
sources = {
    per_filetype = {
        xml = {
            inherit_defaults = true,
            "maven",
        },

        groovy = {
            inherit_defaults = true,
            "gradle",
        },

        kotlin = {
            inherit_defaults = true,
            "gradle_kts",
            "gradle_catalog_accessor",
        },

        toml = {
            inherit_defaults = true,
            "catalog",
        },
    },

    providers = {
        maven = {
            name = "Maven",
            module = "blink_deps.maven",
            async = true,
            timeout_ms = 8000,
            min_keyword_length = 0,
            score_offset = 5,

            enabled = function()
                return vim.fn.fnamemodify(
                    vim.api.nvim_buf_get_name(0),
                    ":t"
                ) == "pom.xml"
            end,
        },

        gradle = {
            name = "Gradle",
            module = "blink_deps.gradle",
            async = true,
            timeout_ms = 8000,
            min_keyword_length = 0,
            score_offset = 5,

            enabled = function()
                return vim.fn.fnamemodify(
                    vim.api.nvim_buf_get_name(0),
                    ":t"
                ) == "build.gradle"
            end,
        },

        gradle_kts = {
            name = "Gradle Kotlin DSL",
            module = "blink_deps.gradle_kts",
            async = true,
            timeout_ms = 8000,
            min_keyword_length = 0,
            score_offset = 5,

            enabled = function()
                return vim.fn.fnamemodify(
                    vim.api.nvim_buf_get_name(0),
                    ":t"
                ) == "build.gradle.kts"
            end,
        },

        catalog = {
            name = "Gradle Version Catalog",
            module = "blink_deps.catalog",
        },

        gradle_catalog_accessor = {
            name = "Gradle Catalog",
            module = "blink_deps.gradle_catalog_accessor",
        },
    },
}
```

No `require("blink_deps").setup()` call is needed.

---

## Maven

### Dependency coordinates

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
    <version>3.</version>
</dependency>
```

Completion is available independently for:

```text
groupId     → org.springframework.kafka
artifactId  → spring-kafka
version     → matching versions
```

The Maven source also completes common POM values such as:

- dependency scopes
- packaging
- classifiers
- dependency types
- lifecycle phases
- repository policies
- common boolean and plugin fields

---

## Gradle Groovy DSL

### String notation

```groovy
dependencies {
    implementation 'org.springframework.kafka:spring-kafka:'
}
```

### Function notation

```groovy
implementation('org.springframework.kafka:spring-kafka:')
```

### Platform dependencies

```groovy
implementation platform('org.springframework.boot:spring-boot-dependencies:')
implementation(platform('org.springframework.boot:spring-boot-dependencies:'))

implementation enforcedPlatform('g:a:v')
implementation(enforcedPlatform('g:a:v'))
```

### Map notation

```groovy
implementation group: 'org.springframework.kafka',
               name: 'spring-kafka',
               version: ''
```

### Multiline declarations

```groovy
implementation(
    'org.springframework.kafka:spring-kafka:'
)
```

Common dependency configurations such as `implementation`,
`testImplementation`, `runtimeOnly`, `compileOnly`, `annotationProcessor`,
`kapt`, `ksp`, and others are recognized.

---

## Gradle Kotlin DSL

### Standard dependency notation

```kotlin
dependencies {
    implementation("org.springframework.kafka:spring-kafka:")
}
```

Completion works independently for each coordinate:

```text
org.springframework.ka
                       → group

org.springframework.kafka:spring-
                                 → artifact

org.springframework.kafka:spring-kafka:
                                      → version
```

Common dependency configurations are supported:

```kotlin
implementation("g:a:v")
testImplementation("g:a:v")
runtimeOnly("g:a:v")
compileOnly("g:a:v")
annotationProcessor("g:a:v")
kapt("g:a:v")
ksp("g:a:v")
```

### Platform dependencies

```kotlin
implementation(platform("g:a:v"))
implementation(enforcedPlatform("g:a:v"))
```

### Multiline declarations

```kotlin
implementation(
    platform(
        "org.springframework.boot:spring-boot-dependencies:"
    )
)
```

---

## Gradle Version Catalogs

`blink-cmp-deps` supports both editing the catalog itself and consuming
generated catalog accessors from `build.gradle.kts`.

The standard catalog location is:

```text
gradle/libs.versions.toml
```

### Libraries

```toml
[libraries]

spring-kafka = "org.springframework.kafka:spring-kafka:4.0.0"

spring-web = {
    module = "org.springframework:spring-web",
    version = "7.0.0"
}
```

Library declarations support completion for:

```text
group
name
module
version
version.ref
```

Both inline and dotted declarations are supported.

For example:

```toml
spring-kafka.module = "org.springframework.kafka:spring-"
```

and:

```toml
spring-kafka = {
    module = "org.springframework.kafka:spring-kafka",
    version = ""
}
```

### Version references

```toml
[versions]

spring = "7.0.0"
kafka = "4.0.0"

[libraries]

spring-web = {
    module = "org.springframework:spring-web",
    version.ref = "spring"
}
```

`version.ref` values are completed from aliases declared under `[versions]`.

---

## Generated Catalog Accessors

Aliases from `gradle/libs.versions.toml` are exposed as Gradle Kotlin DSL
accessors.

Hyphens and underscores are converted to accessor segments.

For example:

```toml
[libraries]

spring-kafka = "org.springframework.kafka:spring-kafka:4.0.0"
```

becomes:

```kotlin
libs.spring.kafka
```

### Library accessors

```kotlin
dependencies {
    implementation(libs.spring.kafka)
}
```

Completion is hierarchical:

```text
libs.
     → spring

libs.spring.
            → kafka
```

### Version accessors

```toml
[versions]

spring-boot = "4.0.0"
spring-kafka = "4.0.0"
```

```kotlin
val version = libs.versions.spring.kafka
```

Completion:

```text
libs.versions.
              → spring

libs.versions.spring.
                     → boot
                       kafka
```

### Bundle accessors

```toml
[bundles]

spring-stack = [
    "spring-web",
    "spring-data",
]

test-utils = [
    "junit",
    "mockito",
]
```

Bundles can be used directly as dependency notation:

```kotlin
dependencies {
    implementation(libs.bundles.spring.stack)
    testImplementation(libs.bundles.test.utils)
}
```

Completion:

```text
libs.bundles.
             → spring
               test
```

### Plugin accessors

```toml
[plugins]

spring-boot = {
    id = "org.springframework.boot",
    version = "4.0.0"
}

kotlin-jvm = {
    id = "org.jetbrains.kotlin.jvm",
    version = "2.3.0"
}
```

Plugin aliases are completed inside Gradle's `alias(...)` notation:

```kotlin
plugins {
    alias(libs.plugins.spring.boot)
    alias(libs.plugins.kotlin.jvm)
}
```

Completion:

```text
alias(libs.)
           → plugins

alias(libs.plugins.)
                   → kotlin
                     spring
```

Catalog completion is context-aware:

```text
dependencies { implementation(libs.) }
    → libraries + bundles

plugins { alias(libs.) }
    → plugins
```

Version and plugin accessors are not suggested as dependency notation.

---

## How it works

```text
                                      ┌─────────────────────────┐
pom.xml ----------------------------->│ blink_deps.maven        │
                                      └───────────┬─────────────┘
                                                  │
                                      ┌───────────▼─────────────┐
build.gradle ------------------------>│ blink_deps.gradle       │
                                      └───────────┬─────────────┘
                                                  │
                                      ┌───────────▼─────────────┐
build.gradle.kts -------------------->│ blink_deps.gradle_kts   │
                                      └───────────┬─────────────┘
                                                  │
                                                  ▼
                                      blink_deps.coordinates
                                                  │
                         ┌────────────────────────┼────────────────────────┐
                         │                        │                        │
                         ▼                        ▼                        ▼
                  blink_deps.central      blink_deps.nexus       blink_deps.repository
                         │                        │                        │
                         ▼                        ▼                        ▼
                    Maven Central          Nexus Search API       Maven metadata
                                             (group/artifact)        (versions)

gradle/libs.versions.toml -----------> blink_deps.catalog
               │
               │
               └---------------------> blink_deps.gradle_catalog_accessor
                                              │
                                              ▼
                                       build.gradle.kts
                                       libs.* accessors
```

Coordinate-based sources share the same completion layer. Maven Central is
used by default, while configured repositories can contribute additional
results.

Nexus repositories use the Nexus Search API for group and artifact discovery
and the Maven repository layout for version metadata. Generic Maven repositories
use the Maven repository layout for version metadata only.

Requests are asynchronous, duplicate in-flight requests are coalesced, and
successful results are cached for the current Neovim session.

A small built-in group catalog provides useful cold-start completions while
remote results are being fetched.

Gradle catalog accessor aliases are read locally from
`gradle/libs.versions.toml` and cached until the file changes.

---

## Options

Options are passed through the Blink provider's `opts` table.

Gradle coordinate sources support:

```lua
opts = {
    debug = false,
    connect_timeout = 3,
    max_time = 7,
}
```

### Persistent cache

> [!NOTE]
> Maven Central results are cached on disk and reused across Neovim sessions.
> The cache is enabled by default with a 24-hour TTL:


```lua
opts = {
    cache = {
        enabled = true,
        ttl = 86400,
    },
}
```

Disable persistent caching with:

```lua
opts = {
    cache = {
        enabled = false,
    },
}
```

### Custom repositories

Additional repositories can be configured through the provider `opts`.

#### Generic Maven repository

For a generic Maven repository, `url` must point directly to the Maven content
root:

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

Generic Maven repositories provide version completion for known coordinates:

```kotlin
implementation("com.company.payment:payment-client:")
```

The plugin reads:

```text
https://repo.company.com/maven/releases/
└── com/company/payment/payment-client/maven-metadata.xml
```

#### Nexus Repository

Nexus repositories support group, artifact, and version completion:

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

For Nexus, `url` is the Nexus instance root and `repository` is the Nexus
repository name.

Group completion:

```kotlin
implementation("com.comp")
```

uses the Nexus Search API with a trailing-prefix query and starts after three
typed characters.

Artifact completion:

```kotlin
implementation("com.company.payment:")
```

uses the Nexus Search API with the exact group.

Version completion:

```kotlin
implementation("com.company.payment:payment-client:")
```

reads Maven metadata from the derived content root:

```text
https://nexus.company.com/repository/maven-releases/
└── com/company/payment/payment-client/maven-metadata.xml
```

Multiple configured repositories are merged with Maven Central results and
duplicate completion items are removed.


The cache is stored under Neovim's standard cache directory:

```sh
stdpath("cache")/blink-cmp-deps
~/.cache/nvim/blink-cmp-deps/
```

In-memory caching is still used during the current Neovim session, so repeated
requests do not require disk access.

The Maven source supports the same options and an optional experimental JDTLS
backend:

```lua
opts = {
    debug = false,
    connect_timeout = 3,
    max_time = 7,

    jdtls = {
        enabled = false,
        -- index_path = "/path/to/vscode-maven/extension/resources/IndexData",
    },
}
```

<details>
<summary>Experimental JDTLS backend</summary>

The Maven source can optionally use Maven search commands exposed by the
vscode-maven JDTLS extension.

This integration is disabled by default and is not required for normal Maven
Central completion.

It assumes that JDTLS already has a compatible vscode-maven extension bundle
loaded and that its `IndexData` is available.

</details>

---

## Development

Run the offline test suite with:

```bash
make test
```

The tests do not contact Maven Central.

They cover:

- Maven
- Gradle Groovy DSL
- Gradle Kotlin DSL
- Gradle Version Catalogs
- generated catalog accessors
- coordinate parsing
- query planning
- bootstrap groups
- context isolation
- shared completion helpers
- custom Maven repository version resolution
- Nexus group and artifact discovery
- Nexus version resolution
- Nexus pagination, caching, and in-flight request coalescing

---

## Roadmap

- [x] Maven completion
- [x] Gradle Groovy DSL completion
- [x] Gradle multiline dependency syntax
- [x] Gradle map notation
- [x] Gradle Kotlin DSL completion
- [x] Gradle Version Catalog editing
- [x] Gradle Version Catalog accessors
- [x] persistent cache
- [x] custom Maven repositories
- [x] Nexus repository search and version completion
- [x] improved version ranking and prerelease handling
- [ ] richer dependency metadata

---

## License

MIT
