-- Resize the actual attached terminal while a real text stream updates the chat.
local app, client, state = require("opencode"), require("opencode.client"), require("opencode.state")
local sync, session, chat = require("opencode.sync"), require("opencode.session"), require("opencode.ui.chat")
local input, cs = require("opencode.ui.input"), require("opencode.ui.chat.state").state
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
assert(vim.env.OPENCODE_V2_ATTACHED_UI, "Requires an attached terminal")
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 15000, predicate, 10), why) end
local function await(register)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return value
end
local function text() chat.do_render(); return table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n") end
local function shot(name) chat.do_render(); vim.cmd("redraw!"); vim.rpcnotify(1, "opencode_screenshot", name) end
local function resize(width, height)
	vim.rpcnotify(1, "opencode_resize", width, height)
	wait(function() return vim.o.columns == width and vim.o.lines == height end, "Terminal did not resize")
	vim.wait(100, function() return false end, 10)
end
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } },
	chat = { width = 80, close_on_focus_lost = false }, lualine = { enabled = false } })
require("opencode.lifecycle").ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "No model")
local info = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model } }, cb) end)
session.remember(info); session.set_active(info.id, "Streaming resize", { preserve_cache = true }); chat.open(); chat.focus()
local deltas = 0
client.on_event("session.text.delta", function(data) if data.sessionID == info.id then deltas = deltas + 1 end end)
assert(require("opencode.send").send("Reply directly with exactly 160 lines numbered ROW001 through ROW160. Each line must be: ROWnnn: Unicode Привет — streaming resize fixture. Replace nnn by its three-digit number. No tools, no introduction, no code fence.", {}))
wait(function() return deltas >= 5 end, "No text stream", 120000)
cs.auto_scroll = false
vim.api.nvim_win_set_cursor(chat.get_winid(), { 3, 0 })
local cursor = vim.api.nvim_win_get_cursor(chat.get_winid())
app.focus_input(); wait(input.is_visible, "No input")
local input_win, input_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "Unsent draft Привет" })
local before = deltas
resize(80, 30)
vim.o.background = "light"; vim.cmd.colorscheme("default")
wait(function() return deltas > before end, "No deltas during resize/theme")
assert(vim.api.nvim_get_current_win() == input_win and input.is_visible(), "Streaming stole input focus")
assert(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] == "Unsent draft Привет", "Resize lost draft")
assert(vim.api.nvim_win_get_width(input_win) <= vim.api.nvim_win_get_width(chat.get_winid()), "Input overflowed its narrowed parent")
for _, win in ipairs(input.get_winids()) do
	local position = vim.api.nvim_win_get_position(win)
	assert(position[1] + vim.api.nvim_win_get_height(win) < vim.o.lines - vim.o.cmdheight, "Input/info bar clipped below editor")
end
assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(chat.get_winid())), "Streaming moved manually positioned chat cursor")
shot("stream-narrow-light-input")
input.close(); chat.focus()
for _, layout in ipairs({ "horizontal", "float", "vertical" }) do
	assert(state.get_session_status(info.id).type ~= "idle", "Stream ended before layout matrix")
	chat.close(); chat.setup({ layout = layout, height = 16, width = 58 }); chat.open(); chat.focus()
	cs.auto_scroll = false
	vim.api.nvim_win_set_cursor(chat.get_winid(), { 3, 0 })
	local win = chat.get_winid()
	local revision = deltas
	wait(function() return deltas > revision end, "No stream during " .. layout)
	assert(vim.api.nvim_get_current_win() == win, "Layout lost focus during stream")
	shot("stream-narrow-" .. layout)
end
client.disconnect_events(); state.set_connection("idle"); assert(client.connect_events())
wait(state.is_connected, "Reconnect failed")
resize(140, 44); vim.o.background = "dark"; vim.cmd.colorscheme("default")
assert(cs.auto_scroll == false, "Reconnect enabled auto-scroll")
wait(function()
	for _, message in ipairs(sync.get_messages(info.id)) do if message.type == "idle" then return true end end
	return false
end, "Generation did not finish", 150000)
local history = await(function(cb) client.get_all_messages(info.id, cb) end)
local answer = ""
for _, message in ipairs(history) do
	if message.info.type == "assistant" then for _, part in ipairs(message.parts) do
		assert(part.type ~= "tool", "Fixture used tools")
		if part.type == "text" then answer = answer .. part.text end
	end end
end
for row = 1, 160 do assert(answer:find(string.format("ROW%03d: Unicode Привет", row), 1, true), "Missing row " .. row) end
wait(function() return text():find("ROW160", 1, true) end, "Incomplete live render")
local live = text()
sync.clear_session_messages(info.id); sync.handle_session_messages(info.id, history, { complete = true, reconcile = true })
assert(text() == live, "Resize/reconnect changed history projection")
shot("stream-wide-dark-completed")
vim.fn.writefile({ vim.json.encode({ session = info, delta_count = deltas, input_focus_and_draft = true, manual_cursor_preserved = true,
	narrow_stream_layouts = { "vertical", "horizontal", "float" }, themes = { "light", "dark" }, live_equals_cold = true,
	auto_scroll_preserved = true, history = history }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); require("opencode.lifecycle").disconnect()
print("Real stream resize, theme, input focus/draft, cursor and live/cold matrix passed")
