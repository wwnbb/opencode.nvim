-- Native input UI check; requires Rust parser/queries via OPENCODE_CODE_RTP.
-- Run with tests/runtime/native_ui.py's run() helper. No server is contacted.
for path in (vim.env.OPENCODE_CODE_RTP or ""):gmatch("[^:]+") do vim.opt.runtimepath:append(path) end
assert(pcall(vim.treesitter.language.add, "rust"), "Rust parser required")
assert(vim.treesitter.query.get("rust", "highlights"), "Rust highlight queries required")

local app = require("opencode")
app.setup({
	server = { auto_start = false },
	lualine = { enabled = false },
	chat = { layout = "vertical", width = 86, close_on_focus_lost = false },
	input = { max_height = 18, history_file = vim.fn.tempname() },
})
local input, chat = require("opencode.ui.input"), require("opencode.ui.chat")
local namespace = vim.api.nvim_create_namespace("opencode_input_syntax")
local source = {
	"#[derive(Debug, Clone)]",
	"pub struct Parser {",
	"    tokens: Vec<Token>,",
	"    pos: usize,",
	"}",
}
local source_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(source_buf, "/tmp/opencode-input-example.rs")
vim.bo[source_buf].filetype = "rust"
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source)
vim.cmd("normal! ggV4j")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
assert(app.add_visual_selection_to_input())
chat.open()
chat.focus_input()

local input_win, input_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local function count()
	return #vim.api.nvim_buf_get_extmarks(input_buf, namespace, 0, -1, { details = true })
end
local function wait_highlights()
	assert(vim.wait(1000, function() return count() > 0 end, 5), "Input code has no highlights")
end
local function shot(name)
	vim.cmd("redraw!")
	vim.rpcnotify(1, "opencode_screenshot", name)
end
wait_highlights()
shot("input-rust-selection-dark")

local draft = "Explain this function:\n```rust\nfn greet(name: &str) {\n    let message = \"Привет, мир\";\n    println!(\"{message}: {name}\");\n}"
input.set_pending_text(draft)
vim.wait(30, function() return false end, 5)
wait_highlights()
shot("input-rust-open-fence-dark")
vim.cmd("stopinsert")
vim.api.nvim_win_set_cursor(input_win, { 3, 0 })
vim.cmd("normal! V2j")
shot("input-rust-visual-selection-dark")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

local cursor = vim.api.nvim_win_get_cursor(input_win)
vim.o.background = "light"
vim.cmd("colorscheme default")
vim.api.nvim_win_set_width(chat.get_winid(), 48)
vim.api.nvim_exec_autocmds("WinResized", { data = { windows = { chat.get_winid() } } })
vim.wait(60, function() return false end, 5)
wait_highlights()
assert(vim.api.nvim_get_current_win() == input_win, "Highlighting stole focus")
assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(input_win)), "Highlighting moved the cursor")
assert(input.get_pending_text() == draft, "Highlighting changed the draft")
shot("input-rust-open-fence-narrow-light")

-- Time full input updates, including scheduled parsing and extmark replacement.
local samples = {}
for _, size in ipairs({ 224, 500 }) do
	local lines = { "```rust", "fn example() {" }
	for i = 2, size - 1 do lines[#lines + 1] = string.format("    let value_%d = %d;", i, i) end
	lines[#lines + 1] = "    let tail = 1"
	input.set_pending_text(table.concat(lines, "\n"))
	vim.wait(50, function() return false end, 5)
	local times = {}
	for _ = 1, 10 do
		local row = #lines - 1
		local col = #vim.api.nvim_buf_get_lines(input_buf, row, row + 1, false)[1]
		local start = vim.uv.hrtime()
		vim.api.nvim_buf_set_text(input_buf, row, col, row, col, { "1" })
		assert(vim.wait(1000, function()
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(input_buf, namespace, { row, 0 }, -1, { details = true })) do
				if mark[4].end_col == col + 1 then return true end
			end
			return false
		end, 1))
		times[#times + 1] = (vim.uv.hrtime() - start) / 1e6
	end
	table.sort(times)
	samples[#samples + 1] = { lines = size, samples = #times, median_ms = times[5], max_ms = times[10] }
end
if vim.env.OPENCODE_INPUT_REPORT then
	vim.fn.writefile({ vim.json.encode(samples) }, vim.env.OPENCODE_INPUT_REPORT)
end
input.close(false)
chat.close()
print("Input selection, open fences, visual mode, themes, wrapping and update timing passed")
