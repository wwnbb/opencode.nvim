local actions = require("opencode.actions")
local history = require("opencode.ui.input.history")
local input = require("opencode.ui.input")
local pending = require("opencode.session.pending")
local projection = require("opencode.protocol.v2.messages")
local slash = require("opencode.slash")
local state = require("opencode.state")
local sync = require("opencode.sync")

describe("session undo and redo", function()
	local saved, old_notify, old_schedule, old_client_cancel, stages, cancellations

	local function run(name)
		assert.is_true(slash.execute(slash.parse("/" .. name)))
	end

	local function delivered_turns()
		sync.handle_session_messages("s", projection.page("s", {
			{ id = "msg_0001", type = "user", text = "First", time = { created = 1 } },
			{ id = "msg_0002", type = "assistant", content = { { type = "text", text = "One" } }, time = { created = 2 } },
			{ id = "msg_0003", type = "user", text = "Second", time = { created = 3 } },
			{ id = "msg_0004", type = "assistant", content = { { type = "text", text = "Two" } }, time = { created = 4 } },
			{ id = "msg_0005", type = "user", text = "Third [File 1] @explore @review", time = { created = 5 },
				files = { { source = { type = "uri", uri = "file:///tmp/context.txt" },
					name = "context.txt", mime = "text/plain", data = "Y29udGV4dA==",
					mention = { start = 6, ["end"] = 14, text = "[File 1]" } } },
				agents = { { name = "explore", mention = { start = 15, ["end"] = 23, text = "@explore" } } },
				skills = { { id = "review", mention = { start = 24, ["end"] = 31, text = "@review" } } } },
			{ id = "msg_0006", type = "assistant", content = { { type = "text", text = "Three" } }, time = { created = 6 } },
		}))
	end

	before_each(function()
		input.close(false)
		state.reset(); sync.clear_all(); pending.clear_all(); history.clear_pending()
		state.set_session("s", "Test")
		slash.register_defaults()
		old_notify, old_schedule = vim.notify, vim.schedule
		old_client_cancel = require("opencode.client").cancel_input
		vim.notify = function() end
		vim.schedule = function(callback) callback() end
		saved = {
			revert_message = actions.revert_message,
			undo_message = actions.undo_message or false,
			clear_revert = actions.clear_revert,
			cancel_pending_input = actions.cancel_pending_input,
			cancel_submitting_input = actions.cancel_submitting_input or false,
		}
		stages, cancellations = {}, {}
		local function stage(session_id, message_id, callback, opts)
			stages[#stages + 1] = { session_id = session_id, message_id = message_id, opts = opts }
			state.upsert_session({ id = session_id, revert = { messageID = message_id } })
			callback(nil)
		end
		actions.revert_message = function(session_id, message_id, opts, callback)
			stage(session_id, message_id, callback, opts)
		end
		actions.undo_message = function(session_id, message_id, callback)
			stage(session_id, message_id, callback)
		end
		actions.clear_revert = function(session_id, callback)
			state.upsert_session({ id = session_id, revert = vim.NIL })
			callback(nil)
		end
		actions.cancel_pending_input = function(session_id, message_id, callback)
			cancellations[#cancellations + 1] = { session_id = session_id, message_id = message_id, callback = callback }
		end
		-- Exercise the real admission waiter without starting a lifecycle connection.
		actions.cancel_submitting_input = function(session_id, message_id, callback)
			return require("opencode.send").cancel_submitting_input(session_id, message_id, callback)
		end
	end)

	after_each(function()
		for name, original in pairs(saved) do
			if original == false then actions[name] = nil else actions[name] = original end
		end
		vim.notify, vim.schedule = old_notify, old_schedule
		require("opencode.client").cancel_input = old_client_cancel
		input.close(false)
		history.clear_pending(); pending.clear_all(); sync.clear_all(); state.reset()
	end)

	it("moves two staged boundaries backward, restores the prompt payload, and clears the stage on redo", function()
		delivered_turns()
		run("undo")
		assert.equals("msg_0005", stages[1].message_id)
		assert.equals("Third [File 1] @explore @review", input.get_pending_text())
		local parts = input.get_pending_parts()
		assert.equals(3, #parts)
		assert.equals("file:///tmp/context.txt", parts[1].uri or parts[1].url)
		assert.equals("explore", parts[2].name)
		assert.equals("review", parts[3].skillID or parts[3].id)
		local resend, error_message = require("opencode.protocol.v2.requests").prompt(input.get_pending_text(), { parts = parts }, "msg_resend")
		assert.is_nil(error_message)
		assert.equals("file:///tmp/context.txt", resend.files[1].uri)
		assert.equals("explore", resend.agents[1].name)
		assert.equals("review", resend.skills[1].id)

		run("undo")
		assert.equals(2, #stages)
		assert.equals("msg_0003", stages[2].message_id)
		assert.equals("Second", input.get_pending_text())
		assert.same({}, input.get_pending_parts())
		assert.equals("msg_0003", state.get_session_record("s").revert.messageID)

		run("redo")
		assert.is_nil(state.get_session_record("s").revert)
	end)

	it("replaces an open composer with the restored prompt and its attachments", function()
		delivered_turns()
		input.show({ text = "Unsent draft", parts = { { type = "file", uri = "file:///tmp/other.txt" } } })
		assert.is_true(input.is_visible())
		run("undo")
		assert.equals("Third [File 1] @explore @review", input.get_pending_text())
		assert.equals("file:///tmp/context.txt", input.get_pending_parts()[1].uri or input.get_pending_parts()[1].url)
		local bufnr = vim.api.nvim_win_get_buf(input.get_winids()[1])
		assert.same({ "Third [File 1] @explore @review" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end)

	it("uses message chronology when IDs are not lexically ordered", function()
		sync.handle_session_messages("s", projection.page("s", {
			{ id = "msg_z", type = "user", text = "First", time = { created = 1 } },
			{ id = "msg_z_reply", type = "assistant", content = { { type = "text", text = "One" } }, time = { created = 2 } },
			{ id = "msg_a", type = "user", text = "Second", time = { created = 3 } },
			{ id = "msg_a_reply", type = "assistant", content = { { type = "text", text = "Two" } }, time = { created = 4 } },
		}))
		run("undo")
		assert.equals("msg_a", stages[1].message_id)
		run("undo")
		assert.equals(2, #stages)
		assert.equals("msg_z", stages[2].message_id)
		assert.equals("First", input.get_pending_text())
	end)

	it("restores an attachment-only user turn", function()
		sync.handle_session_messages("s", projection.page("s", {
			{ id = "msg_file", type = "user", text = "", time = { created = 1 },
				files = { { uri = "file:///tmp/photo.png", name = "photo.png", mime = "image/png" } } },
		}))
		run("undo")
		assert.equals("msg_file", stages[1].message_id)
		assert.equals("", input.get_pending_text())
		assert.equals("file:///tmp/photo.png", input.get_pending_parts()[1].uri or input.get_pending_parts()[1].url)
	end)

	it("preserves targeted agent and skill mentions through the composer when their text repeats", function()
		local native = { id = "msg_repeated", type = "user", text = "@explore @review\n猫 @explore @review",
			agents = { { name = "explore", mention = { start = 20, ["end"] = 28, text = "@explore" } } },
			skills = { { id = "review", mention = { start = 29, ["end"] = 36, text = "@review" } } } }
		sync.handle_session_messages("s", projection.page("s", { native }))
		local payload
		input.show({ text = "", on_send = function(text, parts)
			payload = require("opencode.protocol.v2.requests").prompt(text, { parts = parts }, "msg_new")
		end })
		run("undo")
		vim.fn.maparg("<C-g>", "n", false, true).callback()
		assert.is_not_nil(payload)
		assert.same(native.agents[1].mention, payload.agents[1].mention)
		assert.same(native.skills[1].mention, payload.skills[1].mention)
	end)

	it("relocates unique agent and skill mentions after their restored ranges move", function()
		local draft = projection.draft({ type = "user", text = "@explore @review",
			agents = { { name = "explore", mention = { start = 0, ["end"] = 8, text = "@explore" } } },
			skills = { { id = "review", mention = { start = 9, ["end"] = 16, text = "@review" } } } })
		local payload
		input.show({ text = draft.text, parts = draft.parts, on_send = function(text, parts)
			payload = require("opencode.protocol.v2.requests").prompt(text, { parts = parts }, "msg_moved")
		end })
		local buffer = vim.api.nvim_win_get_buf(input.get_winids()[1])
		vim.api.nvim_buf_set_text(buffer, 0, 0, 0, 0, { "猫", "Use " })
		vim.fn.maparg("<C-g>", "n", false, true).callback()
		assert.same({ start = 7, ["end"] = 15, text = "@explore" }, payload.agents[1].mention)
		assert.same({ start = 16, ["end"] = 23, text = "@review" }, payload.skills[1].mention)
	end)

	it("keeps an existing draft when staging a delivered turn fails", function()
		delivered_turns()
		input.set_pending_text("My unfinished draft")
		actions.undo_message = function(_, _, callback)
			callback({ status = 500, message = "Stage unavailable" })
		end
		run("undo")
		assert.equals("My unfinished draft", input.get_pending_text())
		assert.is_nil(state.get_session_record("s").revert)
	end)

	it("cancels a queued prompt without staging and restores it only after cancellation succeeds", function()
		local native = { id = "msg_0007", type = "user", text = "Queued with file",
			files = { { uri = "file:///tmp/queued.txt", name = "queued.txt" } }, time = { created = 7 } }
		local projected = projection.project("s", native)
		projected.info.provisional = true
		sync.handle_session_messages("s", { projected })
		pending.admit({ sessionID = "s", id = native.id, type = "user", delivery = "queue", payload = native })

		run("undo")
		assert.equals(1, #cancellations)
		assert.equals("msg_0007", cancellations[1].message_id)
		assert.same({}, stages)
		assert.equals("", input.get_pending_text())
		pending.update("s", native.id, { status = "cancelled" })
		sync.handle_message_removed("s", native.id)
		cancellations[1].callback(nil)
		assert.equals("Queued with file", input.get_pending_text())
		assert.equals("file:///tmp/queued.txt", input.get_pending_parts()[1].uri or input.get_pending_parts()[1].url)
	end)

	it("keeps the composer and pending item when queued cancellation fails", function()
		local native = { id = "msg_0007", type = "user", text = "Queued", time = { created = 7 } }
		local projected = projection.project("s", native)
		projected.info.provisional = true
		sync.handle_session_messages("s", { projected })
		pending.admit({ sessionID = "s", id = native.id, type = "user", delivery = "queue", payload = native })
		input.set_pending_text("My unfinished draft")

		run("undo")
		assert.equals(1, #cancellations)
		cancellations[1].callback({ status = 409, message = "Already delivered" })
		assert.same({}, stages)
		assert.equals("My unfinished draft", input.get_pending_text())
		assert.equals("queued", pending.get("s", native.id).status)
	end)

	it("waits for a submitting prompt to be admitted before cancelling and restoring it", function()
		require("opencode.client").cancel_input = function(session_id, message_id, callback)
			cancellations[#cancellations + 1] = { session_id = session_id, message_id = message_id, callback = callback }
		end
		local native = { id = "msg_0007", type = "user", text = "Submitting prompt",
			files = { { uri = "file:///tmp/submitting.txt", name = "submitting.txt" } }, time = { created = 7 } }
		local projected = projection.project("s", native)
		projected.info.provisional = true
		sync.handle_session_messages("s", { projected })
		pending.begin({ session_id = "s", message_id = native.id, status = "submitting", payload = native,
			text = native.text, options = { parts = { { type = "file", uri = "file:///tmp/submitting.txt" } } } })
		input.set_pending_text("Other draft")

		run("undo")
		assert.same({}, stages)
		assert.same({}, cancellations)
		assert.equals("Other draft", input.get_pending_text())
		pending.admit({ sessionID = "s", id = native.id, type = "user", delivery = "queue", payload = native })
		assert.is_true(vim.wait(1000, function() return #cancellations == 1 end, 10))
		assert.equals(native.id, cancellations[1].message_id)
		assert.same({}, stages)
		assert.equals("Other draft", input.get_pending_text())
		cancellations[1].callback(nil)
		assert.equals("Submitting prompt", input.get_pending_text())
		assert.equals("file:///tmp/submitting.txt", input.get_pending_parts()[1].uri or input.get_pending_parts()[1].url)
	end)

	it("stages a delivered turn when cancellation loses the admission race", function()
		require("opencode.client").cancel_input = function(session_id, message_id, callback)
			cancellations[#cancellations + 1] = { session_id = session_id, message_id = message_id, callback = callback }
		end
		local native = { id = "msg_0007", type = "user", text = "Racing prompt", time = { created = 7 } }
		local projected = projection.project("s", native)
		projected.info.provisional = true
		sync.handle_session_messages("s", { projected })
		pending.begin({ session_id = "s", message_id = native.id, status = "submitting", payload = native, text = native.text })
		run("undo")
		pending.admit({ sessionID = "s", id = native.id, type = "user", delivery = "queue", payload = native })
		assert.is_true(vim.wait(1000, function() return #cancellations == 1 end, 10))
		pending.update("s", native.id, { status = "delivered" })
		sync.handle_session_messages("s", projection.page("s", { native }))
		cancellations[1].callback({ status = 404, message = "Already delivered" })
		assert.equals(1, #stages)
		assert.equals(native.id, stages[1].message_id)
		assert.equals("Racing prompt", input.get_pending_text())
		assert.equals(native.id, state.get_session_record("s").revert.messageID)
	end)
end)

describe("native undo action ordering", function()
	local client = require("opencode.client")
	local saved, old_notify, old_schedule, calls, callbacks

	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all(); history.clear_pending()
		state.set_session("s", "Test")
		sync.handle_session_messages("s", projection.page("s", {
			{ id = "msg_1", type = "user", text = "Delivered prompt", time = { created = 1 } },
		}))
		history.set_pending("Unsent draft", { { type = "file", uri = "file:///tmp/draft.txt" } })
		slash.register_defaults()
		old_notify, old_schedule = vim.notify, vim.schedule
		vim.notify = function() end
		vim.schedule = function(callback) callback() end
		saved = { abort_session = client.abort_session, wait_session = client.wait_session,
			revert_message = client.revert_message }
		calls, callbacks = {}, {}
		client.abort_session = function(session_id, callback)
			calls[#calls + 1] = { name = "abort", session_id = session_id }
			callbacks.abort = callback
		end
		client.wait_session = function(session_id, callback)
			calls[#calls + 1] = { name = "wait", session_id = session_id }
			callbacks.wait = callback
		end
		client.revert_message = function(session_id, message_id, opts, callback)
			calls[#calls + 1] = { name = "stage", session_id = session_id, message_id = message_id, opts = opts }
			callbacks.stage = callback
		end
	end)

	after_each(function()
		for name, original in pairs(saved) do client[name] = original end
		vim.notify, vim.schedule = old_notify, old_schedule
		history.clear_pending(); pending.clear_all(); sync.clear_all(); state.reset()
	end)

	it("aborts, waits, then stages before replacing the draft", function()
		assert.is_true(slash.execute(slash.parse("/undo")))
		assert.same({ { name = "abort", session_id = "s" } }, calls)
		assert.equals("Unsent draft", input.get_pending_text())
		callbacks.abort(nil)
		assert.same({ "abort", "wait" }, vim.tbl_map(function(call) return call.name end, calls))
		assert.equals("Unsent draft", input.get_pending_text())
		callbacks.wait(nil)
		assert.same({ "abort", "wait", "stage" }, vim.tbl_map(function(call) return call.name end, calls))
		assert.same({ name = "stage", session_id = "s", message_id = "msg_1", opts = {} }, calls[3])
		assert.equals("Unsent draft", input.get_pending_text())
		callbacks.stage(nil, { messageID = "msg_1" })
		assert.equals("Delivered prompt", input.get_pending_text())
		assert.same({}, input.get_pending_parts())
		assert.equals("msg_1", state.get_session_record("s").revert.messageID)
	end)

	for _, failure_at in ipairs({ "abort", "wait" }) do
		it("stops before staging and preserves the draft when " .. failure_at .. " fails", function()
			assert.is_true(slash.execute(slash.parse("/undo")))
			if failure_at == "wait" then callbacks.abort(nil) end
			callbacks[failure_at]({ status = 500, message = failure_at .. " unavailable" })
			assert.is_nil(callbacks.stage)
			assert.same(failure_at == "abort" and { "abort" } or { "abort", "wait" },
				vim.tbl_map(function(call) return call.name end, calls))
			assert.equals("Unsent draft", input.get_pending_text())
			assert.equals("file:///tmp/draft.txt", input.get_pending_parts()[1].uri)
			assert.is_nil(state.get_session_record("s").revert)
		end)
	end
end)
