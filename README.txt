Modular test suite for blink-cmp-deps

Copy the contents of tests/ into your repository tests/ directory.
Keep your existing tests/minimal_init.lua.

Run from the repository root:

  git diff --check
  make test

Expected result:

  blink-cmp-deps: 238 tests passed
