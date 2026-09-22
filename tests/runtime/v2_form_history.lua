-- A real model invokes native question -> native form -> keyboard reply -> history.
local app, client, state = require("opencode"), require("opencode.client"), require("opencode.state")
local session, sync, chat = require("opencode.session"), require("opencode.sync"), require("opencode.ui.chat")
local forms, cs = require("opencode.question.state"), require("opencode.ui.chat.state").state
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 15000, predicate, 20), why) end
local function await(register)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return value
end
local function key(name)
	local map = vim.fn.maparg(name, "n", false, true)
	assert(type(map.callback) == "function", "Missing mapping " .. name); map.callback()
end
local function text() chat.do_render(); return table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n") end
local function shot(name)
	chat.do_render(); vim.cmd("redraw!")
	if vim.env.OPENCODE_V2_ATTACHED_UI then vim.rpcnotify(1, "opencode_screenshot", name) end
end
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } }, lualine = { enabled = false } })
require("opencode.lifecycle").ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "No model catalog")
local info = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model },
	permissions = { { action = "question", resource = "*", effect = "allow" } } }, cb) end)
session.remember(info); session.set_active(info.id, "Completed native question", { preserve_cache = true }); chat.open()
assert(require("opencode.send").send('Call the direct top-level question tool exactly once. Ask one question with header "History", prompt "Pick a stored answer", and two options: label "Red answer" description "First choice", label "Blue answer" description "Second choice". Wait for my answer. After the answer, reply exactly FORM_HISTORY_DONE. Do not use any other tools.', {}))
local item
wait(function()
	for _, candidate in ipairs(forms.get_all_active()) do if candidate.session_id == info.id then item = candidate; return true end end
end, "Model did not create a native form", 120000)
chat.focus(); chat.do_render()
local pos = assert(cs.questions[item.request_id]); vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 })
shot("native-question-pending"); key("2")
for _ = 1, 3 do
	if item.status == "answered" or item.submitting then break end
	chat.do_render(); pos = assert(cs.questions[item.request_id]); vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 }); key("<CR>")
end
wait(function() return item.status == "answered" end, "Question answer did not settle")
wait(function()
	return text():find("FORM_HISTORY_DONE", 1, true) and state.get_session_status(info.id).type == "idle"
end, "Model did not finish after answer", 120000)
local history = await(function(cb) client.get_all_messages(info.id, cb) end)
local native = await(function(cb) client.http.get("/api/session/" .. info.id .. "/message", cb) end)
local detail = await(function(cb) client.get_form(info.id, item.request_id, cb) end)
local live = text(); assert(live:find("History: Blue answer", 1, true), "Durable answered summary missing")
shot("native-question-completed")
vim.fn.writefile({ vim.json.encode({ session = info, form = detail, native = native, history = history, rendered = live }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); require("opencode.lifecycle").disconnect()
print("Native question answered and retained for cold-history reopening")
