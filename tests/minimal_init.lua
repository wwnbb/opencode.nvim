local source = debug.getinfo(1, "S").source:gsub("^@", "")
local tests_dir = vim.fn.fnamemodify(source, ":p:h")
local plugin_root = vim.fn.fnamemodify(tests_dir, ":h")

vim.opt.runtimepath:append(plugin_root)

local function append_runtime_path(path)
	if type(path) == "string" and path ~= "" and vim.fn.isdirectory(path) == 1 then
		vim.opt.runtimepath:append(path)
	end
end

append_runtime_path(vim.env.PLENARY_PATH or (plugin_root .. "/.deps/nvim/plenary.nvim"))
append_runtime_path(vim.env.NUI_PATH or (plugin_root .. "/.deps/nvim/nui.nvim"))

vim.cmd("runtime plugin/plenary.vim")
