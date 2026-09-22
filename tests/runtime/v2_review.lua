-- End-to-end model -> native permission -> custom review -> Lua file action -> RPC.
local client = require("opencode.client")
local state, sync = require("opencode.state"), require("opencode.sync")
local session, events = require("opencode.session"), require("opencode.events")
local permissions, edits = require("opencode.permission.state"), require("opencode.edit.state")
local actions = require("opencode.actions")
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
vim.cmd.cd(vim.fn.fnameescape(directory))
local function await(register)
	local done, result, failure = false
	register(function(err, data) failure, result, done = err, data, true end)
	assert(vim.wait(15000, function() return done end, 10), "HTTP timeout")
	assert(not failure, vim.inspect(failure))
	return result
end
client.setup({ host = host, port = tonumber(port), auth = { username = "opencode", password = "opencode-nvim-test-only" } })
state.set_config(require("opencode.config").merge({ server = { auto_start = false, shared_filesystem = true }, session = { default_agent = "build" } }))
events.setup()
assert(client.connect_events())
assert(vim.wait(5000, client.sse.is_connected, 10))
state.set_connection("connected")
sync.select_catalog_location(directory)
sync.handle_location_catalog(directory, "providers", await(function(cb) client.get_config_providers(cb, { directory = directory }) end))
sync.handle_location_catalog(directory, "agents", await(function(cb) client.list_agents(cb, { directory = directory }) end))
local created = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model }, permissions = {
	{ action = "neovim_edit", resource = "*", effect = "ask" },
} }, cb) end)
session.remember(created); session.set_active(created.id, "Review smoke", { preserve_cache = true })
local path = directory .. "/review.txt"
vim.fn.writefile({ "before" }, path)
local permission_seen, review_id, reply_done = false, nil, false
local prompt = 'Use the neovim_edit tool exactly once to replace "before" with "after" in the existing file ' .. path .. '. Use oldString="before" and newString="after". Do not use any other tool. Wait for the user review. Then reply with one short sentence.'
assert(require("opencode.send").send(prompt, { agent = "build", model = { providerID = provider, id = model } }))
assert(vim.wait(90000, function()
	for _, item in ipairs(permissions.get_all_active()) do
		if item.session_id == created.id and not item.submitting then
			permission_seen = true
			assert(#edits.get_all_active() == 0, "Review appeared before native permission was approved")
			actions.respond_permission(item.permission_id, "once", {}, function(err)
				assert(not err, vim.inspect(err)); permissions.mark_approved(item.permission_id, "once")
			end)
		end
	end
	for _, item in ipairs(edits.get_all_active()) do
		if item.session_id == created.id and item.transport == "review_rpc" and not review_id then
			review_id = item.review_id
			assert(vim.fn.readfile(path)[1] == "before", "Tool wrote before review")
		end
	end
	return review_id ~= nil
end, 20), "Review generation timed out")
assert(permission_seen, "Native tool permission was not observed")
-- Lose SSE/local review state while the server awaits a decision. Recovery must
-- retrieve the exact review before accepting it, without recreating the tool.
client.disconnect_events(); state.set_connection("idle")
assert(not edits.accept_all(review_id), "Disconnected review wrote local files")
assert(vim.fn.readfile(path)[1] == "before")
edits.clear_all()
assert(client.connect_events())
assert(vim.wait(5000, client.sse.is_connected, 10))
state.set_connection("connected")
assert(vim.wait(10000, function() return edits.get_edit(review_id) ~= nil end, 20), "Pending review did not recover")
assert(edits.accept_all(review_id))
actions.respond_permission(review_id, "once", {}, function(err) assert(not err, vim.inspect(err)); reply_done = true end)
assert(vim.wait(90000, function()
	for _, message in ipairs(sync.get_messages(created.id)) do if message.type == "idle" then return true end end
	return false
end, 20), "Recovered review did not finish")
assert(review_id and reply_done, "RPC review did not complete")
assert(vim.fn.readfile(path)[1] == "after", "Accepted file did not change")
local history = await(function(cb) client.get_messages(created.id, {}, cb) end)
local result
for _, message in ipairs(history) do
	for _, part in ipairs(message.parts) do
		if part.type == "tool" and part.tool == "neovim_edit" then result = part.state end
	end
end
assert(result and result.status == "completed", vim.inspect(result))
assert(result.metadata.status == "applied" and result.metadata.wrote == false, vim.inspect(result))
local record = await(function(cb) client.review_rpc("reviewGet", { sessionID = created.id, reviewID = review_id }, directory, cb) end)
assert(record.status == "settled", vim.inspect(record))
local results = { version = "2.0.11", native_permission_first = permission_seen, pending_review_reconnect = true, review = record,
	tool = result, bytes = table.concat(vim.fn.readfile(path, "b"), "\n") }
await(function(cb) client.delete_session(created.id, cb) end)

local function start_case(name, rules)
	local info = await(function(cb) client.create_session({ location = { directory = directory },
		model = { providerID = provider, id = model }, permissions = rules }, cb) end)
	session.remember(info); session.set_active(info.id, name, { preserve_cache = true })
	local target = directory .. "/" .. name .. ".txt"
	vim.fn.writefile({ "before" }, target)
	local text = 'Call neovim_edit exactly once with filePath=' .. vim.json.encode(name .. ".txt")
		.. ', oldString="before", newString="after". Use the direct top-level neovim_edit function, never the execute wrapper or tools.neovim_edit. Do not call any other tool. If permission is denied, stop and reply briefly. Do not retry.'
	assert(require("opencode.send").send(text, { agent = "build", model = { providerID = provider, id = model } }))
	return info.id, target
end
local interrupted, target = start_case("interrupted-review", { { action = "neovim_edit", resource = "*", effect = "allow" } })
local interrupted_record
assert(vim.wait(90000, function()
	for _, item in ipairs(edits.get_all_active()) do
		if item.session_id == interrupted then interrupted_record = item.native_review; return true end
	end
	return false
end, 20), "Interrupt case did not reach review")
await(function(cb) client.abort_session(interrupted, cb) end)
local cancelled
assert(vim.wait(10000, function()
	local item = edits.get_edit(interrupted_record.reviewID)
	cancelled = item and item.native_review
	return cancelled and cancelled.status == "cancelled"
end, 20), "Effect scope did not cancel review")
local late_done, late_error
client.review_rpc("reviewReply", { protocolVersion = 1, sessionID = interrupted, reviewID = cancelled.reviewID,
	revision = cancelled.revision, decisions = { { fileID = cancelled.files[1].fileID, status = "accepted", apply = "server" } },
}, directory, function(err) late_error, late_done = err, true end)
assert(vim.wait(10000, function() return late_done end, 10))
assert(late_error, "Late review reply was accepted after interrupt")
assert(vim.fn.readfile(target)[1] == "before", "Late reply wrote after interrupt")
results.interrupted = { status = cancelled.status, late_error = late_error, bytes = "before\n" }
await(function(cb) client.delete_session(interrupted, cb) end)

local denied_path = directory .. "/denied-review.txt"
local denied, denied_target = start_case("denied-review", {
	{ action = "neovim_edit", resource = "*", effect = "allow" },
	{ action = "neovim_edit", resource = denied_path, effect = "deny" },
})
assert(vim.wait(90000, function()
	for _, item in ipairs(edits.get_all_active()) do assert(item.session_id ~= denied, "Denied tool reached review") end
	for _, message in ipairs(sync.get_messages(denied)) do if message.type == "idle" then return true end end
	return false
end, 20), "Denied case did not finish")
local denied_history = await(function(cb) client.get_messages(denied, {}, cb) end)
local denied_result
for _, message in ipairs(denied_history) do for _, part in ipairs(message.parts) do
	if part.type == "tool" and part.tool == "neovim_edit" then denied_result = part.state end
end end
assert(denied_result and denied_result.status == "error", vim.inspect(denied_result))
assert(tostring(denied_result.error):find("Native permission denied", 1, true), vim.inspect(denied_result))
assert(vim.fn.readfile(denied_target)[1] == "before", "Denied tool wrote to disk")
results.denied = { tool = denied_result, bytes = "before\n" }
await(function(cb) client.delete_session(denied, cb) end)
vim.fn.writefile({ vim.json.encode(results) }, assert(vim.env.OPENCODE_V2_OUTPUT))
client.disconnect_events(); require("opencode.events.handlers.v2").clear()
print("Neovim v2 native permission, review, deny, interruption and late reply passed")
