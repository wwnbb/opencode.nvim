-- Real TCP/SSE -> v2 reducer -> coalescer -> native buffer, with a controlled
-- local server so assertions can run before it sends the closing fence.
for path in (vim.env.OPENCODE_CODE_RTP or ""):gmatch("[^:]+") do vim.opt.runtimepath:append(path) end
local port = assert(tonumber(vim.env.OPENCODE_CODE_SSE_PORT))
local app, client = require("opencode"), require("opencode.client")
app.setup({ server = { host = "127.0.0.1", port = port, auto_start = false,
	auth = { username = "opencode", password = "fixture-only" } },
	chat = { width = 92, close_on_focus_lost = false }, lualine = { enabled = false } })
client.setup({ host = "127.0.0.1", port = port, reconnect = false, auth = { password = "fixture-only" } })
local state, sync, chat = require("opencode.state"), require("opencode.sync"), require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
state.set_session("code-sse", "Live Rust over SSE")
state.set_session_status("code-sse", { type = "busy" })
client.get_messages = function(_, _, cb) cb(nil, {}) end
chat.open()
local ended = false
client.on_event("session.text.ended", function() ended = true end)
assert(client.connect_events())
local part_id = require("opencode.protocol.v2.messages").part_id("code-sse", "answer", "text", 0)
local function highlighted()
	local count = 0
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.get_bufnr(), cs.chat_hl_ns, 0, -1, { details = true })) do
		if mark[4].priority == 4100 then count = count + 1 end
	end
	return count > 0
end
assert(vim.wait(10000, function()
	local part = sync.get_part("answer", part_id)
	local visible = table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n")
	return part and part.text:find("// before closing", 1, true) and visible:find("// before closing", 1, true) and highlighted()
end, 10), "SSE open block never received highlights")
assert(not ended, "Server completed the response before the open-block assertion")
assert(state.get_session_status("code-sse").type ~= "idle")
vim.cmd("redraw!"); vim.rpcnotify(1, "opencode_screenshot", "rust-live-sse-before-closing")
require("opencode.client.http").get("/continue", function(err) assert(not err, tostring(err)) end)
assert(vim.wait(10000, function()
	return ended and table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n"):find("After the code.", 1, true)
end, 10), "SSE final replacement was not rendered")
assert(highlighted())
local lines = vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false)
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.get_bufnr(), cs.chat_hl_ns, 0, -1, { details = true })) do
	if mark[4].priority == 4100 then assert(not lines[mark[2] + 1]:find("After the code.", 1, true)) end
end
client.disconnect_events()
print("Real SSE: Rust highlighted before closing fence and text.ended; prose stays unhighlighted")
chat.close()
