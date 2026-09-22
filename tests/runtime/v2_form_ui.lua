-- Real native forms/permissions exercised through the installed chat mappings.
-- curl is a second client: its replies bypass every Lua action/state callback.
local app, client = require("opencode"), require("opencode.client")
local state, session = require("opencode.state"), require("opencode.session")
local chat, cs = require("opencode.ui.chat"), require("opencode.ui.chat.state").state
local forms, permissions = require("opencode.question.state"), require("opencode.permission.state")
local input = require("opencode.ui.input")
local url, directory = assert(vim.env.OPENCODE_V2_SERVER_URL), assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = url:match("^http://([^:]+):(%d+)$")
vim.cmd.cd(vim.fn.fnameescape(directory))
local function wait(predicate, why) assert(vim.wait(15000, predicate, 20), why) end
local function await(register)
	local done, data, failure
	register(function(err, result) failure, data, done = err, result, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return data
end
local function key(name)
	local map = vim.fn.maparg(name, "n", false, true)
	assert(type(map.callback) == "function", "Missing actual keymap " .. name)
	map.callback()
end
local function focus(kind, id)
	chat.focus(); chat.do_render()
	local pos = assert(cs[kind][id], "Widget not rendered: " .. id)
	vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 })
end
local function snapshot(name)
	chat.do_render()
	if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw"); vim.rpcnotify(1, "opencode_screenshot", name) end
end
local function second(method, path, body)
	local args = { "curl", "--silent", "--show-error", "--max-time", "10", "-u", "opencode:opencode-nvim-test-only",
		"-X", method, "-w", "\n%{http_code}", url .. path }
	if body then vim.list_extend(args, { "-H", "Content-Type: application/json", "--data-binary", vim.json.encode(body) }) end
	local result = vim.system(args, { text = true }):wait()
	assert(result.code == 0, result.stderr)
	local content, code = result.stdout:match("^(.*)\n(%d+)$")
	return tonumber(code), content ~= "" and vim.json.decode(content) or nil
end
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	chat = { width = 80, close_on_focus_lost = false }, lualine = { enabled = false } })
require("opencode.lifecycle").ensure_connected(function() end)
wait(state.is_connected, "No connection")
local created = await(function(cb) client.create_session({ location = { directory = directory }, permissions = {
	{ action = "form_ui_once", resource = "*", effect = "ask" },
	{ action = "form_ui_always", resource = "*", effect = "ask" },
	{ action = "form_ui_reject", resource = "*", effect = "ask" },
} }, cb) end)
session.remember(created); session.set_active(created.id, "Typed forms", { preserve_cache = true }); chat.open()
local prefix = "/api/session/" .. created.id
local function form(fields, title)
	local native = await(function(cb) client.http.post(prefix .. "/form", { title = title, fields = fields }, cb) end).data
	wait(function() return forms.get_question(native.id) end, "Form event missing")
	focus("questions", native.id)
	return native, forms.get_question(native.id)
end
local native, item = form({
	{ key = "target", type = "string", required = true, options = { { label = "Same", value = "a" }, { label = "Same", value = "b" } } },
	{ key = "checks", type = "multiselect", required = true, minItems = 1, options = { { label = "Unit", value = "unit" }, { label = "Integration", value = "integration" } } },
	{ key = "retries", type = "integer", required = true, minimum = 0, maximum = 3 },
	{ key = "ratio", type = "number", required = true, minimum = 0, maximum = 1 },
	{ key = "confirm", type = "boolean", required = true },
	{ key = "note", type = "string", required = true, when = { { key = "confirm", op = "eq", value = true } } },
	{ key = "hidden", type = "string", hidden = true, required = true, default = "preserved-default" },
}, "Typed keyboard form")
local function tab(field)
	for _ = 1, #item.questions + 1 do
		focus("questions", native.id)
		if item.questions[item.current_tab].key == field then return end
		key("<Tab>")
	end
	error("No field " .. field)
end
local function custom(value)
	key("c"); wait(input.is_visible, "Custom input did not open")
	assert(vim.api.nvim_get_current_win() ~= chat.get_winid(), "Input did not get focus")
	vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { value })
	vim.cmd("stopinsert"); key("<C-g>")
	wait(function() return not input.is_visible() and vim.api.nvim_get_current_win() == chat.get_winid() end, "Input focus did not return")
	focus("questions", native.id)
end
key("2"); tab("checks"); key("1"); key("2")
tab("retries"); custom("2.5")
tab("ratio"); custom("0")
tab("confirm"); key("1"); tab("note"); custom("Черновик 😀")
tab("confirm"); key("2")
assert(forms.get_answers(native.id).note == nil, "Conditional hidden answer leaked")
key("1"); assert(forms.get_answers(native.id).note == "Черновик 😀", "Conditional draft lost")
key("2")
-- Enter validates before opening confirmation and moves to the invalid field.
key("<CR>"); key("<CR>")
assert(item.status == "pending" and item.field_errors.retries, "Fractional integer was accepted")
assert(item.form_selections.retries.custom_input == "2.5" and not item.submitting)
snapshot("form-invalid-integer")
-- Edit the invalid field through input, then review and confirm the answer.
tab("retries"); custom("0")
tab("confirm")
for _ = 1, 2 do if item.status ~= "confirming" then key("<CR>") end end
assert(item.status == "confirming", vim.inspect(item.field_errors))
focus("questions", native.id); key("<CR>")
wait(function() return item.status == "answered" end, "Keyboard form did not settle")
local detail = await(function(cb) client.get_form(created.id, native.id, cb) end)
local expected = { target = "b", checks = { "unit", "integration" }, retries = 0, ratio = 0, confirm = false, hidden = "preserved-default" }
assert(vim.deep_equal(detail.state.answer, expected), vim.inspect(detail))
snapshot("form-answered")

-- JavaScript regex validation belongs to the server; keep a rejected draft editable.
local regex, regex_item = form({ { key = "code", type = "string", required = true, pattern = "^OK-[0-9]+$" } }, "Server validation")
key("c"); wait(input.is_visible, "Regex input did not open")
vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "bad-draft" })
vim.cmd("stopinsert"); key("<C-g>")
wait(function() return regex_item.server_error and not regex_item.submitting end, "Server validation not shown")
assert(regex_item.status == "pending" and regex_item.form_selections.code.custom_input == "bad-draft")
focus("questions", regex.id); snapshot("form-server-error")
key("c"); wait(input.is_visible, "Retry input did not open")
assert(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n") == "bad-draft")
vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "OK-42" })
vim.cmd("stopinsert"); key("<C-g>")
wait(function() return regex_item.status == "answered" end, "Corrected server answer did not settle")

-- A second client answers while a local draft and an SSE interruption exist.
local other, other_item = form({ { key = "text", type = "string", required = true } }, "Second client reply")
forms.set_custom_input(other.id, 1, "unsent local draft")
client.disconnect_events()
state.set_connection("idle") -- Explicit transport shutdown does not emit its failure callback.
local code = second("POST", prefix .. "/form/" .. other.id .. "/reply", { answer = { text = "authoritative second client" } })
assert(code == 204, "Second client reply failed")
assert(client.connect_events())
wait(function() return other_item.status == "answered" end, "Missed remote reply did not recover")
assert(other_item.answers.text == "authoritative second client")
snapshot("form-second-client-recovered")

-- Link dispatch is captured, but completion must still arrive from the server.
local external, external_item = form({ { key = "auth", type = "external", url = url .. "/api/info" } }, "External step")
local original_open, opened = vim.ui.open, nil
vim.ui.open = function(link) opened = link end
key("<CR>"); vim.ui.open = original_open
assert(opened == url .. "/api/info" and external_item.status == "pending")
assert(not forms.begin_submission(external.id, "reply"), "External field submitted locally")
snapshot("form-external-wait")
code = second("DELETE", prefix .. "/form/" .. external.id)
assert(code == 204)
wait(function() return external_item.status == "rejected" end, "External cancellation not reflected")

local permission_results = {}
for _, choice in ipairs({ { "once", 1 }, { "always", 2 }, { "reject", 3 } }) do
	local action = "form_ui_" .. choice[1]
	local request = await(function(cb) client.create_permission(created.id, { action = action, resources = { "fixture-resource" }, save = { "fixture-resource" } }, cb) end)
	assert(request.effect == "ask")
	wait(function() return permissions.get_permission(request.id) end, "Permission event missing")
	focus("permissions", request.id); key(tostring(choice[2])); snapshot("permission-" .. choice[1]); key("<CR>")
	wait(function() return permissions.get_permission(request.id).status ~= "pending" end, "Permission not settled")
	local result = permissions.get_permission(request.id)
	assert(result.status == (choice[1] == "reject" and "rejected" or "approved"), vim.inspect(result))
	local next_request = await(function(cb) client.create_permission(created.id, { action = action, resources = { "fixture-resource" } }, cb) end)
	assert(next_request.effect == (choice[1] == "always" and "allow" or "ask"), vim.inspect(next_request))
	permission_results[choice[1]] = { status = result.status, subsequent_effect = next_request.effect }
	if next_request.effect == "ask" then
		code = second("POST", prefix .. "/permission/" .. next_request.id .. "/reply", { decision = "reject" }); assert(code == 204)
	end
end
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", typed_form = detail, permissions = permission_results,
	second_client_reconnect = true, external_dispatch_only = true, external_cancelled = true,
	conditional_draft = true, invalid_integer_preserved = true, server_validation_retry = true, input_focus_restored = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); require("opencode.lifecycle").disconnect()
print("Native typed forms, second-client recovery and once/always/reject keyboard UI passed")
