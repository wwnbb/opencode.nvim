local context = require("opencode.explanation.context")
local config = require("opencode.config")

describe("selection explanation context", function()
	local buffers, original_buf
	local root = "/tmp/opencode-explanation-context"
	local function buffer(path, lines)
		local bufnr = vim.api.nvim_create_buf(true, false)
		buffers[#buffers + 1] = bufnr
		vim.api.nvim_buf_set_name(bufnr, path)
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		return bufnr
	end
	local function snapshot(bufnr, first, selected, mode)
		return { bufnr = bufnr, path = vim.api.nvim_buf_get_name(bufnr), root = root,
			filetype = "lua", mode = mode or "V", start_line = first,
			end_line = first + #selected - 1, lines = selected, text = table.concat(selected, "\n") }
	end
	local function decoded(prompt)
		return vim.json.decode(prompt:match("Context %(JSON%):\n(.*)$"))
	end
	before_each(function() buffers = {}; original_buf = vim.api.nvim_get_current_buf() end)
	after_each(function()
		vim.api.nvim_set_current_buf(original_buf)
		for _, bufnr in ipairs(buffers) do vim.api.nvim_buf_delete(bufnr, { force = true }) end
	end)

	it("prioritizes the entire unsaved selection and adds exact source line numbers", function()
		local bufnr = buffer(root .. "/main.lua", { "-- header", "local before = 1", "local a = 'é'", "return a", "after()" })
		buffer(root .. "/sibling.lua", { "return { unsaved = true }" })
		local opts = config.merge({ explanation = { language = "ru" } }).explanation
		local prompt = assert(context.build(snapshot(bufnr, 3, { "local a = 'é'", "return a" }), opts))
		local data = decoded(prompt)
		assert.is_truthy(prompt:find("Объясни только выделенный исходный код по-русски", 1, true))
		assert.is_truthy(prompt:find("<answer>", 1, true))
		assert.same({ { line = 3, text = "local a = 'é'" }, { line = 4, text = "return a" } }, data.selection)
		assert.same({ "-- header", "local before = 1" }, data.before)
		assert.same({ "after()" }, data.after)
		assert.equals("sibling.lua", data.related[1].path)
		assert.same({ "return { unsaved = true }" }, data.related[1].lines)
	end)

	it("uses the byte budget for optional context and never truncates selected UTF-8", function()
		local selected = string.rep("é", 500)
		local bufnr = buffer(root .. "/large.lua", { string.rep("b", 5000), selected, string.rep("a", 5000) })
		local opts = config.merge({ explanation = { context = { max_bytes = 2500 } } }).explanation
		local prompt = assert(context.build(snapshot(bufnr, 2, { selected }), opts))
		assert.is_true(#prompt <= 2500)
		assert.equals(selected, decoded(prompt).selection[1].text)
		assert.same({}, decoded(prompt).before)
		assert.same({}, decoded(prompt).after)
		opts.context.max_bytes = 1024
		local missing, err = context.build(snapshot(bufnr, 2, { selected }), opts)
		assert.is_nil(missing)
		assert.matches("full selection exceeds", err)
	end)

	it("uses a custom prompt with the language placeholder and counts it against the budget", function()
		local bufnr = buffer(root .. "/custom.lua", { "local value = 1" })
		local selected = snapshot(bufnr, 1, { "local value = 1" })
		local opts = config.merge({ explanation = {
			language = "ru", prompt = "Ответь одним предложением на {language} без номеров строк.",
		} }).explanation
		local prompt = assert(context.build(selected, opts))
		assert.is_truthy(prompt:find("Ответь одним предложением на ru без номеров строк.", 1, true))
		assert.is_nil(prompt:find("Explain the selected source code", 1, true))
		assert.same({ { line = 1, text = "local value = 1" } }, decoded(prompt).selection)
		opts.prompt = string.rep("x", opts.context.max_bytes)
		local missing, err = context.build(selected, opts)
		assert.is_nil(missing)
		assert.matches("full selection exceeds", err)
		assert.has_error(function() config.merge({ explanation = { prompt = "  " } }) end,
			"opencode.nvim: explanation.prompt must be a non-empty string")
	end)

	it("preserves source line numbers for every blockwise selection row", function()
		local bufnr = buffer(root .. "/block.lua", { "abc", "", "def", "ghi" })
		local selected = snapshot(bufnr, 1, { "a", "", "d", "g" }, "\022")
		local data = decoded(context.build(selected, config.merge().explanation))
		assert.equals("block", data.selection_mode)
		assert.same({
			{ line = 1, text = "a" }, { line = 2, text = "" },
			{ line = 3, text = "d" }, { line = 4, text = "g" },
		}, data.selection)
	end)

	it("preserves padding-only block rows in the prompt context", function()
		local bufnr = buffer(root .. "/ragged.lua", { "abcdef", "", "ghijkl" })
		local selected = snapshot(bufnr, 1, { "bcd", "   ", "hij" }, "\022")
		assert.same({
			{ line = 1, text = "bcd" }, { line = 2, text = "   " },
			{ line = 3, text = "hij" },
		}, decoded(context.build(selected, config.merge().explanation)).selection)
	end)
end)
