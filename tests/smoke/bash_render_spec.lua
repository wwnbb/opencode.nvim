local bash = require("opencode.ui.chat.bash")
local chat_state = require("opencode.ui.chat.state").state
local syntax = require("opencode.ui.syntax")

describe("shell panel tab rendering", function()
	local saved
	before_each(function()
		saved = {
			bufnr = chat_state.bufnr, winid = chat_state.winid,
			buffer = vim.api.nvim_get_current_buf(), columns = vim.o.columns,
			add_highlights = syntax.add_highlights,
		}
		vim.cmd("botright new")
		chat_state.bufnr = vim.api.nvim_get_current_buf()
		chat_state.winid = vim.api.nvim_get_current_win()
		vim.bo.buftype, vim.bo.bufhidden = "nofile", "wipe"
		vim.wo.wrap, vim.wo.linebreak, vim.wo.breakindent = true, true, true
		vim.wo.number, vim.wo.relativenumber, vim.wo.list = false, false, false
		vim.wo.signcolumn, vim.wo.foldcolumn = "no", "0"
	end)

	after_each(function()
		syntax.add_highlights = saved.add_highlights
		vim.api.nvim_win_close(chat_state.winid, true)
		vim.o.columns = saved.columns
		chat_state.bufnr, chat_state.winid = saved.bufnr, saved.winid
	end)

	it("keeps Plenary output within panel rows with linebreak enabled", function()
		local part = {
			tool = "bash",
			state = {
				status = "completed", input = { command = "./tests/run.sh smoke" },
				output = table.concat({
					"Using plenary.nvim from: /tmp/opencode.nvim/.deps/nvim/plenary.nvim",
					"==> tests/smoke", "Starting...Scheduling: tests/smoke/require_spec.lua", "",
					"========================================\t",
					"Testing: \t/tmp/opencode.nvim/tests/smoke/chat_new_session_skill_render_spec.lua\t",
					"Live UI check skipped: run tests/runtime/capture_v2.py --nvim-ui with an explicit model.\t",
					"\27[32mSuccess\27[0m\t||\topencode real server smoke renders a native skill after starting a new chat session\t",
					"\t", "Success: \t1\t", "Failed: \t0\t", "Errors: \t0\t",
				}, "\n"),
			},
		}
		local original = vim.deepcopy(part)
		for _, width in ipairs({ 40, 144 }) do
			vim.o.columns = width
			for _, tabstop in ipairs({ 2, 8 }) do
				vim.bo[chat_state.bufnr].tabstop = tabstop
				for _, expanded in ipairs({ false, true }) do
					local result = bash.render_tool(part, expanded)
					vim.api.nvim_buf_set_lines(chat_state.bufnr, 0, -1, false, result.lines)
					assert.equals(#result.lines, vim.api.nvim_win_text_height(chat_state.winid, {}).all)
					for _, line in ipairs(result.lines) do
						assert.equals("▏", line:sub(1, #"▏"))
						assert.equals(width, vim.fn.strdisplaywidth(line))
					end
				end
			end
		end
		assert.same(original, part)
	end)

	it("aligns syntax highlights with expanded command and output tabs", function()
		vim.o.columns = 144
		vim.bo[chat_state.bufnr].tabstop = 8
		local highlighted = {}
		syntax.add_highlights = function(result, text, language, opts)
			table.insert(highlighted, { text = text, language = language })
			for i, line in ipairs(vim.split(text, "\n", { plain = true })) do
				local rendered = result.lines[opts.line_start + i]
				assert.equals(line, rendered:sub(opts.col_offset + 1, opts.col_offset + #line))
			end
		end
		local result = bash.render_tool({
			tool = "bash", state = {
				status = "error", input = { command = "printf\t'界'\n\tprintf done" },
				output = "{\n\t\"界\":\t1\n}", metadata = { language = "json" },
				error = "failure:\tmessage\t",
			},
		}, true)
		assert.same({
			{ language = "bash", text = "printf     '界'\n   printf done" },
			{ language = "json", text = "{\n     \"界\":   1\n}\n" },
		}, highlighted)
		vim.api.nvim_buf_set_lines(chat_state.bufnr, 0, -1, false, result.lines)
		assert.equals(#result.lines, vim.api.nvim_win_text_height(chat_state.winid, {}).all)
		assert.is_nil(table.concat(result.lines):find("\t", 1, true))
	end)

	it("uses the chat tabstop and display columns while another buffer is current", function()
		local render = require("opencode.ui.chat.render")
		vim.bo[chat_state.bufnr].tabstop = 2
		vim.api.nvim_buf_call(saved.buffer, function()
			assert.equals("界  x", render.expand_tabs("界\tx", 0))
			assert.equals("界 x", render.expand_tabs("界\tx", 3))
			assert.equals(" a b", render.expand_tabs("\ta\tb", 3))
		end)
	end)
end)
