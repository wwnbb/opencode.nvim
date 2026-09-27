-- Fail loudly when a missing runtime would turn work-count coverage into skips
-- or fallback-only tests. This is run under the same isolated minimal_init.
assert(jit and type(jit.version) == "string", "Hot-path tests require LuaJIT")
require("plenary.busted")
require("nui.line")
print("Neovim: " .. vim.inspect(vim.version()))
print("LuaJIT: " .. jit.version)
print("Runtime: " .. tostring(vim.env.VIMRUNTIME))

local syntax = require("opencode.ui.syntax")
for _, language in ipairs({ "lua", "markdown", "markdown_inline" }) do
	vim.treesitter.language.add(language)
	local source = language == "lua" and "local value = 1\nreturn value" or "**bold** and [link](target)"
	local parser = vim.treesitter.get_string_parser(source, language)
	assert(parser:parse()[1], "Missing usable parser: " .. language)
	local query = vim.treesitter.query.get(language, "highlights")
	assert(query, "Missing highlight query: " .. language)
	if language == "lua" then
		assert(syntax.query_cache_signature(query), "Unsupported built-in Lua query metadata/handlers")
	end
	print(language .. " parser paths: " .. vim.inspect(vim.api.nvim_get_runtime_file("parser/" .. language .. ".*", true)))
	print(language .. " query paths: " .. vim.inspect(vim.treesitter.query.get_files(language, "highlights")))
end

for _, language in ipairs({ "markdown", "markdown_inline" }) do
	local paths = vim.api.nvim_get_runtime_file("lua/opencode/ui/markdown/queries/" .. language .. ".scm", false)
	assert(paths[1], "Missing vendored query: " .. language)
	local query = vim.treesitter.query.parse(language, table.concat(vim.fn.readfile(paths[1]), "\n"))
	assert(syntax.query_cache_signature(query), "Unsupported vendored query metadata/handlers: " .. language)
end
print("Hot-path runtime preflight passed")
