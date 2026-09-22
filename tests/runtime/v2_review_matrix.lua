-- Real bundled patch tool, attached UI, mixed decisions and native manual diff.
local app, client = require("opencode"), require("opencode.client")
local state, sync, chat = require("opencode.state"), require("opencode.sync"), require("opencode.ui.chat")
local session, edits, lifecycle = require("opencode.session"), require("opencode.edit.state"), require("opencode.lifecycle")
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
local function write(name, bytes) local f = assert(io.open(directory .. "/" .. name, "wb")); f:write(bytes); f:close() end
local function read(name) local f = io.open(directory .. "/" .. name, "rb"); if not f then return false end; local bytes = f:read("*a"); f:close(); return bytes end
local function snapshot(name)
	vim.cmd("redraw")
	if vim.env.OPENCODE_V2_ATTACHED_UI then vim.rpcnotify(1, "opencode_screenshot", name) end
end
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	shared_filesystem = true, config_dir = vim.env.OPENCODE_CONFIG_DIR,
	auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } },
	chat = { width = 80, close_on_focus_lost = false }, lualine = { enabled = false } })
lifecycle.ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "Catalogs unavailable")
local before = { ["accepted.txt"] = "before\n", ["rejected.txt"] = "before\n", ["manual.txt"] = "before\n",
	["deleted.txt"] = "delete me\n", ["moved.txt"] = "move me\n", ["bom.txt"] = "\239\187\191before\r\n" }
for name, bytes in pairs(before) do write(name, bytes) end
local patch = [[*** Begin Patch
*** Update File: accepted.txt
@@
-before
+after
*** Update File: rejected.txt
@@
-before
+after
*** Update File: manual.txt
@@
-before
+after
*** Add File: added.txt
+new file
*** Delete File: deleted.txt
*** Update File: moved.txt
*** Move to: renamed.txt
@@
-move me
+moved
*** Update File: bom.txt
@@
-before
+after
*** End Patch]]
local info = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model },
	permissions = { { action = "neovim_apply_patch", resource = "*", effect = "allow" } } }, cb) end)
session.remember(info); session.set_active(info.id, "Mixed patch review", { preserve_cache = true }); chat.open(); chat.focus()
assert(require("opencode.send").send("Call the direct top-level neovim_apply_patch function exactly once with the following patchText. Do not call execute or any other tool. Wait for the review decision, then reply briefly.\n" .. patch, {}))
local review
wait(function()
	for _, item in ipairs(edits.get_all_active()) do if item.session_id == info.id then review = item; return true end end
end, "Patch did not reach review", 100000)
assert(review.apply_mode == "client" and #review.files == 8, vim.inspect(review))
local index = {}
for i, file in ipairs(review.files) do index[vim.fn.fnamemodify(file.filepath, ":t")] = i end
for name, bytes in pairs(before) do assert(read(name) == bytes, "Proposal wrote " .. name) end
chat.do_render(); snapshot("review-pending")
local view = require("opencode.ui.chat.state").state
local function select_file(name)
	chat.focus(); chat.do_render()
	local pos = assert(view.edits[review.review_id])
	for _, range in ipairs(pos.meta.file_ranges) do if range.index == index[name] then
		vim.api.nvim_win_set_cursor(view.winid, { pos.start_line + range.start_line + 1, 0 })
		require("opencode.ui.chat.edits").sync_selected_file_from_cursor()
		assert(review.selected_file == index[name], "Wrong file selected by cursor")
		return
	end end
	error("File has no rendered range")
end
select_file("manual.txt")
local chat_width = vim.api.nvim_win_get_width(view.winid)
local split = vim.fn.maparg("dv", "n", false, true)
assert(type(split.callback) == "function", "dv keymap missing"); split.callback()
local actual = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_name(actual) == directory .. "/manual.txt", "Diff did not focus actual file")
vim.api.nvim_buf_set_lines(actual, 0, -1, false, { "manual result" })
local confirm = vim.fn.maparg("<C-a>", "n", false, true)
assert(type(confirm.callback) == "function", "Diff confirmation unavailable")
client.disconnect_events(); state.set_connection("idle")
confirm.callback()
assert(read("manual.txt") == "before\n", "Offline diff confirmation wrote to disk")
assert(vim.bo[actual].modified, "Offline confirmation lost manual buffer")
assert(client.connect_events()); wait(state.is_connected, "Review reconnect failed")
snapshot("review-native-diff")
confirm.callback()
assert(read("manual.txt") == "manual result\n" and review.files[index["manual.txt"]].status == "resolved")
assert(vim.api.nvim_win_get_width(view.winid) == chat_width, "Closing diff changed chat layout")
assert(#vim.fn.win_findbuf(actual) > 0, "Closing diff removed the actual file window")
select_file("rejected.txt")
local reject = vim.fn.maparg("<C-x>", "n", false, true)
assert(type(reject.callback) == "function"); reject.callback()
assert(read("rejected.txt") == "before\n")
-- A byte-only external change must survive acceptance too.
write("bom.txt", "\239\187\191before\n")
for _, name in ipairs({ "accepted.txt", "added.txt", "deleted.txt", "moved.txt", "renamed.txt", "bom.txt" }) do
	assert(edits.accept_file(review.review_id, index[name]))
end
await(function(cb) assert(require("opencode.review").reply(review.review_id, cb)) end)
wait(function()
	for _, message in ipairs(sync.get_messages(info.id)) do if message.type == "idle" then return true end end
end, "Mixed review did not finish", 100000)
local expected = { ["accepted.txt"] = "after\n", ["rejected.txt"] = "before\n", ["manual.txt"] = "manual result\n",
	["added.txt"] = "new file\n", ["deleted.txt"] = false, ["moved.txt"] = false, ["renamed.txt"] = "moved\n", ["bom.txt"] = "\239\187\191before\n" }
for name, bytes in pairs(expected) do assert(read(name) == bytes, "Wrong final bytes for " .. name .. ": " .. vim.inspect(read(name))) end
local history = await(function(cb) client.get_all_messages(info.id, cb) end)
local tool
for _, message in ipairs(history) do for _, part in ipairs(message.parts) do
	if part.type == "tool" and part.tool == "neovim_apply_patch" then tool = part.state end
end end
assert(tool and tool.status == "completed" and tool.metadata.status == "partial", vim.inspect(tool))
chat.do_render(); chat.focus(); snapshot("review-settled")
local record = await(function(cb) client.review_rpc("reviewGet", { sessionID = info.id, reviewID = review.review_id }, directory, cb) end)
assert(record.status == "settled")
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", before = before, after = expected, review = record, tool = tool,
	manual_diff_keymap = true, offline_diff_preserves_buffer = true, rejected_keymap = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Mixed patch, manual native diff, offline buffer safety and exact final bytes passed")
