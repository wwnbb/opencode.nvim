local app, client = require("opencode"), require("opencode.client")
local state, sync, chat = require("opencode.state"), require("opencode.sync"), require("opencode.ui.chat")
local session, lifecycle = require("opencode.session"), require("opencode.lifecycle")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
vim.cmd.cd(vim.fn.fnameescape(directory))
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 15000, predicate, 20), why) end
local function await(register)
	local done, data, failure
	register(function(err, result) failure, data, done = err, result, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return data
end
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } }, lualine = { enabled = false } })
lifecycle.ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "Catalogs unavailable")
local info = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model } }, cb) end)
session.remember(info); session.set_active(info.id, "Reconnect smoke", { preserve_cache = true }); chat.open()
local view = require("opencode.ui.chat.state").state
view.auto_scroll = false
local dropped, reconnected, deltas = false, false, 0
client.on_event("session.text.delta", function(data)
	if data.sessionID ~= info.id then return end
	deltas = deltas + 1
	if dropped then return end
	dropped = true
	client.disconnect_events(); state.set_connection("idle")
	vim.defer_fn(function() assert(client.connect_events()); reconnected = true end, 700)
end)
assert(require("opencode.send").send("This is a chat streaming test. Return exactly 40 lines directly in your final chat response, numbered ROW01 through ROW40, each followed by ': reconnect fixture'. Do not create or edit files. Do not call any tools. The complete 40 lines must appear as plain text in your response. No introduction.", {}))
wait(function()
	if not reconnected or not state.is_connected() then return false end
	for _, message in ipairs(sync.get_messages(info.id)) do if message.type == "idle" then return true end end
	return false
end, "Reconnect generation timeout", 120000)
assert(dropped and deltas > 0, "No stream interruption occurred")
local history = await(function(cb) client.get_all_messages(info.id, cb) end)
local answer = {}
for _, message in ipairs(history) do
	if message.info.type == "assistant" then
		for _, part in ipairs(message.parts) do
			assert(part.type ~= "tool", "Streaming fixture called a tool instead of answering directly")
			if part.type == "text" then answer[#answer + 1] = part.text end
		end
		local matched = vim.wait(10000, function()
			local actual = sync.get_message(info.id, message.info.id)
			return actual and vim.deep_equal(actual._v2, message.info._v2)
		end, 20)
		if not matched then
			vim.fn.writefile({ vim.json.encode({ live = sync.get_message(info.id, message.info.id), expected = message.info }) }, vim.env.OPENCODE_V2_OUTPUT .. ".mismatch.json")
		end
		assert(matched, "Recovered live message differs from HTTP after reconciliation")
		assert(vim.deep_equal(sync.get_parts(message.info.id), message.parts), "Recovered parts differ from HTTP")
	end
end
local complete_answer = table.concat(answer, "\n")
for row = 1, 40 do assert(complete_answer:find(string.format("ROW%02d: reconnect fixture", row), 1, true), "Incomplete 40-line response") end
assert(view.auto_scroll == false, "Reconnect enabled auto-scroll")
chat.do_render()
local live = table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n")
assert(live:find("ROW40", 1, true), "Final text missing from live buffer")
sync.clear_session_messages(info.id); sync.handle_session_messages(info.id, history, { complete = true, reconcile = true }); chat.do_render()
local cold = table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n")
assert(live == cold, "Live and cold render differ")
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw"); vim.rpcnotify(1, "opencode_screenshot", "reconnected-chat") end
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", dropped_mid_text = true, delta_count = deltas,
	live_equals_http = true, live_equals_cold_render = true, auto_scroll_preserved = true, rendered = live }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Mid-text SSE reconnect, exact history/render and auto-scroll preservation passed")
