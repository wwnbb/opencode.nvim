-- Keep this smoke limited to loading real modules and the public setup contract.
describe("opencode.nvim module loading", function()
	it("loads every module with the installed Neovim dependencies", function()
		local files = vim.fn.glob("lua/opencode/**/*.lua", false, true)
		assert.is_true(#files > 0)
		table.sort(files)
		for _, path in ipairs(files) do
			local name = path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/", "."):gsub("%.init$", "")
			local ok, result = pcall(require, name)
			assert.is_true(ok, name .. ": " .. tostring(result))
		end
	end)

	it("sets up without starting a server and exposes the public entry points", function()
		local opencode = require("opencode")
		opencode.setup({ server = { auto_start = false }, lualine = { enabled = true } })
		for _, name in ipairs({
			"open_input_at_end", "add_current_line", "add_current_line_and_open_input",
			"add_visual_selection", "add_visual_selection_and_open_input", "active_sessions",
			"toggle_danger_mode", "new_session", "close_session", "is_danger_mode_enabled",
		}) do
			assert.is_function(opencode[name], name .. " is not exported")
		end
	end)
end)
