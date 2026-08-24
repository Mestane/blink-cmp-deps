# blink-deps.nvim

Dependency completion sources for [blink.cmp](https://github.com/Saghen/blink.cmp).

The first backend is Maven (`pom.xml`). It provides completion for:

- `groupId`
- `artifactId`
- `version`
- common Maven static values such as scopes and packaging

Results are sourced from Maven Central, with a small cold-start group catalog and optional JDTLS/vscode-maven index integration when available.

> Status: early development. The Maven source is currently the proven baseline that was extracted from an existing Neovim configuration. The public API may still change before `v0.1.0`.

## Requirements

- Neovim with `vim.system` support
- [blink.cmp](https://github.com/Saghen/blink.cmp)
- `curl`
- Internet access for Maven Central results

JDTLS is optional. Maven Central completion works without it.

## Installation

### lazy.nvim

```lua
{
    "yourname/blink-deps.nvim",
    dependencies = {
        "saghen/blink.cmp",
    },
}
```

## blink.cmp configuration

Add the Maven source to `sources.per_filetype.xml` and register the provider:

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

## Examples

### Group

```xml
<groupId>org.spring</groupId>
```

Possible results include:

```text
org.springframework
org.springframework.boot
org.springframework.data
org.springframework.kafka
org.springframework.security
```

### Artifact

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-</artifactId>
</dependency>
```

### Version

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
    <version></version>
</dependency>
```

## Optional JDTLS Maven index

The current Maven source can also use the vscode-maven/JDTLS artifact index when the required JDTLS commands and `IndexData` are available. This is an optional acceleration/fallback layer; Maven Central remains available independently.

This integration will be generalized before the first stable release so it does not assume a particular local vscode-maven installation layout.

## Roadmap

- [x] Maven groupId completion
- [x] Maven artifactId completion
- [x] Maven version completion
- [x] Maven Central backend
- [x] async streaming and in-session caches
- [ ] extract shared Maven Central backend
- [ ] make JDTLS integration fully optional/configurable
- [ ] tests
- [ ] Gradle Groovy DSL source
- [ ] persistent cache

## Development

Quick smoke test inside Neovim:

```vim
:lua print(vim.inspect(require("blink_deps.maven").self_test()))
```

## License

MIT
