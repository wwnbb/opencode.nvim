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
	local function file(prompt) return prompt:match('<file path="[^"]*" language="[^"]*">\n(.-)</file>\n') end
	local function selection(prompt)
		local lines, mode, text = prompt:match('<selection lines="([^"]*)" mode="([^"]*)">\n(.-)\n</selection>\n')
		return { lines = lines, mode = mode, text = text }
	end
	-- Source lines around the selection inside <file>.
	local function surroundings(prompt)
		return file(prompt):match("^(.-)<selection .-</selection>\n(.*)$")
	end
	local function diagnostic_lines(prompt)
		local block = prompt:match("<diagnostics>\n(.-)</diagnostics>\n")
		return block and vim.split(block, "\n", { trimempty = true }) or {}
	end
	local function related(prompt)
		local found = {}
		for path, body in prompt:gmatch('<related path="([^"]*)" start_line="%d+">\n(.-)</related>\n') do
			found[#found + 1] = { path = path, body = body }
		end
		return found
	end
	before_each(function() buffers = {}; original_buf = vim.api.nvim_get_current_buf() end)
	after_each(function()
		vim.api.nvim_set_current_buf(original_buf)
		for _, bufnr in ipairs(buffers) do
			vim.diagnostic.reset(diagnostic_ns, bufnr)
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("puts the entire unsaved selection with exact source lines before the instruction", function()
		local bufnr = buffer(root .. "/main.lua", { "-- header", "local before = 1", "local a = 'é'", "return a", "after()" })
		buffer(root .. "/sibling.lua", { "return { unsaved = true }" })
		local opts = config.merge({ explanation = { language = "ru" } }).explanation
		local prompt = assert(context.build(snapshot(bufnr, 3, { "local a = 'é'", "return a" }), opts))
		local instruction = prompt:find("Объясни по-русски только код внутри <selection>", 1, true)
		assert.is_truthy(instruction)
		assert.is_true(instruction > prompt:find("</file>\n", 1, true))
		assert.is_truthy(prompt:find("<answer>", 1, true))
		assert.is_nil(prompt:find("JSON", 1, true))
		assert.same({ lines = "3-4", mode = "line", text = "local a = 'é'\nreturn a" }, selection(prompt))
		local before, after = surroundings(prompt)
		assert.equals("-- header\nlocal before = 1\n", before)
		assert.equals("after()\n", after)
		assert.same({ { path = "sibling.lua", body = "return { unsaved = true }\n" } }, related(prompt))
		assert.same({}, diagnostic_lines(prompt))
		assert.is_nil(prompt:find("<diagnostics> are", 1, true))
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
		local prompt = assert(context.build(snapshot(bufnr, 3, { "three", "four" }), config.merge().explanation))
		assert.same({
			"line 2:1 ERROR: Starts above and enters selection",
			"line 3:2 WARN: Inside selection",
			"line 4:1 INFO: Starts inside and extends below selection",
		}, diagnostic_lines(prompt))
		assert.is_truthy(prompt:find("<diagnostics> are the editor's linter/LSP messages", 1, true))
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
			'line 2:3 ERROR ruff F821: Undefined name "missing"',
			"line 1:6 WARN: Earlier line",
			"line 2:1 WARN: Earlier column",
			"line 2:2 WARN pylsp 42: A warning",
			"line 2:2 WARN: Z warning",
			"line 1:1 INFO: Information",
			"line 1:1 HINT: Hint",
		}, diagnostic_lines(prompt))
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
		opts.context.max_bytes = #base + 240
		opts.context.before_lines, opts.context.after_lines = 1, 1
		diagnostics(bufnr, {
			{ lnum = 1, col = 0, severity = 1, message = string.rep("é", 2000) },
			{ lnum = 1, col = 0, severity = 2, message = "Unknown name" },
		})
		local prompt = assert(context.build(snap, opts))
		assert.is_true(#prompt <= opts.context.max_bytes)
		assert.equals(selected, selection(prompt).text)
		assert.same({ "line 2:1 WARN: Unknown name" }, diagnostic_lines(prompt))
		local before, after = surroundings(prompt)
		assert.equals("", before)
		assert.equals("", after)
	end)

	it("uses the byte budget for optional context and never truncates selected UTF-8", function()
		local selected = string.rep("é", 500)
		local bufnr = buffer(root .. "/large.lua", { string.rep("b", 5000), selected, string.rep("a", 5000) })
		local opts = config.merge({ explanation = { context = { max_bytes = 2500 } } }).explanation
		local prompt = assert(context.build(snapshot(bufnr, 2, { selected }), opts))
		assert.is_true(#prompt <= 2500)
		assert.equals(selected, selection(prompt).text)
		local before, after = surroundings(prompt)
		assert.equals("", before)
		assert.equals("", after)
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
		assert.equals("Ответь одним предложением на ru без номеров строк.\n", prompt:match("</diagnostics>\n(.*)$"))
		assert.is_nil(prompt:find("Explain only the code", 1, true))
		assert.same({ lines = "1", mode = "line", text = "local value = 1" }, selection(prompt))
		assert.same({ "line 1:1 INFO: Custom prompt diagnostic" }, diagnostic_lines(prompt))
		opts.prompt = string.rep("x", opts.context.max_bytes)
		local missing, err = context.build(selected, opts)
		assert.is_nil(missing)
		assert.matches("full selection exceeds", err)
		assert.has_error(function() config.merge({ explanation = { prompt = "  " } }) end,
			"opencode.nvim: explanation.prompt must be a non-empty string")
	end)

	it("names the answer language in the default instruction", function()
		local bufnr = buffer(root .. "/language.lua", { "local value = 1" })
		local prompt = assert(context.build(snapshot(bufnr, 1, { "local value = 1" }), config.merge().explanation))
		assert.is_truthy(prompt:find("Answer in this language: en.", 1, true))
		assert.is_nil(prompt:find("code in en", 1, true))
	end)

	it("preserves source line numbers and empty or padded block rows", function()
		local bufnr = buffer(root .. "/block.lua", { "abcdef", "", "ghijkl" })
		for _, middle in ipairs({ "", "   " }) do
			local prompt = assert(context.build(snapshot(bufnr, 1, { "bcd", middle, "hij" }, "\022"), config.merge().explanation))
			assert.same({ lines = "1-3", mode = "block", text = "bcd\n" .. middle .. "\nhij" }, selection(prompt))
		end
		local prompt = assert(context.build(snapshot(bufnr, 1, { "cd" }, "v"), config.merge().explanation))
		assert.equals("character", selection(prompt).mode)
	end)

	it("asks follow-ups with the built-in instruction after the same context and every earlier turn", function()
		local bufnr = buffer(root .. "/follow.lua", { "local value = 1", "return value" })
		local opts = config.merge({ explanation = { prompt = "Custom {language}", language = "ru" } }).explanation
		local snap = snapshot(bufnr, 1, { "local value = 1" })
		local collected = assert(context.collect(snap, opts))
		local prompt = context.prompt(collected, opts)
		assert.equals(prompt, context.build(snap, opts))
		assert.equals(collected .. "Custom ru\n", prompt)
		local turns = { { answer = "First." }, { question = "Why?", answer = "Because." }, { question = "And?" } }
		local follow_up = context.follow_up(collected, turns, opts)
		assert.equals(collected, follow_up:sub(1, #collected))
		assert.is_truthy(follow_up:find("Ответь по-русски на последний вопрос", 1, true))
		assert.is_nil(follow_up:find("Custom", 1, true))
		assert.equals("<conversation>\n<assistant>\nFirst.\n</assistant>\n<user>\nWhy?\n</user>\n"
			.. "<assistant>\nBecause.\n</assistant>\n<user>\nAnd?\n</user>\n</conversation>\n",
			follow_up:sub(#collected + 1):match("^<conversation>\n.-</conversation>\n"))
		opts.language = "de"
		assert.is_truthy(context.follow_up(collected, turns, opts):find("Answer in this language: de.", 1, true))
	end)
end)
