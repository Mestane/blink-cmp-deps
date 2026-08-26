# blink-cmp-deps

Dependency completion for [`blink.cmp`](https://github.com/Saghen/blink.cmp).

https://github.com/user-attachments/assets/ae694858-a4c8-4c54-b921-d886db63b21a

Currently supports:

- Maven `pom.xml`
  - `groupId`
  - `artifactId`
  - versions
  - scopes and other common POM values
- Gradle Groovy DSL `build.gradle`
  - group completion
  - artifact completion
  - version completion
  - common dependency configurations
  - `platform(...)` and `enforcedPlatform(...)`

Maven Central is the default dependency backend.

A small cold-start group catalog makes common group completions immediately available while asynchronous Maven Central requests populate the session cache.

## Requirements

- Neovim with `vim.system`
- [`blink.cmp`](https://github.com/Saghen/blink.cmp)
- `curl`
- Internet access for live Maven Central results

JDTLS is **not required**.

Run this after installation to verify the local requirements:

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

Then register the Maven and Gradle sources in your `blink.cmp` configuration:

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
    },
}
```

No `require("blink_deps").setup()` call is needed. Source-specific configuration is passed through Blink's provider `opts` table.

## Maven

### Group completion

```xml
<groupId>org.spring</groupId>
```

Possible candidates include:

```text
org.springframework
org.springframework.boot
org.springframework.data
org.springframework.kafka
org.springframework.security
```

Qualified searches are supported as well:

```xml
<groupId>org.springframework.ka</groupId>
```

### Artifact completion

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-</artifactId>
</dependency>
```

### Version completion

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
    <version></version>
</dependency>
```

### Static Maven values

The Maven source also provides completion for common POM values such as:

- dependency scopes
- packaging
- lifecycle phases
- classifiers
- dependency types
- `optional`
- plugin `extensions`
- plugin `inherited`
- repository update/checksum policies
- repository layout

## Gradle Groovy DSL

### Group completion

```groovy
dependencies {
    implementation 'org.spring'
}
```

### Artifact completion

```groovy
dependencies {
    implementation 'org.springframework.kafka:spring-'
}
```

### Version completion

```groovy
dependencies {
    implementation 'org.springframework.kafka:spring-kafka:'
}
```

### Supported dependency forms

```groovy
implementation 'g:a:v'
implementation "g:a:v"

implementation('g:a:v')
implementation("g:a:v")

testImplementation 'g:a:v'
runtimeOnly 'g:a:v'
compileOnly 'g:a:v'
annotationProcessor 'g:a:v'

implementation platform('g:a:v')
implementation(platform('g:a:v'))

implementation enforcedPlatform('g:a:v')
implementation(enforcedPlatform('g:a:v'))
```

The Gradle source supports string notation, multiline declarations, and map notation in `build.gradle`.

## How it works

```text
pom.xml -----------------> blink_deps.maven ----┐
                                                │
build.gradle ------------> blink_deps.gradle ---┤
                                                │
                                                ▼
                                      blink_deps.coordinates
                                                │
                                                ▼
                                        blink_deps.central
                                                │
                                                ▼
                                           Maven Central
                                      ├── group search
                                      ├── artifact search
                                      └── version search
```

The Maven and Gradle sources share the same coordinate completion layer and Maven Central backend.

Requests are asynchronous, duplicate in-flight requests are coalesced, and successful results are cached for the current Neovim session.

## Options

Options belong under the Blink provider's `opts` table.

### Maven

```lua
maven = {
    name = "Maven",
    module = "blink_deps.maven",
    async = true,

    opts = {
        debug = false,
        connect_timeout = 3,
        max_time = 7,

        -- Experimental. Disabled by default.
        jdtls = {
            enabled = false,
            -- index_path = "/path/to/vscode-maven/extension/resources/IndexData",
        },
    },
}
```

### Gradle

```lua
gradle = {
    name = "Gradle",
    module = "blink_deps.gradle",
    async = true,

    opts = {
        debug = false,
        connect_timeout = 3,
        max_time = 7,
    },
}
```

### Experimental JDTLS backend

The Maven source contains an optional integration for the Maven search commands exposed by the vscode-maven JDTLS extension. It is disabled by default and is **not** needed for normal Maven Central completion.

Enabling it assumes that your JDTLS process already has a compatible vscode-maven extension bundle loaded and that its `IndexData` is available. This is an advanced/experimental backend, not a normal installation requirement.

## Development

Run the offline unit/smoke tests with:

```bash
make test
```

The tests intentionally do not contact Maven Central. They protect:

- Maven and Gradle source defaults
- Maven Central query shapes
- bootstrap groups
- artifact and version query planning
- shared coordinate helpers
- shared result helpers

For manual live regression testing, verify these cases.

### Maven

```text
groupId:           spring
qualified groupId: org.springframework.ka
artifactId:        spring-
version:           org.springframework.kafka:spring-kafka
```

### Gradle

```text
group:             spring
qualified group:   org.springframework.ka
artifact:          org.springframework.kafka:spring-
version:           org.springframework.kafka:spring-kafka:
```

## Roadmap

- [x] Maven `groupId` completion
- [x] Maven `artifactId` completion
- [x] Maven version completion
- [x] Maven Central backend
- [x] async streaming and session caches
- [x] optional JDTLS backend
- [x] shared Central/util modules
- [x] shared Maven/Gradle coordinate completion
- [x] offline tests and CI
- [x] Gradle Groovy DSL source
- [x] Gradle multiline dependency syntax
- [x] Gradle map notation
- [ ] Gradle Kotlin DSL source
- [ ] persistent cache

## License

MIT
