# blink-cmp-deps

Dependency completion for [`blink.cmp`](https://github.com/Saghen/blink.cmp).

The first source targets Maven `pom.xml` files and provides completion for:

- `groupId`
- `artifactId`
- `version`
- Maven scopes, packaging, lifecycle phases, classifiers, and other common static values

Maven Central is the default backend. A small cold-start group catalog makes common group completions immediately available while asynchronous Maven Central requests populate the session cache.

> Current release: `0.1.0`. Maven completion is available; Gradle support is planned.

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

Then register the Maven source in your `blink.cmp` configuration:

```lua
sources = {
    per_filetype = {
        xml = {
            inherit_defaults = true,
            "maven",
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
    },
}
```

No `require("blink_deps").setup()` call is needed. Source-specific configuration is passed through Blink's provider `opts` table.

## Examples

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

## How it works

```text
pom.xml
   │
   ▼
blink.cmp
   │
   ▼
blink_deps.maven
   │
   ├── cold-start group hints
   │
   └── Maven Central
          ├── group search
          ├── artifact search
          └── version search
```

Requests are asynchronous, duplicate in-flight requests are coalesced, and successful results are cached for the current Neovim session.

## Options

Options belong under the Blink provider's `opts` table:

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

### Experimental JDTLS backend

The Maven source contains an optional integration for the Maven search commands exposed by the vscode-maven JDTLS extension. It is disabled by default and is **not** needed for normal Maven Central completion.

Enabling it assumes that your JDTLS process already has a compatible vscode-maven extension bundle loaded and that its `IndexData` is available. This is an advanced/experimental backend, not a normal installation requirement.

## Development

Run the offline unit/smoke tests with:

```bash
make test
```

The tests intentionally do not contact Maven Central. They protect the query shapes, source defaults, bootstrap groups, and shared result helpers that completion relies on.

For a manual live regression test in a `pom.xml`, verify all four cases:

```text
groupId:           spring
qualified groupId: org.springframework.ka
artifactId:        spring-
version:           org.springframework.kafka:spring-kafka
```

## Roadmap

- [x] Maven `groupId` completion
- [x] Maven `artifactId` completion
- [x] Maven version completion
- [x] Maven Central backend
- [x] async streaming and session caches
- [x] optional JDTLS backend
- [x] shared Central/util modules
- [x] offline tests and CI
- [ ] Gradle Groovy DSL source
- [ ] Gradle Kotlin DSL source
- [ ] persistent cache

## License

MIT
