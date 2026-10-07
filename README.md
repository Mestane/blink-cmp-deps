<div align="center">

# blink-cmp-deps

**Dependency completion for [`blink.cmp`](https://github.com/Saghen/blink.cmp)**

Search for libraries by name and complete dependencies in Maven, Gradle and Cargo.

[![Tests](https://github.com/Mestane/blink-cmp-deps/actions/workflows/test.yml/badge.svg)](https://github.com/Mestane/blink-cmp-deps/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

https://github.com/user-attachments/assets/ae694858-a4c8-4c54-b921-d886db63b21a

## Highlights

- **Search by name** — type `jackson-databind` and get the full coordinate
- **Every build file** — `pom.xml`, `build.gradle`, `build.gradle.kts`, version catalogs
- **Cargo too** — crate names, versions and features in `Cargo.toml`
- **Real version ranking** — `2.10.0` beats `2.9.0`, and `RC` beats `alpha`
- **Your repositories** — Maven Central, Nexus, or any Maven content root
- **Nothing to set up** — one provider, no `setup()` call, no per-file sources

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "saghen/blink.cmp",

    dependencies = { "Mestane/blink-cmp-deps" },

    opts = {
        sources = {
            default = { "lsp", "path", "snippets", "buffer", "deps" },

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

That's the whole setup. The plugin detects the current file and routes
completion internally.

**Requires** Neovim 0.10 or newer, `blink.cmp` and `curl`. JDTLS is *not*
required. Verify with `:checkhealth blink_deps`.

## Searching for a dependency

When you know the library but not the coordinate, type what you remember:

```kotlin
implementation("jackson-databind")
implementation("spring data jpa")
```

```text
com.fasterxml.jackson.core:jackson-databind    2.20
tools.jackson.core:jackson-databind            3.0
```

Accepting a result inserts `groupId:artifactId:` and version completion takes
over from there.

Your local `~/.m2` repository is searched first and ranked above everything
else, because a library already on disk is one you have actually used. Maven
Central is searched too: exactly by artifact id, or by all of your words when
the search contains spaces.

In `pom.xml` the coordinate lives in two elements, so accepting a result fills
both at once:

```xml
<dependency>
    <groupId>jackson-databind</groupId>     <!-- search here -->
    <artifactId></artifactId>               <!-- filled for you -->
</dependency>
```

This needs the `<artifactId>` line to already be there. Without it, `<groupId>`
falls back to ordinary group completion.

> A single common word like `spring` has no good answer from Maven Central's
> search API, so those results come mostly from your local repository.

## Completing coordinates

Type a reverse-domain group and completion walks you through the coordinate,
one segment at a time.

<details>
<summary><b>Maven</b> — <code>pom.xml</code></summary>

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
    <version></version>
</dependency>
```

Also completes scopes, packaging, classifiers, dependency types, lifecycle
phases and repository policies.

</details>

<details>
<summary><b>Gradle Groovy DSL</b> — <code>build.gradle</code></summary>

String, function, platform, map and multiline notation all work:

```groovy
implementation "org.springframework.kafka:spring-kafka:"

implementation("org.springframework.kafka:spring-kafka:")

implementation platform("org.springframework.boot:spring-boot-dependencies:")

implementation group: "org.springframework.kafka",
               name: "spring-kafka",
               version: ""
```

</details>

<details>
<summary><b>Gradle Kotlin DSL</b> — <code>build.gradle.kts</code></summary>

```kotlin
implementation("org.springframework.kafka:spring-kafka:")

implementation(platform("org.springframework.boot:spring-boot-dependencies:"))
implementation(enforcedPlatform("org.springframework.boot:spring-boot-dependencies:"))
```

The same source also completes version catalog accessors from
`gradle/libs.versions.toml`:

```kotlin
implementation(libs.spring.kafka)
implementation(libs.bundles.spring.stack)

val version = libs.versions.spring.kafka
```

```kotlin
plugins {
    alias(libs.plugins.spring.boot)
}
```

Accessor completion is context aware, so dependency, bundle, version and plugin
namespaces are only suggested where they belong.

</details>

<details>
<summary><b>Gradle Version Catalog</b> — <code>*.versions.toml</code></summary>

```toml
[versions]
spring = "7.0.0"

[libraries]
spring-kafka = "org.springframework.kafka:spring-kafka:"
spring-web = { module = "org.springframework:spring-web", version.ref = "spring" }
```

Completes `module`, `group`, `name`, `version` and `version.ref` in inline,
shorthand and dotted declarations. Aliases become `libs.spring.kafka` in Kotlin
DSL.

</details>

## Cargo

In `Cargo.toml` the plugin completes three things.

**Crate names.** Type the beginning of a name in a dependency table:

```toml
[dependencies]
tok
```

```text
tokio           1.53.2
tokio-util      0.7.16
tokio-stream    0.1.17
```

Accepting a crate on a line of its own writes the whole dependency,
`tokio = "1.53.2"`. Where there is already something after the name, only the
name is replaced. Results are ordered by downloads, with a crate named exactly
what you typed first.

**Versions.** Inside a requirement, in any of the ways Cargo lets you write one:

```toml
serde = ""
serde = { version = "", features = ["derive"] }

[dependencies.serde]
version = ""
```

Releases are listed newest first. Prereleases follow, labelled as such, and
yanked releases are left out. Operators are kept: in `">=1.2, <2"` only the
version being typed is replaced. A renamed dependency,
`json = { package = "serde_json", version = "" }`, completes the versions of the
real package.

**Features.** Inside a `features` array, on one line or spread over several.
Features already listed are not offered again.

All dependency tables are recognised: `dependencies`, `dev-dependencies`,
`build-dependencies`, `[workspace.dependencies]` and per-target tables such as
`[target.'cfg(unix)'.dependencies]`.

Crates are searched through the crates.io API and versions are read from the
crates.io sparse index, the same one `cargo` uses.

Crates you have already built against are also read from cargo's own files
under `~/.cargo`. Their versions and features appear at once and work offline,
and when you search by name they are listed above crates you have never used.
`CARGO_HOME` is honoured.

Each source can be pointed elsewhere, or switched off:

```lua
opts = {
    crates_io = {
        enabled = true,
        api_url = "https://crates.io",
        index_url = "https://index.crates.io",
    },
    cargo_home = {
        enabled = true,
        path = "~/.cargo",
    },
}
```

## Configuration

Everything goes in the provider's `opts` table:

```lua
deps = {
    name = "Dependencies",
    module = "blink_deps",
    async = true,

    opts = {
        debug = false,
    },
},
```

The defaults are meant to be good. Reach for these only when you need them.

<details>
<summary><b>Choosing sources</b></summary>

All sources are on by default. To narrow them:

```lua
opts = {
    enabled_sources = { "maven", "gradle_kts" },
}
```

| Name | Enables |
| --- | --- |
| `maven` | `pom.xml` |
| `gradle` | `build.gradle` |
| `gradle_kts` | `build.gradle.kts` coordinates **and `libs.*` accessors** |
| `version_catalog` | `*.versions.toml` |
| `cargo` | `Cargo.toml` |

An empty list disables all of them.

</details>

<details>
<summary><b>Local repository search</b></summary>

```lua
opts = {
    local_repository = {
        enabled = true,
        path = "~/.m2/repository",
    },
}
```

Scanned once per session by listing `.pom` files and reading the coordinate out
of the directory layout. Nothing is parsed and nothing is written to disk: a
1.4 GB repository with 770 coordinates scans in about half a second, and only
on the first search.

</details>

<details>
<summary><b>Network timing</b></summary>

```lua
opts = {
    connect_timeout = 3,
    max_time = 3,
    debounce_ms = 250,
    discovery_debounce_ms = 400,
    retries = 1,
}
```

`debounce_ms` is how long completion waits after your last keystroke before
going to the network. Blink asks for completions on every keystroke, so without
a delay every half-typed prefix would become a request. Cached and already
discovered results always appear immediately, whatever this is set to.

`discovery_debounce_ms` is the same delay for search, which waits a little
longer because a half-typed search term is never a useful query. Setting
`debounce_ms` alone lowers both.

`max_time` is deliberately short. A healthy Maven Central request answers in
well under a second, and one that has not answered in three seconds will not
answer in seven either, so failing fast and retrying beats waiting. `retries`
covers transport failures only; a rejected query is never retried.

Both timeouts apply to every backend, but Nexus and generic Maven repositories
keep a longer default of 7 seconds since they often sit on slower internal
networks.

</details>

<details>
<summary><b>Nexus repositories</b></summary>

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

Nexus provides group, artifact and version completion. `url` is the instance
root and `repository` is the repository name. Group search starts after three
characters. Results merge with Maven Central and are deduplicated.

</details>

<details>
<summary><b>Generic Maven repositories</b></summary>

Any Maven content root can contribute **version completion for coordinates you
already have**:

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

For `com.company.payment:payment-client` the plugin reads
`com/company/payment/payment-client/maven-metadata.xml` under that root.
Generic repositories do not offer group or artifact discovery.

</details>

<details>
<summary><b>Disabling Maven Central</b></summary>

```lua
opts = {
    central = { enabled = false },
}
```

No requests are made and no Maven Central cache entries are read. Configured
repositories keep working normally.

</details>

<details>
<summary><b>Persistent cache</b></summary>

On by default, living under `stdpath("cache")/blink-cmp-deps`:

```lua
opts = {
    cache = {
        enabled = true,
        ttl = 86400,
    },
}
```

Disabling it leaves in-memory caching for the current session intact.

</details>

<details>
<summary><b>JDTLS-backed Maven search</b></summary>

The Maven source can optionally use search commands from a compatible JDTLS /
vscode-maven setup:

```lua
opts = {
    jdtls = {
        enabled = true,
        -- index_path = "/path/to/vscode-maven/extension/resources/IndexData",
    },
}
```

Off by default and not needed for normal Maven Central completion.

</details>

## How it works

```text
                        blink_deps
                            │
        ┌───────────────────┼───────────────────┐
     pom.xml           build.gradle      build.gradle.kts
        │                   │                   │
      Maven              Gradle          Gradle Kotlin DSL
                                                │
                                        libs.* accessors

  *.versions.toml  ──►  Version Catalog


              blink_deps.coordinates
                        │
      ┌─────────┬───────┴───────┬──────────────┐
   Central    Nexus     Maven repositories    ~/.m2
```

Every coordinate source shares one completion layer, so caching, ranking,
cancellation and request coalescing behave the same everywhere. Version catalog
accessors are read locally from `gradle/libs.versions.toml`.

## Development

```bash
make test              # every spec
SPEC=maven make test   # only specs whose file name contains "maven"
make lint              # luacheck, and a check for debug output left behind
make check             # lint, then test
```

The suite runs offline and never contacts Maven Central or Nexus, and never
reads your own `~/.m2`. It covers provider routing, every build file syntax,
version ranking, caching, custom repositories, Nexus search and pagination,
dependency search and local repository matching, request deduplication and
cancellation.

Each spec runs in isolation and every failure is reported, not only the first.
`make lint` needs [luacheck](https://github.com/lunarmodules/luacheck).

CI runs the suite on Neovim 0.10, 0.11, stable and nightly. Nightly is allowed
to fail, so an upstream regression is visible without blocking a pull request.

Internally the unified provider delegates to `blink_deps.maven`,
`blink_deps.gradle`, `blink_deps.gradle_kts`, `blink_deps.catalog` and
`blink_deps.gradle_catalog_accessor`. They stay separate so each syntax owns its
parser, while users configure a single Blink source.

Which files are handled, and by which of those modules, is declared in
`blink_deps.manifests`. Supporting another file means registering an entry
there; the unified provider itself does not change.

## Roadmap

- [x] Maven, Gradle Groovy DSL and Gradle Kotlin DSL completion
- [x] Gradle Version Catalog editing and `libs.*` accessors
- [x] Semantic version ranking
- [x] Persistent cache
- [x] Nexus and generic Maven repositories
- [x] Dependency search by name
- [ ] Repository authentication
- [ ] Richer dependency metadata

## License

MIT
