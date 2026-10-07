-- Neovim embeds LuaJIT.
std = "luajit"

-- Tests replace functions on vim, so it is written to as well as read.
globals = { "vim" }

max_line_length = 120

ignore = {
	-- blink.cmp calls source methods as methods. A method that does not
	-- need its source still has to accept it.
	"212/self",
}
