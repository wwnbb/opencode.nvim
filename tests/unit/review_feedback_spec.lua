local edits = require("opencode.edit.state")
local app = require("opencode.state")
local client = require("opencode.client")
local actions = require("opencode.actions")
local note = "смешные, можешь еще парочку добавить?\nСохрани мои правки."

describe("review feedback delivery", function()
	local rpc, permission, notify, calls, path
	before_each(function()
		app.set_connection("connected")
		app.set_config({ server = { shared_filesystem = false } })
		edits.clear_all()
		rpc, permission, notify = client.review_rpc, client.respond_permission, vim.notify
		calls = {}
		path = vim.fn.tempname()
		vim.notify = function() end
		client.respond_permission = function() error("Review must not use native permission replies") end
		client.review_rpc = function(method, input, directory, callback)
			calls[#calls + 1] = { method = method, input = input, directory = directory, callback = callback }
		end
	end)
	after_each(function()
		vim.wait(20, function() return false end, 10)
		client.review_rpc, client.respond_permission, vim.notify = rpc, permission, notify
		edits.clear_all()
		require("opencode.artifact.changes").clear()
		app.reset()
		vim.fn.delete(path)
	end)

	local function add(path)
		local item = edits.add_edit("r", "s", {
			{ fileID = "f", filePath = path, before = "before\n", after = "after\n", type = "update" },
		}, { transport = "review_rpc", revision = 1, location = { directory = "/server" }, native_review = { status = "pending" } })
		assert.is_true(edits.set_message("r", "  " .. note .. "  "))
		assert.is_true(edits.accept_all("r"))
		return item
	end

	it("routes widget confirmation through review RPC with the note and freezes submission", function()
		local item = add(path)
		assert.is_true(require("opencode.ui.chat.edits").finalize_edit("r"))
		assert.equals(1, #calls)
		assert.equals("reviewReply", calls[1].method)
		assert.equals("/server", calls[1].directory)
		assert.same({ protocolVersion = 2, sessionID = "s", reviewID = "r", revision = 1, message = note,
			decisions = { { fileID = "f", status = "accepted", apply = "server" } } }, calls[1].input)
		assert.is_false(edits.set_message("r", "too late"))
		assert.is_false(actions.reply_review("r"))
		assert.equals(1, #calls)
		calls[1].callback(nil, { reviewID = "r", sessionID = "s", revision = 1, status = "decided",
			message = note, decisions = calls[1].input.decisions })
		assert.equals("sent", item.status)
		assert.equals(note, item.message)
	end)

	it("preserves feedback on RPC failure and retries the same payload", function()
		local item = add(path)
		assert.is_true(actions.reply_review("r"))
		calls[1].callback({ message = "Connection lost" })
		assert.equals("pending", item.status)
		assert.is_false(item.submitting)
		assert.equals(note, item.message)
		assert.is_true(actions.reply_review("r"))
		assert.same(calls[1].input, calls[2].input)
	end)

	it("keeps terminal feedback if its HTTP response arrives after the settled event", function()
		local item = add(path)
		assert.is_true(actions.reply_review("r"))
		edits.set_review_record({ reviewID = "r", sessionID = "s", revision = 1, status = "settled",
			message = note, outcome = { review_message = note } })
		calls[1].callback(nil, { reviewID = "r", sessionID = "s", revision = 1, status = "decided" })
		assert.equals("settled", item.native_review.status)
		assert.equals(note, item.message)
	end)

	it("does not send reviews while disconnected or through permission APIs", function()
		add(path)
		local err
		assert.is_false(actions.respond_permission("r", "once", {}, function(value) err = value end))
		assert.is_truthy(err.message:find("reply_review", 1, true))
		app.set_connection("idle")
		assert.is_false(actions.reply_review("r"))
		assert.equals(0, #calls)
	end)
end)

describe("review feedback in tool history", function()
	local sync = require("opencode.sync")
	before_each(function() edits.clear_all(); sync.clear_all() end)
	after_each(function() edits.clear_all(); sync.clear_all() end)

	for _, name in ipairs({ "neovim_patch", "neovim_apply_patch", "neovim_edit" }) do
		it("restores preview and feedback for " .. name, function()
			local file = { filePath = "/history/a", relativePath = "a", before = "before\n", after = "manual\n",
				type = "update", status = "partial", additions = 1, deletions = 1,
				diff = "--- a\n+++ a\n@@ -1 +1 @@\n-before\n+manual" }
			sync.handle_message_updated({ id = "m", sessionID = "s", role = "assistant", time = { created = 1 } })
			sync.handle_part_updated({ id = "p", messageID = "m", sessionID = "s", type = "tool", tool = name,
				callID = "c", state = { status = "completed", output = "Done", metadata = {
					status = "partial", files = { file }, filediff = file, review_message = note,
				} } })
			assert.equals(1, require("opencode.ui.chat.edit_previews").sync_session("s"))
			local item = edits.get_edit("tool-preview:s:m:p")
			assert.is_not_nil(item)
			assert.equals("readonly", item.review_mode)
			assert.equals(note, item.message)
			assert.equals("manual\n", item.files[1].after)
			local lines = require("opencode.ui.edit_widget").get_resolved_lines(item.permission_id, item)
			assert.is_truthy(table.concat(lines, "\n"):find("смешные", 1, true))
		end)
	end
end)

describe("review protocol 2 events", function()
	it("handles policy authorization and review settlement using the new protocol", function()
		local methods, handlers = {}, {}
		local rpc, get, create = client.review_rpc, client.get_permission, client.create_permission
		local events = { emit = function() end, on = function(kind, callback) handlers[kind] = callback end }
		app.reset(); edits.clear_all()
		app.upsert_session({ id = "s", directory = "/server" })
		require("opencode.session").set_active("s", "Review")
		client.get_permission = function(_, _, callback) callback({ status = 404 }) end
		client.create_permission = function(_, request, callback)
			assert.equals("neovim_patch", request.action)
			callback(nil, { effect = "allow" })
		end
		client.review_rpc = function(method, _, _, callback)
			methods[#methods + 1] = method
			callback(nil, { status = "allowed" })
		end
		local ok, err = pcall(function()
			require("opencode.events.handlers.review_v2").setup(events)
			handlers.v2_interaction({ type = "rpc.opencode_nvim.policyRequested", data = { policy = {
				protocolVersion = 2, status = "pending", sessionID = "s", gateID = "gate",
				location = { directory = "/server" }, request = { id = "per", action = "neovim_patch" },
			} } })
			assert.same({ "policyConfirm" }, methods)
			local record = { protocolVersion = 2, status = "pending", sessionID = "s", reviewID = "r",
				revision = 1, created = 1000, messageID = "m", callID = "c", location = { directory = "/server" },
				files = { { fileID = "f", filePath = "/server/a", type = "update", before = "before", after = "after" } } }
			handlers.v2_interaction({ type = "rpc.opencode_nvim.reviewCreated", data = { review = record } })
			assert.equals("pending", edits.get_edit("r").status)
			local settled = vim.tbl_extend("force", record, { status = "settled", message = note,
				decisions = { { fileID = "f", status = "accepted" } }, outcome = { review_message = note } })
			handlers.v2_interaction({ type = "rpc.opencode_nvim.reviewSettled", data = { review = settled } })
			assert.equals(note, edits.get_edit("r").message)
			assert.equals("sent", edits.get_edit("r").status)
			handlers.v2_interaction({ type = "rpc.opencode_nvim.reviewCreated", data = { review = record } })
			assert.equals("sent", edits.get_edit("r").status)
		end)
		client.review_rpc, client.get_permission, client.create_permission = rpc, get, create
		edits.clear_all(); require("opencode.artifact.changes").clear(); app.reset()
		assert.is_true(ok, err)
	end)
end)
