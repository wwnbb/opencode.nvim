-- Actual selection + clipboard input workflow, with a deterministic OS source.
local app, client = require("opencode"), require("opencode.client")
local state, sync, chat = require("opencode.state"), require("opencode.sync"), require("opencode.ui.chat")
local input, lifecycle = require("opencode.ui.input"), require("opencode.lifecycle")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 15000, predicate, 20), why) end
local function await(register)
	local done, data, failure
	register(function(err, result) failure, data, done = err, result, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return data
end
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } }, lualine = { enabled = false } })
lifecycle.ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "Model not loaded")
local created = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model } }, cb) end)
require("opencode.session").remember(created)
require("opencode.session").set_active(created.id, "Input attachments", { preserve_cache = true })
local path = directory .. "/выделение with spaces.txt"
vim.fn.writefile({ "OUTSIDE_SELECTION", "SELECTED_猫🙂", "SECOND_SELECTED_LINE", "ALSO_OUTSIDE" }, path)
vim.cmd.edit(vim.fn.fnameescape(path))
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("normal! Vj")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
assert(app.add_visual_selection_to_input({ context = "Reply exactly INPUT_ATTACHMENT_READY. Do not call tools." }))
local draft = input.get_pending_text()
assert(draft:find("SELECTED_猫🙂\nSECOND_SELECTED_LINE", 1, true) and draft:find("#2-3", 1, true), draft)
assert(not draft:find("OUTSIDE", 1, true), "Selection included unselected text")
app.focus_input(); wait(input.is_visible, "Input did not open")
assert(input.paste_clipboard(), "Clipboard paste failed")
assert(vim.fn.filereadable(vim.env.OPENCODE_V2_CLIPBOARD_SOURCE .. "/called") == 1, "Fixture OS clipboard source was not invoked")
local bufnr = vim.api.nvim_get_current_buf()
local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
assert(text:find("[Image 1]", 1, true), "Image marker missing from input")
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw"); vim.rpcnotify(1, "opencode_screenshot", "selection-clipboard-input") end
vim.cmd("stopinsert")
local send = vim.fn.maparg("<C-g>", "n", false, true)
assert(type(send.callback) == "function"); send.callback()
wait(function()
	for _, message in ipairs(sync.get_messages(created.id)) do if message.type == "idle" then return true end end
	return false
end, "Attachment prompt did not finish", 120000)
local history = await(function(cb) client.get_all_messages(created.id, cb) end)
local users, found, answer = 0, nil, ""
for _, message in ipairs(history) do
	if message.info.role == "user" then users = users + 1; found = message.info._v2 end
	if message.info.role == "assistant" then for _, part in ipairs(message.parts) do if part.type == "text" then answer = answer .. part.text end end end
end
assert(users == 1 and found and found.text:find("SELECTED_猫🙂\nSECOND_SELECTED_LINE", 1, true), "Selection lost in history")
assert(not found.text:find("OUTSIDE", 1, true))
assert(#found.files == 1 and found.files[1].mime == "image/png", vim.inspect(found.files))
local image_file = assert(io.open(vim.env.OPENCODE_V2_CLIPBOARD_SOURCE .. "/source.png", "rb"))
local bytes = image_file:read("*a")
image_file:close()
assert(found.files[1].data == vim.base64.encode(bytes), "Clipboard bytes changed")
assert(found.files[1].mention and found.files[1].mention.text == "[Image 1]", "Image mention lost")
assert(answer:find("INPUT_ATTACHMENT_READY", 1, true), answer)
chat.focus(); chat.do_render()
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw"); vim.rpcnotify(1, "opencode_screenshot", "selection-clipboard-history") end
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", model = provider .. "/" .. model, history = history,
	selection_exact = true, clipboard_bytes_exact = true, keyboard_submit_once = true,
	clipboard_source = "isolated osascript shim returning a generated PNG; personal clipboard untouched" }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Selection and clipboard input survived native prompt/history round trip")
