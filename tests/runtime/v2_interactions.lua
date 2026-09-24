local client = require("opencode.client")
local state = require("opencode.state")
local forms = require("opencode.question.state")
local permissions = require("opencode.permission.state")
local session = require("opencode.session")
local events = require("opencode.events")
local actions = require("opencode.actions")
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
vim.cmd.cd(vim.fn.fnameescape(directory))
local function await(register)
	local done, result, failure = false
	register(function(err, data) failure, result, done = err, data, true end)
	assert(vim.wait(15000, function() return done end, 10), "HTTP timeout")
	assert(not failure, vim.inspect(failure))
	return result
end
client.setup({ host = host, port = tonumber(port), auth = { username = "opencode", password = "opencode-nvim-test-only" } })
local server_info = await(function(cb) client.health(cb) end)
state.set_config(require("opencode.config").merge({ server = { auto_start = false } }))
events.setup()
assert(client.connect_events())
assert(vim.wait(5000, client.sse.is_connected, 10), "SSE connection timeout")
local created = await(function(cb) client.create_session({ location = { directory = directory }, permissions = {
	{ action = "fixture", resource = "*", effect = "ask" },
} }, cb) end)
session.remember(created)
session.set_active(created.id, "Interaction smoke", { preserve_cache = true })
local prefix = "/api/session/" .. created.id
local native = await(function(cb) client.http.post(prefix .. "/form", { title = "Runtime form", fields = {
	{ key = "zero", type = "integer", required = true, minimum = 0 },
	{ key = "false", type = "boolean", required = true },
	{ key = "choice", type = "string", options = { { label = "Same", value = "a" }, { label = "Same", value = "b" } } },
} }, cb) end).data
assert(vim.wait(5000, function() return forms.get_question(native.id) ~= nil end, 10), "Missing form SSE")
local item = forms.get_question(native.id)
assert(item.message_id == nil, "Unlinked form must remain a session widget")
forms.set_custom_input(native.id, 1, "0")
forms.set_tab(native.id, 2); forms.select_option(native.id, 2)
forms.set_tab(native.id, 3); forms.select_option(native.id, 2)
local answer = forms.get_answers(native.id)
assert(vim.deep_equal(answer, { zero = 0, ["false"] = false, choice = "b" }), vim.inspect(answer))
-- Switch active session before replying; routing must remain captured.
local other = await(function(cb) client.create_session({ location = { directory = directory } }, cb) end)
session.remember(other); session.set_active(other.id, "Other", { preserve_cache = true })
await(function(cb) actions.reply_to_question(native.id, answer, cb) end)
assert(vim.wait(5000, function() return item.status == "answered" end, 10), "Missing form settlement")
local detail = await(function(cb) client.get_form(created.id, native.id, cb) end)
assert(vim.deep_equal(detail.state.answer, answer), vim.inspect(detail))
local requested = await(function(cb) client.http.post(prefix .. "/permission", { action = "fixture", resources = { "fixture-resource" } }, cb) end).data
assert(requested.effect == "ask", vim.inspect(requested))
assert(vim.wait(5000, function() return permissions.get_permission(requested.id) ~= nil end, 10), "Missing permission SSE")
local pstate = permissions.get_permission(requested.id)
assert(pstate.session_id == created.id and pstate.transport == "permission")
-- Actions normally settles through the widget callback; SSE can win that race
-- and intentionally suppress a stale callback, so observe authoritative state.
actions.respond_permission(requested.id, "once", {}, function(err)
	assert(not err, vim.inspect(err)); permissions.mark_approved(requested.id, "once")
end)
assert(vim.wait(5000, function() return pstate.status == "approved" end, 10), "Missing permission settlement")
local cancel = await(function(cb) client.http.post(prefix .. "/form", { title = "Cancel me", fields = {
	{ key = "text", type = "string" },
} }, cb) end).data
assert(vim.wait(5000, function() return forms.get_question(cancel.id) ~= nil end, 10))
await(function(cb) actions.reject_question(created.id, cancel.id, cb) end)
assert(vim.wait(5000, function() return forms.get_question(cancel.id).status == "rejected" end, 10))
vim.fn.writefile({ vim.json.encode({ version = server_info.version, typed_form = true, owner_routing = true, permission_once = true, form_cancel = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
await(function(cb) client.delete_session(created.id, cb) end)
await(function(cb) client.delete_session(other.id, cb) end)
client.disconnect_events()
require("opencode.events.handlers.v2").clear()
print("Neovim v2 interaction smoke passed")
