-- Keep this smoke limited to loading every real module.
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

end)
