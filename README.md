# blink-cmp-deps

Dependency completion for [`blink.cmp`](https://github.com/Saghen/blink.cmp).

https://github.com/user-attachments/assets/ae694858-a4c8-4c54-b921-d886db63b21a

Supports dependency completion for:

- Maven — `pom.xml`
- Gradle Groovy DSL — `build.gradle`
- Gradle Kotlin DSL — `build.gradle.kts`

Group, artifact, and version results are resolved through Maven Central.

## Requirements

- Neovim with `vim.system`
- [`blink.cmp`](https://github.com/Saghen/blink.cmp)
- `curl`
- Internet access for live Maven Central results

JDTLS is **not required**.

After installation:

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
    },
}
```

No `require("blink_deps").setup()` call is needed.

## Maven

### Coordinates

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
    <version>3.</version>
</dependency>
```

Completion is available for:

```text
groupId     → org.springframework.kafka
artifactId  → spring-kafka
version     → matching versions
```

The Maven source also completes common POM values such as dependency scopes,
packaging, classifiers, dependency types, lifecycle phases, repository policies,
and several boolean/plugin fields.

## Gradle Groovy DSL

String notation:

```groovy
dependencies {
    implementation 'org.springframework.kafka:spring-kafka:'
}
```

Function notation:

```groovy
implementation('org.springframework.kafka:spring-kafka:')
```

Platform dependencies:

```groovy
implementation platform('org.springframework.boot:spring-boot-dependencies:')
implementation(platform('org.springframework.boot:spring-boot-dependencies:'))

implementation enforcedPlatform('g:a:v')
implementation(enforcedPlatform('g:a:v'))
```

Map notation:

```groovy
implementation group: 'org.springframework.kafka',
               name: 'spring-kafka',
               version: ''
```

Multiline declarations are supported as well:

```groovy
implementation(
    'org.springframework.kafka:spring-kafka:'
)
```

Common configurations such as `implementation`, `testImplementation`,
`runtimeOnly`, `compileOnly`, `annotationProcessor`, `kapt`, `ksp`, and others
are recognized.

## Gradle Kotlin DSL

Standard dependency notation:

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

Platform dependencies:

```kotlin
implementation(platform("g:a:v"))
implementation(enforcedPlatform("g:a:v"))
```

Multiline declarations are also supported:

```kotlin
implementation(
    platform(
        "org.springframework.boot:spring-boot-dependencies:"
    )
)
```

## How it works

```text
pom.xml -----------> blink_deps.maven ------┐
                                             │
build.gradle ------> blink_deps.gradle -----┤
                                             ├──> blink_deps.coordinates
build.gradle.kts --> blink_deps.gradle_kts -┘              │
                                                            ▼
                                                   blink_deps.central
                                                            │
                                                            ▼
                                                       Maven Central
```

All sources share the same coordinate completion layer and Maven Central
backend.

Requests are asynchronous, duplicate in-flight requests are coalesced, and
successful results are cached for the current Neovim session.

A small built-in group catalog provides useful cold-start completions while
Maven Central results are being fetched.

## Options

Options are passed through the Blink provider's `opts` table.

Gradle sources support:

```lua
opts = {
    debug = false,
    connect_timeout = 3,
    max_time = 7,
}
```

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

## Development

Run the offline test suite with:

```bash
make test
```

The tests do not contact Maven Central.

They cover Maven, Gradle Groovy DSL, Gradle Kotlin DSL, coordinate parsing,
query planning, bootstrap groups, and shared completion helpers.

## Roadmap

- [x] Maven completion
- [x] Gradle Groovy DSL completion
- [x] Gradle multiline dependency syntax
- [x] Gradle map notation
- [x] Gradle Kotlin DSL completion
- [ ] Gradle Version Catalogs (`libs.versions.toml`)
- [ ] persistent cache
- [ ] custom Maven repositories
- [ ] improved version ranking and prerelease handling
- [ ] richer dependency metadata

## License

MIT
