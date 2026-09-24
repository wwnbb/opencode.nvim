-- Three real projects/sessions while HTTP/SSE callbacks are in flight.
local app, client = require("opencode"), require("opencode.client")
local state, sync, lifecycle = require("opencode.state"), require("opencode.sync"), require("opencode.lifecycle")
local session, chat, actions = require("opencode.session"), require("opencode.ui.chat"), require("opencode.actions")
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
local sessions = {}
for i = 1, 3 do
	local project = directory .. "/scope " .. i
	vim.fn.mkdir(project, "p")
	assert(vim.system({ "git", "init", "--quiet", project }):wait().code == 0)
	local info = await(function(cb) client.create_session({ location = { directory = project }, model = { providerID = provider, id = model },
		permissions = { { action = "scope_fixture", resource = "*", effect = "ask" } } }, cb) end)
	sessions[i] = info; session.remember(info); session.set_active(info.id, "Scope " .. i, { preserve_cache = true })
	assert(require("opencode.send").send("Return exactly SCOPE_REPLY_" .. i .. " in chat. Do not use tools or create files.",
		{ session_id = info.id, model = { providerID = provider, id = model }, agent = "build" }))
end
chat.open(); chat.focus()
-- All sends are pending while the selected project keeps changing.
for _, i in ipairs({ 1, 3, 2, 1, 3 }) do session.switch_to(sessions[i]); vim.wait(40, function() return false end, 10) end
wait(function()
	for _, info in ipairs(sessions) do
		local idle = false
		for _, message in ipairs(sync.get_messages(info.id)) do if message.type == "idle" then idle = true end end
		if not idle then return false end
	end
	return true
end, "Concurrent sessions did not finish", 180000)
local histories = {}
for i, info in ipairs(sessions) do
	assert(state.get_session_directory(info.id) == info.location.directory)
	assert(sync.get_location_catalog(info.location.directory, "providers"), "Missing scoped catalog")
	local history = await(function(cb) client.get_all_messages(info.id, cb) end)
	histories[i] = history
	local users, answer = 0, ""
	for _, message in ipairs(history) do
		if message.info.role == "user" then users = users + 1 end
		if message.info.role == "assistant" then for _, part in ipairs(message.parts) do if part.type == "text" then answer = answer .. part.text end end end
	end
	assert(users == 1 and answer:find("SCOPE_REPLY_" .. i, 1, true), "Wrong reply in session " .. i)
	for j = 1, 3 do if j ~= i then assert(not answer:find("SCOPE_REPLY_" .. j, 1, true), "Cross-project answer leak") end end
	session.switch_to(info); chat.do_render()
	local text = table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n")
	assert(text:find("SCOPE_REPLY_" .. i, 1, true), "Wrong active buffer")
	for j = 1, 3 do if j ~= i then assert(not text:find("SCOPE_REPLY_" .. j, 1, true), "Cross-project buffer leak") end end
end
local owner, active = sessions[1], sessions[3]
local request = await(function(cb) client.create_permission(owner.id, { action = "scope_fixture", resources = { owner.location.directory } }, cb) end)
assert(request.effect == "ask")
local permissions = require("opencode.permission.state")
wait(function() return permissions.get_permission(request.id) end, "Background permission missing")
assert(state.get_session().id == active.id, "Background permission switched active tab")
actions.respond_permission(request.id, "once", {}, function(err) assert(not err, vim.inspect(err)) end)
wait(function() return permissions.get_permission(request.id).status == "approved" end, "Permission did not settle in its owning session")
chat.do_render()
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw"); vim.rpcnotify(1, "opencode_screenshot", "three-project-sessions") end
-- Hold a genuine HTTP history response, delete its session, then release it.
local original_get, delayed = client.http.get, nil
client.http.get = function(path, callback, opts)
	if path == "/api/session/" .. owner.id .. "/message" then
		return original_get(path, function(err, data, meta) delayed = function() callback(err, data, meta) end end, opts)
	end
	return original_get(path, callback, opts)
end
actions.load_session_messages(owner.id, function() error("Deleted session callback was not invalidated") end)
wait(function() return delayed ~= nil end, "Did not capture delayed history")
client.http.get = original_get
await(function(cb) client.delete_session(owner.id, cb) end)
wait(function() return state.get_session_record(owner.id) == nil end, "Deleted session remained in state")
delayed(); vim.wait(100, function() return false end, 10)
assert(state.get_session_record(owner.id) == nil and #sync.get_messages(owner.id) == 0, "Stale HTTP resurrected deleted session")
assert(state.get_session().id == active.id, "Deleting background session changed active tab")
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", sessions = sessions, histories = histories,
	three_projects = true, owner_permission = true, stale_deleted_callback_ignored = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Three-project send/selection/permission isolation and deleted-session HTTP race passed")
