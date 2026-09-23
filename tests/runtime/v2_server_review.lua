-- External-server mode: the frontend never applies the file itself.
local app, client = require("opencode"), require("opencode.client")
local state, sync, lifecycle = require("opencode.state"), require("opencode.sync"), require("opencode.lifecycle")
local session, edits, chat = require("opencode.session"), require("opencode.edit.state"), require("opencode.ui.chat")
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
local path = directory .. "/server-reviewed.txt"
vim.fn.writefile({ "before" }, path)
local function bytes() return table.concat(vim.fn.readfile(path, "b"), "\n") end
local info = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model },
	permissions = { { action = "neovim_edit", resource = "*", effect = "allow" } } }, cb) end)
session.remember(info); session.set_active(info.id, "Server apply review", { preserve_cache = true }); chat.open()
assert(require("opencode.send").send('Call the direct top-level neovim_edit tool exactly once with path="server-reviewed.txt", oldString="before", newString="after". Do not use execute or any other tool. Wait for review then reply briefly.', {}))
local review
wait(function()
	for _, item in ipairs(edits.get_all_active()) do if item.session_id == info.id then review = item; return true end end
end, "Server review missing", 100000)
assert(review.apply_mode == "server" and bytes() == "before\n")
assert(not edits.resolve_file(review.review_id, 1), "External review allowed manual filesystem access")
chat.do_render()
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw"); vim.rpcnotify(1, "opencode_screenshot", "server-review-pending") end
assert(edits.accept_all(review.review_id))
assert(bytes() == "before\n", "Frontend wrote external review bytes")
await(function(cb) assert(require("opencode.review").reply(review.review_id, cb)) end)
wait(function()
	for _, message in ipairs(sync.get_messages(info.id)) do if message.type == "idle" then return true end end
end, "Server review did not finish", 100000)
assert(bytes() == "after\n")
local record = await(function(cb) client.review_rpc("reviewGet", { sessionID = info.id, reviewID = review.review_id }, directory, cb) end)
assert(record.status == "settled" and record.outcome.wrote == true)
assert(record.decisions[1].apply == "server" and record.decisions[1].observed == nil)
vim.fn.writefile({ "external after settlement" }, path)
local duplicate = await(function(cb) client.review_rpc("reviewReply", { protocolVersion = 2, sessionID = info.id, reviewID = review.review_id,
	revision = record.revision, decisions = record.decisions }, directory, cb) end)
assert(duplicate.status == "settled" and bytes() == "external after settlement\n", "Duplicate reply reapplied the proposal")
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", before = "before\n", after = "after\n", duplicate_bytes = bytes(),
	frontend_did_not_write = true, manual_blocked = true, review = record }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("External-server review apply and duplicate reply preservation passed")
