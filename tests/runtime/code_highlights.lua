-- Native line-grid smoke and timing fixture. Requires Rust parser/queries on
-- runtimepath (OPENCODE_CODE_RTP, colon separated), no model or account access.
for path in (vim.env.OPENCODE_CODE_RTP or ""):gmatch("[^:]+") do vim.opt.runtimepath:append(path) end
assert(pcall(vim.treesitter.language.add, "rust"), "Rust parser required")
assert(vim.treesitter.query.get("rust", "highlights"), "Rust highlight queries required")
local app = require("opencode")
app.setup({ server = { auto_start = false }, lualine = { enabled = false },
	chat = { layout = "vertical", width = 92, close_on_focus_lost = false } })
local state, sync, chat = require("opencode.state"), require("opencode.sync"), require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local cache = require("opencode.ui.chat.render_state")
local event_seq = 0
local function event(kind, data)
	event_seq = event_seq + 1
	return sync.handle_v2_event({ id = "evt_visual_" .. event_seq, created = event_seq + 2,
		type = "session." .. kind, data = vim.tbl_extend("force", {
			sessionID = "code-visual", assistantMessageID = "assistant", ordinal = 0,
		}, data or {}) })
end
require("opencode.client").get_messages = function(_, _, cb) cb(nil, {}) end
state.set_session("code-visual", "Rust code highlights")
state.set_session_status("code-visual", { type = "busy" })
local rust = [[use crate::ast::Expr;
#[derive(Debug, Clone, PartialEq)]
pub enum ParseError {
    UnexpectedToken { expected: &'static str, found: String },
}
impl ParseError {
    pub fn describe(&self) -> String {
        let message = "Ошибка: неожиданный токен";
        format!("{message}: {self:?}")
    }
}]]
sync.handle_message_updated({ id = "user", sessionID = "code-visual", role = "user", time = { created = 1 } })
sync.handle_part_updated({ id = "user-text", sessionID = "code-visual", messageID = "user", type = "text",
	text = "@src/parser.rs#1-224\n```rust\n" .. rust .. "\n```" })
chat.open(); chat.do_render()
local function shot(name)
	vim.cmd("redraw!")
	vim.rpcnotify(1, "opencode_screenshot", name)
end
shot("rust-user-dark")
event("step.started", { started = 2, agent = "build", model = { providerID = "test", id = "test" } })
event("text.started")
event("text.delta", { delta = "```rust\n" .. rust })
local text_id = sync.get_parts("assistant")[1].id
chat.do_render()
local key = cache.stream_block_key("code-visual", "assistant", text_id, "text")
local function count_syntax()
	local block, count = cs.state.stream_blocks[key], 0
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.get_bufnr(), cs.chat_hl_ns, 0, -1, { details = true })) do
		if mark[2] >= block.start_line and mark[2] <= block.end_line and mark[4].priority == 4100 then count = count + 1 end
	end
	return count
end
assert(count_syntax() > 0, "Open Rust block has no colors")
shot("rust-open-stream-dark")
cs.state.auto_scroll = false
vim.api.nvim_win_set_cursor(chat.get_winid(), { cs.state.stream_blocks[key].start_line + 1, 0 })
chat.focus_input()
local input = require("opencode.ui.input")
assert(vim.wait(500, input.is_visible, 10))
local input_win, input_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "Unsent draft Привет" })
local cursor = vim.api.nvim_win_get_cursor(chat.get_winid())
vim.o.background = "light"; vim.cmd("colorscheme default")
vim.api.nvim_win_set_width(chat.get_winid(), 54)
vim.api.nvim_exec_autocmds("WinResized", { data = { windows = { chat.get_winid() } } })
vim.wait(100, function() return false end, 10)
chat.do_render()
event("text.delta", { delta = "\n// поток продолжается" })
assert(chat.update_stream_part_block("code-visual", "assistant", text_id))
assert(vim.api.nvim_get_current_win() == input_win, "Stream stole input focus")
assert(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] == "Unsent draft Привет", "Draft changed")
assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(chat.get_winid())), "Manual cursor moved")
assert(count_syntax() > 0)
shot("rust-open-stream-narrow-light-input")
input.close()
vim.api.nvim_win_set_width(chat.get_winid(), 92)
vim.o.background = "dark"; vim.cmd("colorscheme default")
vim.wait(100, function() return false end, 10)

local results = {}
for _, size in ipairs({ 224, 500 }) do
	local code = { "fn example() {" }
	for i = 2, size - 1 do code[#code + 1] = string.format('    let value_%d = "Привет";', i) end
	code[#code + 1] = "    let tail = 1"
	event("message.content.updated", { content = { { type = "text", text = "```rust\n" .. table.concat(code, "\n") } } })
	chat.do_render()
	local times, parses, parse_ms = {}, 0, 0
	local syntax = require("opencode.ui.syntax")
	local original = syntax.highlight_text
	syntax.highlight_text = function(...)
		parses = parses + 1
		local start = vim.uv.hrtime()
		local hls = original(...)
		parse_ms = parse_ms + (vim.uv.hrtime() - start) / 1e6
		return hls
	end
	for _ = 1, 20 do
		event("text.delta", { delta = "1" })
		local start = vim.uv.hrtime()
		assert(chat.update_stream_part_block("code-visual", "assistant", text_id))
		times[#times + 1] = (vim.uv.hrtime() - start) / 1e6
	end
	syntax.highlight_text = original
	table.sort(times)
	assert(parses == #times, "Unchanged user code was reparsed")
	results[#results + 1] = { lines = size, samples = #times, parses = parses,
		mean_syntax_ms = parse_ms / 20, median_ms = times[10], p95_ms = times[19], cache = cache.code_cache_stats() }
end
vim.fn.writefile({ vim.json.encode(results) }, assert(vim.env.OPENCODE_CODE_REPORT))
print("Open Rust blocks, focus, Unicode, resize, themes and timing checks passed")
chat.close()
