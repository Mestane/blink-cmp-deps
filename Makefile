.PHONY: test

# SPEC=<part of a spec file name> runs only the matching specs.
test:
	@nvim --headless -u tests/minimal_init.lua \
		-c "lua local ok, err = pcall(dofile, 'tests/run.lua'); if not ok then io.stderr:write(tostring(err) .. '\n'); vim.cmd('cquit 1') end" \
		-c "qa!"
