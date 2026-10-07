# Changelog

Notable changes to blink-cmp-deps. Versions follow [semantic versioning](https://semver.org).

## 0.6.0 — 2026-10-07

The plugin now covers five ecosystems and can tell you which of your
dependencies have known vulnerabilities. Existing Maven and Gradle
configurations keep working unchanged.

### Added

- **Cargo.** Crate names, version requirements and features in `Cargo.toml`, in
  every spelling Cargo accepts, from crates.io.
- **npm.** Package names and version ranges in `package.json`, including
  overrides, yarn resolutions, pnpm overrides and `npm:` aliases.
- **Python.** Project names and versions in requirements files and in
  `pyproject.toml`: PEP 508 strings in every standard section, and Poetry
  tables. Versions are ordered by PEP 440.
- **Offline completion.** Versions, artifacts and searches are answered from
  `~/.m2`, crates from the cargo cache, and npm packages from the project's
  lockfile. Results from disk appear at once and rank above packages you have
  never used.
- **Known vulnerabilities**, opt-in with `security = { enabled = true }`.
  Affected versions are marked during completion, a version's documentation
  lists what affects it, and the versions already written in a file are checked
  when it is opened or saved and shown as diagnostics. `:DepsAudit` checks on
  demand. Data comes from [OSV](https://osv.dev).
- **`:checkhealth blink_deps`** reports what the plugin makes of the current
  file, which registries it would ask, and how the cache is performing.
- **`require("blink_deps").setup(opts)`**, optional, to create the source at
  startup instead of when blink first needs it.
- Options `crates_io`, `cargo_home`, `npm`, `npm_project`, `pypi`, `pypi_top`
  and `security`. `enabled_sources` accepts `cargo`, `npm`, `requirements` and
  `pyproject`.

### Changed

- Requests identify the plugin with a contact URL in the User-Agent, which
  crates.io requires.

### Fixed

- **Credentials in repository URLs were displayed.** A repository configured
  without a `name` was shown by its URL, credentials included, in the completion
  menu and in failure notifications. Such names are now redacted.
- `pom.xml`: a plugin without a `groupId` took the group of a dependency nested
  inside it; a commented-out `<dependency>` confused the cursor context;
  exclusions leaked into the enclosing dependency; a `<version>` inside
  `<configuration>` was treated as the plugin's version; elements after the
  cursor were not read.
- The local repository scan discarded everything it had found when a single
  directory was unreadable.

### Internal

- One HTTP transport and one cache pipeline shared by every backend, with
  structured errors, retries limited to transport failures, cancellation and
  request coalescing.
- A registry contract that every source of package information implements,
  remote or on disk, and ecosystem-neutral name and version completion built on
  it.
- The test suite grew from 359 to over 2,400 assertions, runs each spec in
  isolation, and is exercised in CI on Neovim 0.10, 0.11, stable and nightly
  together with a lint job.

## 0.5.0

Maven, Gradle Groovy and Kotlin DSL, and Gradle Version Catalog completion from
Maven Central, Nexus and generic Maven repositories, with dependency search by
name and a persistent cache.
