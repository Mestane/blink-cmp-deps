local root = vim.fn.getcwd()

vim.opt.runtimepath:prepend(root)

package.path = table.concat({
	root .. "/lua/?.lua",
	root .. "/lua/?/init.lua",
	package.path,
}, ";")
