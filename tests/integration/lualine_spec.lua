local state = require("opencode.state")

describe("lualine status component", function()
	local lualine, saved_module, original_cwd, original_directory_scope, temporary_directory
	local highlight_names = { "OpenCodeLualineAttention", "OpenCodeLualineDiffAdd", "OpenCodeLualineDiffDelete" }
	local highlights

	before_each(function()
		state.reset()
		original_cwd = vim.fn.getcwd()
		original_directory_scope = vim.fn.haslocaldir()
		temporary_directory = nil
		highlights = {}
		for _, name in ipairs(highlight_names) do
			highlights[name] = vim.api.nvim_get_hl(0, { name = name, link = false })
		end
		saved_module = package.loaded["opencode.components.lualine"]
		package.loaded["opencode.components.lualine"] = nil
		lualine = require("opencode.components.lualine")
	end)

	after_each(function()
		local directory_command = ({ [0] = "cd", [1] = "lcd", [2] = "tcd" })[original_directory_scope]
		vim.cmd(directory_command .. " " .. vim.fn.fnameescape(original_cwd))
		if temporary_directory then vim.fn.delete(temporary_directory, "rf") end
		pcall(vim.api.nvim_del_augroup_by_name, "OpenCodeLualine")
		for name, value in pairs(highlights) do vim.api.nvim_set_hl(0, name, value) end
		package.loaded["opencode.components.lualine"] = saved_module
		state.reset()
	end)

	it("shows pending attention without status text through the public component", function()
		lualine.setup({ show_attention = true, attention_icon = "◈", show_diff_stats = false })
		state.set_session("attention-session", "Attention session")
		state.set_session_pending_counts("attention-session", { questions = 1 })
		local component = require("opencode").lualine_component()
		assert.is_string(component)
		assert.is_truthy(component:find("◈1", 1, true))
		assert.is_nil(component:find("idle", 1, true))
	end)

	it("counts an untracked file in a real git repository and highlights both totals", function()
		assert.equals(1, vim.fn.executable("git"), "git is required for this integration test")
		temporary_directory = vim.fn.tempname()
		vim.fn.mkdir(temporary_directory, "p")
		vim.fn.system({ "git", "-C", temporary_directory, "init" })
		assert.equals(0, vim.v.shell_error, "temporary git repository must initialize")
		vim.fn.writefile({ "one", "two", "three" }, temporary_directory .. "/new.txt")
		vim.cmd("lcd " .. vim.fn.fnameescape(temporary_directory))
		lualine.setup({
			show_attention = false,
			show_diff_stats = true,
			diff_stats_cache_ms = 0,
			diff_stats_include_untracked = true,
		})
		assert.equals("%#OpenCodeLualineDiffAdd#+3%#OpenCodeLualineDiffDelete# -0%*", lualine.component())
	end)
end)
