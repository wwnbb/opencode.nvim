local edits = require("opencode.edit.state")
local app = require("opencode.state")
local client = require("opencode.client")
local actions = require("opencode.actions")
local note = "смешные, можешь еще парочку добавить?\nСохрани мои правки."

describe("review feedback delivery", function()
	local rpc, permission, notify, calls, path, original_open, original_close
	before_each(function()
		app.set_connection("connected")
		app.set_config({ server = { shared_filesystem = false } })
		edits.clear_all()
		rpc, permission, notify = client.review_rpc, client.respond_permission, vim.notify
		calls = {}
		original_open, original_close = io.open, vim.uv.fs_close
		path = vim.fn.tempname()
		vim.notify = function() end
		client.respond_permission = function() error("Review must not use native permission replies") end
		client.review_rpc = function(method, input, directory, callback)
			calls[#calls + 1] = { method = method, input = input, directory = directory, callback = callback }
		end
	end)
	after_each(function()
		io.open, vim.uv.fs_close = original_open, original_close
		vim.wait(20, function() return false end, 10)
		client.review_rpc, client.respond_permission, vim.notify = rpc, permission, notify
		edits.clear_all()
		require("opencode.artifact.changes").clear()
		app.reset()
		vim.fn.delete(path)
		vim.fn.delete(path .. ".target")
	end)

	local function add(path, kind)
		local item = edits.add_edit("r", "s", {
			{ fileID = "f", filePath = path, before = "before\n", after = kind == "delete" and "" or "after\n", type = kind or "update" },
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
		local delivered
		assert.is_true(actions.reply_review("r", function(err, record)
			assert.is_nil(err)
			delivered = record
		end))
		edits.set_review_record({ reviewID = "r", sessionID = "s", revision = 1, status = "settled",
			message = note, outcome = { review_message = note } })
		calls[1].callback(nil, { reviewID = "r", sessionID = "s", revision = 1, status = "decided" })
		assert.equals("settled", item.native_review.status)
		assert.equals(note, item.message)
		assert.same(item.native_review, delivered)
	end)

	for _, failed in ipairs({ false, true }) do
		it("reports cancellation before a late " .. (failed and "failed" or "successful") .. " RPC response", function()
			local item = add(path)
			local failure, delivered
			assert.is_true(actions.reply_review("r", function(err, record) failure, delivered = err, record end))
			assert.is_true(edits.set_review_record({ reviewID = "r", sessionID = "s", revision = 1, status = "cancelled" }))
			calls[1].callback(failed and { message = "Late RPC failure" } or nil,
				{ reviewID = "r", sessionID = "s", revision = 1, status = "decided" })
			assert.is_not_nil(failure)
			assert.is_truthy(failure.message:find("cancelled", 1, true))
			assert.same(item.native_review, delivered)
			assert.equals("cancelled", item.native_review.status)
			assert.is_false(item.submitting)
			assert.equals(note, item.message)
		end)

		it("ignores a scheduled " .. (failed and "failure" or "finalizer") .. " after its review owner changes", function()
			add(path)
			local notices = {}
			vim.notify = function(message) notices[#notices + 1] = message end
			assert.is_true(require("opencode.ui.chat.edits").finalize_edit("r"))
			calls[1].callback(failed and { message = "Late RPC failure" } or nil,
				{ reviewID = "r", sessionID = "s", revision = 1, status = "decided" })
			edits.clear_all()
			local replacement = add(path)
			vim.wait(20, function() return false end, 10)
			assert.equals("pending", replacement.status)
			assert.same({}, notices)
		end)
	end

	it("does not notify a queued reply error after its session was invalidated", function()
		add(path)
		local notices = {}
		vim.notify = function(message) notices[#notices + 1] = message end
		assert.is_true(require("opencode.ui.chat.edits").finalize_edit("r"))
		calls[1].callback({ message = "Old request failed" })
		require("opencode.session.pending").clear_session("s")
		vim.wait(20)
		assert.same({}, notices)
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

	local function local_review(kind)
		app.set_config({ server = { shared_filesystem = true } })
		vim.fn.writefile({ "before" }, path)
		return add(path, kind)
	end

	it("restores submission and preserves feedback when closing the observed file fails", function()
		local item = local_review()
		vim.uv.fs_close = function(fd)
			original_close(fd)
			return nil, "temporary observation close failure"
		end
		io.open = function(name, mode)
			local handle, err = original_open(name, mode)
			if name ~= path or mode ~= "rb" or not handle then return handle, err end
			return { read = function(_, ...) return handle:read(...) end, close = function()
				handle:close()
				return nil, "temporary observation close failure"
			end }
		end
		local failure
		assert.is_false(actions.reply_review("r", function(err) failure = err end))
		assert.equals(0, #calls)
		assert.equals("temporary observation close failure", failure.message)
		assert.equals("pending", item.status)
		assert.is_false(item.submitting)
		assert.equals(note, item.message)
		io.open, vim.uv.fs_close = original_open, original_close
		assert.is_true(actions.reply_review("r"))
		assert.equals(1, #calls)
		assert.equals(note, calls[1].input.message)
	end)

	it("does not confirm bytes from a symbolic link substituted after acceptance", function()
		local item = local_review()
		local target = path .. ".target"
		vim.fn.writefile({ "after" }, target)
		assert(vim.uv.fs_unlink(path))
		assert(vim.uv.fs_symlink(target, path))
		local failure
		assert.is_false(actions.reply_review("r", function(err) failure = err end))
		assert.equals(0, #calls)
		assert.is_truthy(failure.message:find("link", 1, true))
		assert.is_false(item.submitting)
		assert.equals("pending", item.status)
		assert.equals("link", vim.uv.fs_lstat(path).type)
	end)

	it("confirms complete bytes including BOM, CRLF and an empty file", function()
		for _, bytes in ipairs({ "after\n", "\239\187\191after\r\n", "" }) do
			edits.clear_all()
			local_review()
			local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
			assert.is_true(actions.reply_review("r"))
			assert.same({ exists = true, sha256 = vim.fn.sha256(bytes) }, calls[#calls].input.decisions[1].observed)
		end
	end)

	it("confirms absence after accepting a deletion", function()
		local_review("delete")
		assert.is_nil(vim.uv.fs_stat(path))
		assert.is_true(actions.reply_review("r"))
		assert.same({ exists = false }, calls[1].input.decisions[1].observed)
	end)

end)

describe("review feedback in tool history", function()
	local sync = require("opencode.sync")
	before_each(function() edits.clear_all(); sync.clear_all() end)
	after_each(function() edits.clear_all(); sync.clear_all() end)

	for _, name in ipairs({ "neovim_patch", "neovim_edit" }) do
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

	it("renders a historical patch call as a generic tool without review controls", function()
		sync.handle_message_updated({ id = "m", sessionID = "s", role = "assistant", time = { created = 1 } })
		local part = { id = "p", messageID = "m", sessionID = "s", type = "tool", tool = "neovim_apply_patch",
			callID = "c", state = { status = "completed", input = { patchText = "*** Begin Patch" },
				output = "Historical patch result", metadata = { files = { { filePath = "/history/a" } } } } }
		sync.handle_part_updated(part)
		assert.equals(0, require("opencode.ui.chat.edit_previews").sync_session("s"))
		assert.is_nil(edits.get_edit("tool-preview:s:m:p"))
		local rendered = require("opencode.ui.chat.tasks").render_regular_tool(part, true)
		assert.is_truthy(table.concat(rendered.lines, "\n"):find("neovim_apply_patch", 1, true))
	end)
end)

describe("review protocol 2 events", function()
	for _, reconnect in ipairs({ false, true }) do
		it("retries a policy interrupted by " .. (reconnect and "connection invalidation" or "closing its session"), function()
			local handlers, lookups, confirmations = {}, {}, {}
			local get, create, rpc = client.get_permission, client.create_permission, client.review_rpc
			local pending = require("opencode.session.pending")
			app.reset(); pending.clear_all()
			app.set_session("policy-session", "Policy")
			client.get_permission = function(_, _, callback) lookups[#lookups + 1] = callback end
			client.create_permission = function(_, _, callback) callback(nil, { effect = "allow" }) end
			client.review_rpc = function(method, _, _, callback)
				assert.equals("policyConfirm", method)
				confirmations[#confirmations + 1] = callback
			end
			local ok, err = pcall(function()
				require("opencode.events.handlers.review_v2").setup({ emit = function() end,
					on = function(kind, callback) handlers[kind] = callback end })
				local event = { type = "rpc.opencode_nvim.policyRequested", data = { policy = {
					protocolVersion = 2, sessionID = "policy-session", status = "pending", gateID = "gate",
					location = { directory = "/policy" }, request = { id = "permission", action = "neovim_edit" },
				} } }
				handlers.v2_interaction(event)
				handlers.v2_interaction(event)
				assert.equals(1, #lookups)
				if reconnect then pending.invalidate() else pending.clear_session("policy-session") end
				handlers.v2_interaction(event)
				assert.equals(2, #lookups)
				lookups[1]({ status = 404 })
				assert.equals(0, #confirmations)
				lookups[2]({ status = 404 })
				assert.equals(1, #confirmations)
				confirmations[1](nil, { status = "allowed" })
				handlers.v2_interaction(event)
				assert.equals(2, #lookups)
			end)
			client.get_permission, client.create_permission, client.review_rpc = get, create, rpc
			app.reset(); pending.clear_all()
			assert.is_true(ok, err)
		end)
	end

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
