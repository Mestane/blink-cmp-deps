local source = debug.getinfo(1, "S").source:sub(2)
local tests_dir = vim.fn.fnamemodify(source, ":p:h")
local root = vim.fn.fnamemodify(tests_dir, ":h")

vim.opt.runtimepath:prepend(root)
