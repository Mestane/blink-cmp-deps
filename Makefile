.PHONY: test lint check

# SPEC=<part of a spec file name> runs only the matching specs.
test:
	@nvim --headless -u tests/minimal_init.lua \
		-c "lua local ok, err = pcall(dofile, 'tests/run.lua'); if not ok then io.stderr:write(tostring(err) .. '\n'); vim.cmd('cquit 1') end" \
		-c "qa!"

# Static analysis, then a guard against debug output left in the plugin.
# Tests may print; the plugin itself reports through vim.notify only.
lint:
	@luacheck --quiet lua tests
	@if grep -rnE '(^|[^[:alnum:]_.])(print|vim\.print|vim\.pretty_print)\(' lua; then \
		echo "debug output left in lua/"; \
		exit 1; \
	fi

check: lint test
