local context = require("opencode.explanation.context")
local config = require("opencode.config")

describe("selection explanation context", function()
	local buffers, original_buf
	local root = "/tmp/opencode-explanation-context"
	local diagnostic_ns = vim.api.nvim_create_namespace("opencode_explanation_context_test")
	local function diagnostics(bufnr, items)
		vim.diagnostic.set(diagnostic_ns, bufnr, items, { virtual_text = false, signs = false, underline = false })
	end
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
		for _, bufnr in ipairs(buffers) do
			vim.diagnostic.reset(diagnostic_ns, bufnr)
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("prioritizes the entire unsaved selection and adds exact source line numbers", function()
		local bufnr = buffer(root .. "/main.lua", { "-- header", "local before = 1", "local a = 'é'", "return a", "after()" })
		buffer(root .. "/sibling.lua", { "return { unsaved = true }" })
		local opts = config.merge({ explanation = { language = "ru" } }).explanation
		local prompt = assert(context.build(snapshot(bufnr, 3, { "local a = 'é'", "return a" }), opts))
		local data = decoded(prompt)
		assert.is_truthy(prompt:find("Объясни только выделенный исходный код по-русски", 1, true))
		assert.is_truthy(prompt:find("<answer>", 1, true))
		assert.is_truthy(prompt:find("отдельный блок «Диагностика»", 1, true))
		assert.same({ { line = 3, text = "local a = 'é'" }, { line = 4, text = "return a" } }, data.selection)
		assert.same({ "-- header", "local before = 1" }, data.before)
		assert.same({ "after()" }, data.after)
		assert.equals("sibling.lua", data.related[1].path)
		assert.same({ "return { unsaved = true }" }, data.related[1].lines)
		assert.same({}, data.diagnostics)
	end)

	it("includes only diagnostics whose ranges overlap the selected source lines", function()
		local bufnr = buffer(root .. "/ranges.lua", { "one", "two", "three", "four", "five", "six" })
		local other = buffer(root .. "/other.lua", { "one", "two", "three", "four" })
		diagnostics(bufnr, {
			{ lnum = 0, col = 0, end_lnum = 2, end_col = 0, severity = 1, message = "Ends before selection" },
			{ lnum = 1, col = 0, end_lnum = 2, end_col = 2, severity = 1, message = "Starts above and enters selection" },
			{ lnum = 2, col = 1, severity = 2, message = "Inside selection" },
			{ lnum = 3, col = 0, end_lnum = 5, end_col = 2, severity = 3, message = "Starts inside and extends below selection" },
			{ lnum = 4, col = 0, severity = 1, message = "Below selection" },
		})
		diagnostics(other, { { lnum = 2, col = 0, severity = 1, message = "Other buffer diagnostic" } })
		local data = decoded(assert(context.build(snapshot(bufnr, 3, { "three", "four" }), config.merge().explanation)))
		assert.same({
			"Starts above and enters selection", "Inside selection", "Starts inside and extends below selection",
		}, vim.tbl_map(function(item) return item.message end, data.diagnostics))
		assert.equals(2, data.diagnostics[1].line)
		assert.equals(3, data.diagnostics[1].end_line)
		assert.equals(3, data.diagnostics[1].end_column)
	end)

	it("sorts diagnostic severity and positions while serializing only safe metadata", function()
		local bufnr = buffer(root .. "/metadata.lua", { "local foo = 1", "return missing" })
		diagnostics(bufnr, {
			{ lnum = 0, col = 0, severity = 4, message = "Hint" },
			{ lnum = 1, col = 1, severity = 2, message = "Z warning" },
			{ lnum = 1, col = 1, severity = 2, source = "pylsp", code = 42, message = "A warning" },
			{ lnum = 1, col = 0, severity = 2, message = "Earlier column" },
			{ lnum = 0, col = 5, severity = 2, message = "Earlier line" },
			{ lnum = 0, col = 0, severity = 3, message = "Information" },
			{ lnum = 1, col = 2, end_lnum = 1, end_col = 4, severity = 1, source = "ruff", code = "F821",
				message = 'Undefined name "missing"', user_data = { secret = "private-data", callback = function() end } },
		})
		local prompt = assert(context.build(snapshot(bufnr, 1, { "local foo = 1", "return missing" }), config.merge().explanation))
		assert.same({
			{ line = 2, column = 3, end_line = 2, end_column = 5, severity = "ERROR", source = "ruff", code = "F821", message = 'Undefined name "missing"' },
			{ line = 1, column = 6, end_line = 1, end_column = 6, severity = "WARN", message = "Earlier line" },
			{ line = 2, column = 1, end_line = 2, end_column = 1, severity = "WARN", message = "Earlier column" },
			{ line = 2, column = 2, end_line = 2, end_column = 2, severity = "WARN", source = "pylsp", code = 42, message = "A warning" },
			{ line = 2, column = 2, end_line = 2, end_column = 2, severity = "WARN", message = "Z warning" },
			{ line = 1, column = 1, end_line = 1, end_column = 1, severity = "INFO", message = "Information" },
			{ line = 1, column = 1, end_line = 1, end_column = 1, severity = "HINT", message = "Hint" },
		}, decoded(prompt).diagnostics)
		assert.is_nil(prompt:find("private-data", 1, true))
		assert.is_truthy(prompt:find("append a separate Diagnostics section inside <answer>", 1, true))
	end)

	it("skips oversized diagnostics but keeps smaller entries and the entire selected UTF-8", function()
		local selected = "local café = missing"
		local bufnr = buffer(root .. "/budget.lua", { string.rep("b", 100), selected, string.rep("a", 100) })
		local opts = config.merge({ explanation = { context = {
			before_lines = 0, after_lines = 0, header_lines = 0, max_related_buffers = 0,
		} } }).explanation
		local snap = snapshot(bufnr, 2, { selected })
		local base = assert(context.build(snap, opts))
		opts.context.max_bytes = #base + 180
		opts.context.before_lines, opts.context.after_lines = 1, 1
		diagnostics(bufnr, {
			{ lnum = 1, col = 0, severity = 1, message = string.rep("é", 2000) },
			{ lnum = 1, col = 0, severity = 2, message = "Unknown name" },
		})
		local prompt = assert(context.build(snap, opts))
		assert.is_true(#prompt <= opts.context.max_bytes)
		assert.same({ { line = 2, text = selected } }, decoded(prompt).selection)
		assert.equals(1, #decoded(prompt).diagnostics)
		assert.equals("Unknown name", decoded(prompt).diagnostics[1].message)
		assert.same({}, decoded(prompt).before)
		assert.same({}, decoded(prompt).after)
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
		diagnostics(bufnr, { { lnum = 0, col = 0, severity = 3, message = "Custom prompt diagnostic" } })
		local selected = snapshot(bufnr, 1, { "local value = 1" })
		local opts = config.merge({ explanation = {
			language = "ru", prompt = "Ответь одним предложением на {language} без номеров строк.",
		} }).explanation
		local prompt = assert(context.build(selected, opts))
		assert.is_truthy(prompt:find("Ответь одним предложением на ru без номеров строк.", 1, true))
		assert.is_nil(prompt:find("Explain the selected source code", 1, true))
		assert.same({ { line = 1, text = "local value = 1" } }, decoded(prompt).selection)
		assert.equals("Custom prompt diagnostic", decoded(prompt).diagnostics[1].message)
		opts.prompt = string.rep("x", opts.context.max_bytes)
		local missing, err = context.build(selected, opts)
		assert.is_nil(missing)
		assert.matches("full selection exceeds", err)
		assert.has_error(function() config.merge({ explanation = { prompt = "  " } }) end,
			"opencode.nvim: explanation.prompt must be a non-empty string")
	end)

	it("preserves source line numbers and empty or padded block rows", function()
		local bufnr = buffer(root .. "/block.lua", { "abcdef", "", "ghijkl" })
		for _, middle in ipairs({ "", "   " }) do
			local selected = snapshot(bufnr, 1, { "bcd", middle, "hij" }, "\022")
			local data = decoded(context.build(selected, config.merge().explanation))
			assert.equals("block", data.selection_mode)
			assert.same({
				{ line = 1, text = "bcd" }, { line = 2, text = middle }, { line = 3, text = "hij" },
			}, data.selection)
		end
	end)

end)
