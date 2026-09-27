local app = require("opencode")
local input = require("opencode.ui.input")
local code_blocks = require("opencode.ui.code_blocks")

describe("code selections in the input draft", function()
	local bufnr, previous_buf, previous_notify, previous_open, previous_leader
	local opened

	before_each(function()
		previous_buf = vim.api.nvim_get_current_buf()
		previous_notify, previous_open, previous_leader = vim.notify, app.open_input_at_end, vim.g.mapleader
		vim.notify = function() end
		opened = 0
		app.open_input_at_end = function()
			opened = opened + 1
		end
		vim.g.mapleader = " "
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".rs")
		vim.bo[bufnr].filetype = "rust"
		input.set_pending_text("")
	end)

	after_each(function()
		input.set_pending_text("")
		vim.notify, app.open_input_at_end, vim.g.mapleader = previous_notify, previous_open, previous_leader
		vim.api.nvim_set_current_buf(previous_buf)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end)

	local function reference(range)
		return "@" .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:.") .. "#" .. range
	end

	local function select(keys)
		vim.cmd("normal! " .. keys)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
	end

	it("adds a Rust fence through the visual hotkey before focusing the input", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"outside", "fn main() {", '\tprintln!("Привет 猫🙂");', "}",
		})
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		input.set_pending_text("Explain this code")
		vim.keymap.set("x", "<leader>oe", function()
			app.add_visual_selection_and_open_input({ context = "  Focus on output  " })
		end, { buffer = bufnr })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Vj<Space>oe", true, false, true), "xt", false)
		assert.is_true(vim.wait(1000, function() return opened == 1 end, 10))
		assert.equals(
			"Explain this code\n\n" .. reference("2-3")
				.. '\n```rust\nfn main() {\n\tprintln!("Привет 猫🙂");\n```\nContext: Focus on output',
			input.get_pending_text()
		)
	end)

	it("preserves characterwise and rectangular selections inside the fence", function()
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "xxabczz", "xxdefzz" })
		for _, mode in ipairs({ "v", "\022" }) do
			input.set_pending_text("")
			vim.api.nvim_win_set_cursor(0, { 1, 2 })
			select(mode .. "j2l")
			assert.is_true(app.add_visual_selection_to_input())
			local selected = mode == "v" and "abczz\nxxdef" or "abc\ndef"
			assert.equals(reference("1-2") .. "\n```rust\n" .. selected .. "\n```", input.get_pending_text())
		end
	end)

	it("uses the source filetype and wraps normal-mode current lines too", function()
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "return 1", "" })
		assert.is_true(app.add_current_line_and_open_input())
		assert.equals(1, opened)
		assert.equals(reference("1") .. "\n```lua\nreturn 1\n```", input.get_pending_text())
		input.set_pending_text("")
		vim.api.nvim_win_set_cursor(0, { 2, 0 })
		assert.is_true(app.add_current_line_to_input())
		assert.equals(reference("2") .. "\n```lua\n\n```", input.get_pending_text())
	end)

	it("detects a language by filename when filetype is empty", function()
		vim.bo[bufnr].filetype = ""
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "let n = 1;" })
		assert.is_true(app.add_current_line_to_input())
		assert.equals(reference("1") .. "\n```rust\nlet n = 1;\n```", input.get_pending_text())
	end)

	it("keeps unknown filetypes in an unlabelled code block", function()
		vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".opencode_unknown_extension")
		vim.bo[bufnr].filetype = ""
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "some code" })
		select("V")
		assert.is_true(app.add_visual_selection_to_input())
		assert.equals(reference("1") .. "\n```\nsome code\n```", input.get_pending_text())
	end)

	it("keeps selected Markdown fences within one closed outer block", function()
		vim.bo[bufnr].filetype = "markdown"
		local selected = { "````lua", "return 1", "````", "```" }
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, selected)
		select("V3j")
		assert.is_true(app.add_visual_selection_to_input({ context = "Explain the Markdown" }))
		local blocks = code_blocks.parse(input.get_pending_text())
		assert.equals(1, #blocks)
		assert.equals("markdown", blocks[1].info)
		assert.is_true(blocks[1].closed)
		assert.same(selected, blocks[1].lines)
		assert.equals("Context: Explain the Markdown", vim.split(input.get_pending_text(), "\n")[#selected + 4])
	end)
end)
