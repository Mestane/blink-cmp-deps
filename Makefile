.PHONY: test

test:
	nvim --headless -u tests/minimal_init.lua \
		-c "lua local ok, err = pcall(dofile, 'tests/run.lua'); if not ok then vim.api.nvim_err_writeln(err); vim.cmd('cquit 1') end" \
		-c "qa!"
