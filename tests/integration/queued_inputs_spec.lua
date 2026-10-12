local app = require("opencode.state")
local sync = require("opencode.sync")
local pending = require("opencode.session.pending")
local chat = require("opencode.ui.chat")
local state = require("opencode.ui.chat.state").state
local keymaps = require("opencode.ui.chat.keymaps")
local input = require("opencode.ui.input")
local history = require("opencode.ui.input.history")
local actions = require("opencode.actions")
local client = require("opencode.client")
local lifecycle = require("opencode.lifecycle")
local sessions = require("opencode.session")
local bus = require("opencode.events.bus")
local projection = require("opencode.protocol.messages")
local render_state = require("opencode.ui.chat.render_state")

describe("queued inputs in the chat buffer", function()
	local original_buffer, saved, cancels, steers, sent, notices, fallbacks
	local function text()
		return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
	end
	local function key(lhs)
		local mapping = vim.fn.maparg(lhs, "n", false, true)
		assert.is_function(mapping.callback)
		local feedkeys = vim.api.nvim_feedkeys
		vim.api.nvim_feedkeys = function(value, mode) fallbacks[#fallbacks + 1] = { value = value, mode = mode } end
		local ok, err = pcall(mapping.callback)
		vim.api.nvim_feedkeys = feedkeys
		assert.is_true(ok, err)
	end
	local function seed(id, value, files, delivery)
		local effect = sync.handle_server_event({ id = "evt_" .. id, created = 10, type = "session.inbox.enqueued",
			data = { sessionID = "queue-test", inboxID = id, item = { type = "user", delivery = delivery or "queue",
				payload = { text = value, files = files } } } })
		pending.admit(effect.inbox)
	end
	local function focus(id)
		vim.api.nvim_set_current_win(state.winid)
		for _, pos in ipairs(state.message_positions) do
			if pos.id == id then
				vim.api.nvim_win_set_cursor(state.winid, { math.min(pos.start_line + 2, pos.end_line + 1), 0 })
				return
			end
		end
		error("Message not rendered: " .. id)
	end
	before_each(function()
		bus.clear(); sync.clear_all(); pending.clear_all(); app.reset(); history.clear()
		local config = vim.deepcopy(require("opencode.config").defaults)
		config.input.history_file = vim.fn.tempname()
		app.set_config(config)
		app.set_session("queue-test", "Queue")
		app.set_session_status("queue-test", { type = "busy" })
		render_state.reset_chat_surface({ reset_expansions = true })
		state.render_scheduled, state.session_stack = false, {}
		chat.setup({ session_tabs = { enabled = true }, auto_scroll = false })
		original_buffer = vim.api.nvim_get_current_buf()
		state.bufnr = vim.api.nvim_create_buf(false, true)
		state.winid, state.visible = vim.api.nvim_get_current_win(), true
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)
		keymaps.setup_buffer(state.bufnr, {})
		saved = { cancel = client.cancel_input, delivery = client.set_input_delivery, messages = client.get_messages, send = actions.send,
			connect = lifecycle.ensure_connected, refresh = sessions.refresh_status, notify = vim.notify }
		cancels, steers, sent, notices, fallbacks = {}, {}, {}, {}, {}
		lifecycle.ensure_connected = function(cb) cb() end
		sessions.refresh_status = function() end
		client.cancel_input = function(sid, id, cb) cancels[#cancels + 1] = { sid = sid, id = id, callback = cb } end
		client.set_input_delivery = function(sid, id, delivery, cb)
			steers[#steers + 1] = { sid = sid, id = id, delivery = delivery, callback = cb }
		end
		actions.send = function(value, opts) sent[#sent + 1] = { text = value, opts = opts } end
		vim.notify = function(value) notices[#notices + 1] = value end
	end)
	after_each(function()
		input.close(false)
		history.clear()
		client.cancel_input, client.get_messages, actions.send = saved.cancel, saved.messages, saved.send
		client.set_input_delivery = saved.delivery
		lifecycle.ensure_connected, sessions.refresh_status, vim.notify = saved.connect, saved.refresh, saved.notify
		require("opencode.ui.chat.tasks").stop_task_animation_timer()
		vim.api.nvim_win_set_buf(state.winid, original_buffer)
		vim.api.nvim_buf_delete(state.bufnr, { force = true })
		state.bufnr, state.winid, state.visible = nil, nil, false
		render_state.reset_chat_surface({ reset_expansions = true })
		bus.clear(); pending.clear_all(); sync.clear_all(); app.reset()
	end)

	it("pins queued inputs below later assistant output and the processing footer", function()
		seed("q", "First pending"); seed("q2", "Second pending")
		sync.handle_session_messages("queue-test", projection.page("queue-test", {
			{ id = "assistant", type = "assistant", agent = "active-agent", time = { created = 20 },
				content = { { type = "text", text = "Agent is still working" } } },
		}))
		chat.do_render()
		assert.is_true(text():find("Agent is still working", 1, true) < text():find("First pending", 1, true))
		assert.is_true(state.spinner_footer_line < state.pending_inputs.q.start_line)
		assert.is_true(state.pending_inputs.q.end_line < state.pending_inputs.q2.start_line)
		assert.equals("q", sync.get_messages("queue-test")[1].id)
		local previous_start = state.pending_inputs.q2.start_line
		local part = vim.deepcopy(sync.get_parts("assistant")[1])
		part.text = "Agent is still working\nAnother line"
		sync.handle_part_updated(part)
		assert.is_true(chat.update_stream_part_block("queue-test", "assistant", part.id))
		assert.is_true(text():find("Another line", 1, true) < text():find("First pending", 1, true))
		assert.equals(previous_start + 1, state.pending_inputs.q2.start_line)
		focus("q2"); key("C")
		assert.equals("q2", cancels[1].id)
		assert.same({}, fallbacks)
	end)

	it("keeps old pending inputs visible outside the history render limit", function()
		seed("q", "Old pending")
		sync.handle_session_messages("queue-test", projection.page("queue-test", {
			{ id = "a1", type = "assistant", time = { created = 20, completed = 21 }, content = { { type = "text", text = "Older output" } } },
			{ id = "a2", type = "assistant", time = { created = 30 }, content = { { type = "text", text = "Newest output" } } },
		}))
		chat.setup({ max_rendered_messages = 1 })
		chat.do_render()
		assert.is_nil(text():find("Older output", 1, true))
		assert.is_true(text():find("Newest output", 1, true) < text():find("Old pending", 1, true))
		assert.is_not_nil(state.pending_inputs.q)
	end)

	it("moves delivered inputs back into history while other inputs remain at the bottom", function()
		seed("q", "Delivered input"); seed("q2", "Remaining pending")
		sync.handle_server_event({ id = "evt_delivery", created = 20, type = "session.inbox.delivered",
			data = { sessionID = "queue-test", inboxID = "q" } })
		pending.update("queue-test", "q", { status = "delivered" })
		sync.handle_session_messages("queue-test", projection.page("queue-test", {
			{ id = "assistant", type = "assistant", time = { created = 30 }, content = { { type = "text", text = "Response after delivery" } } },
		}))
		chat.do_render()
		assert.is_true(text():find("Delivered input", 1, true) < text():find("Response after delivery", 1, true))
		assert.is_true(text():find("Response after delivery", 1, true) < text():find("Remaining pending", 1, true))
		assert.is_nil(state.pending_inputs.q)
		assert.is_not_nil(state.pending_inputs.q2)
	end)

	it("steers only the queued item at the cursor after confirmation without resending", function()
		seed("q", "First"); seed("q2", "Second"); chat.do_render()
		assert.equals("", vim.fn.maparg("s", "n"))
		assert.is_truthy(text():find("Queued · C cancel · E edit · S steer", 1, true))
		focus("q2"); key("S"); key("S")
		assert.equals(1, #steers)
		assert.equals("q2", steers[1].id)
		assert.equals("queue-test", steers[1].sid)
		assert.equals("steer", steers[1].delivery)
		assert.equals("queued", pending.get("queue-test", "q2").status)
		steers[1].callback({ message = "Unavailable" })
		assert.equals("queued", pending.get("queue-test", "q2").status)
		assert.equals(1, #notices)
		key("S"); steers[2].callback(nil); chat.do_render()
		assert.equals("queued", pending.get("queue-test", "q").status)
		assert.equals("accepted", pending.get("queue-test", "q2").status)
		assert.equals(2, #sync.get_messages("queue-test"))
		assert.is_truthy(text():find("Steering pending · C cancel · E edit", 1, true))
		focus("q2"); key("S")
		assert.equals(2, #steers)
		assert.equals(0, #sent)
		assert.equals(0, #cancels)
	end)

	it("queues a steering input and can steer the same message again", function()
		seed("steer", "Keep this", { { uri = "file:///tmp/context.txt" } }, "steer")
		chat.do_render(); focus("steer")
		assert.is_truthy(text():find("Q queue", 1, true))
		key("Q"); key("Q")
		assert.equals(1, #steers)
		assert.same({ sid = "queue-test", id = "steer", delivery = "queue" }, {
			sid = steers[1].sid, id = steers[1].id, delivery = steers[1].delivery,
		})
		assert.equals("accepted", pending.get("queue-test", "steer").status)
		steers[1].callback({ message = "Unavailable" })
		assert.equals("accepted", pending.get("queue-test", "steer").status)
		key("Q"); steers[2].callback(nil); chat.do_render()
		assert.equals("queued", pending.get("queue-test", "steer").status)
		assert.is_truthy(text():find("S steer", 1, true))
		focus("steer"); key("S"); steers[3].callback(nil); chat.do_render()
		assert.equals("accepted", pending.get("queue-test", "steer").status)
		assert.equals("file:///tmp/context.txt", sync.get_parts("steer")[2].url)
		assert.equals(1, #sync.get_messages("queue-test"))
		assert.equals(0, #sent)
		assert.equals(0, #cancels)
	end)


	it("keeps steering visibly pending while the active agent continues, until delivery", function()
		seed("steer", "стой", nil, "steer")
		chat.do_render()
		assert.is_truthy(text():find("Steering pending · C cancel · E edit", 1, true))
		assert.is_nil(text():find("Queued", 1, true))
		sync.handle_server_event({ id = "evt_step", created = 15, type = "session.step.started",
			data = { sessionID = "queue-test", assistantMessageID = "assistant", started = 15 } })
		chat.do_render()
		assert.is_truthy(text():find("Steering pending · C cancel · E edit", 1, true))
		assert.is_not_nil(state.pending_inputs.steer)
		sync.handle_server_event({ id = "evt_delivered", created = 20, type = "session.inbox.delivered",
			data = { sessionID = "queue-test", inboxID = "steer" } })
		pending.update("queue-test", "steer", { status = "delivered" })
		chat.do_render()
		assert.is_nil(text():find("Steering pending", 1, true))
		assert.is_nil(state.pending_inputs.steer)
		assert.is_truthy(text():find("стой", 1, true))
	end)

	it("removes the queue badge from a delivered message without removing its text", function()
		seed("q", "продолжай"); chat.do_render()
		assert.is_truthy(text():find("Queued · C cancel · E edit", 1, true))
		sync.handle_server_event({ id = "evt_delivered", created = 20, type = "session.inbox.delivered",
			data = { sessionID = "queue-test", inboxID = "q" } })
		pending.update("queue-test", "q", { status = "delivered" })
		chat.do_render()
		assert.is_nil(text():find("Queued", 1, true))
		assert.is_truthy(text():find("продолжай", 1, true))
		focus("q"); key("C"); key("E")
		assert.equals(0, #cancels)
		assert.equals(0, #notices)
		assert.same({ { value = "C", mode = "n" }, { value = "E", mode = "n" } }, fallbacks)
	end)

	it("clears stale queue state when loading confirmed history without a delivery event", function()
		seed("q", "Delivered"); seed("q2", "Still queued"); chat.do_render()
		client.get_messages = function(_, _, cb)
			cb(nil, projection.page("queue-test", { { id = "q", type = "user", text = "Delivered", time = { created = 20 } } }))
		end
		actions.load_session_messages("queue-test")
		chat.do_render()
		assert.equals("delivered", pending.get("queue-test", "q").status)
		assert.equals("queued", pending.get("queue-test", "q2").status)
		local _, badges = text():gsub("Queued ·", "")
		assert.equals(1, badges)
		focus("q"); key("C")
		assert.equals(0, #cancels)
	end)

	it("cancels only the queued message at the cursor after the server confirms", function()
		seed("q", "First"); seed("q2", "Second"); chat.do_render(); focus("q"); key("C")
		assert.equals("q", cancels[1].id)
		assert.is_not_nil(sync.get_message("queue-test", "q"))
		cancels[1].callback({ message = "Unavailable" })
		assert.is_not_nil(sync.get_message("queue-test", "q"))
		key("C"); cancels[2].callback(nil); chat.do_render()
		assert.is_nil(sync.get_message("queue-test", "q"))
		assert.is_not_nil(sync.get_message("queue-test", "q2"))
		assert.equals("busy", app.get_session_status("queue-test").type)
	end)

	it("only consumes keys inside the queued widget, including its status line", function()
		seed("q", "Queued text")
		sync.handle_session_messages("queue-test", projection.page("queue-test", {
			{ id = "assistant", type = "assistant", time = { created = 20, completed = 21 },
				content = { { type = "text", text = "First word next" } } },
		}))
		chat.do_render()
		local pos = state.pending_inputs.q
		-- The blank separator after the queue status belongs to no widget.
		vim.api.nvim_win_set_cursor(state.winid, { pos.end_line + 2, 0 })
		key("C"); key("E"); key("S"); key("Q")
		focus("assistant"); key("C"); key("E"); key("S"); key("Q")
		assert.equals(0, #cancels)
		assert.equals(0, #steers)
		assert.equals(0, #notices)
		assert.equals(8, #fallbacks)
		vim.api.nvim_win_set_cursor(state.winid, { pos.end_line + 1, 0 })
		key("C")
		assert.equals("q", cancels[1].id)
		assert.equals(8, #fallbacks)
	end)

	it("keeps native E motion outside the queued widget", function()
		seed("q", "Queued text")
		sync.handle_session_messages("queue-test", projection.page("queue-test", {
			{ id = "assistant", type = "assistant", time = { created = 20, completed = 21 },
				content = { { type = "text", text = "First word next" } } },
		}))
		chat.do_render()
		for row, line in ipairs(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)) do
			if line == "First word next" then
				vim.api.nvim_win_set_cursor(state.winid, { row, 0 })
				vim.api.nvim_feedkeys("E", "xt", false)
				assert.same({ row, 4 }, vim.api.nvim_win_get_cursor(state.winid))
				assert.equals(0, #cancels)
				assert.equals(0, #notices)
				return
			end
		end
		error("Assistant text not rendered")
	end)


	it("edits multiline text with attachments and sends back to its original session", function()
		local original = "## Title\n\n**Line one**\n\n```lua\nreturn 1\n```"
		seed("q", original, { { uri = "file:///tmp/fixture.txt", name = "fixture.txt" } })
		chat.do_render()
		assert.is_nil(text():find("```lua", 1, true))
		assert.is_nil(text():find("**Line one**", 1, true))
		focus("q"); key("E")
		assert.is_false(input.is_visible())
		cancels[1].callback(nil)
		assert.is_true(input.is_visible())
		assert.equals(original, input.get_pending_text())
		input.set_pending_text("Edited\nmessage")
		app.set_session("other", "Other")
		assert.is_false(input.is_visible())
		assert.equals("Edited\nmessage", history.get_pending("queue-test"))
		assert.equals("", history.get_pending("other"))
		app.set_session("queue-test", "Queue")
		chat.focus_input()
		vim.fn.maparg("<C-x><C-s>", "n", false, true).callback()
		assert.equals(1, #sent)
		assert.equals("Edited\nmessage", sent[1].text)
		assert.equals("queue-test", sent[1].opts.session_id)
		assert.equals("steer", sent[1].opts.delivery)
		assert.equals("file:///tmp/fixture.txt", sent[1].opts.parts[1].uri or sent[1].opts.parts[1].url)
		assert.is_nil(sync.get_message("queue-test", "q"))
	end)

	it("removes deleted attachment markers when editing local and recovered queue entries", function()
		for index, origin in ipairs({ "local", "server" }) do
			local value, uri = "Keep [Image 2]", "data:image/png;base64,Yg=="
			seed(origin, value, { { uri = uri, name = "2.png", mention = { start = 5, ["end"] = 14, text = "[Image 2]" } } })
			if origin == "local" then
				pending.update("queue-test", origin, { text = value, options = { parts = {
					{ type = "file", url = uri, filename = "2.png", source = { text = { start = 5, ["end"] = 14, value = "[Image 2]" } } },
				} } })
			end
			chat.do_render(); focus(origin); key("E"); cancels[index].callback(nil)
			assert.is_true(input.is_visible())
			input.set_pending_text("Image removed")
			key("<C-g>")
			assert.same({}, sent[index].opts.parts)
		end
	end)

	it("preserves native mention positions while editing a recovered queue entry", function()
		local payload = { text = "[Image 2] @explore @review\n猫 [Image 2] @explore @review",
			files = { { uri = "data:image/png;base64,Yg==", name = "2.png",
				mention = { start = 30, ["end"] = 39, text = "[Image 2]" } } },
			agents = { { name = "explore", mention = { start = 40, ["end"] = 48, text = "@explore" } } },
			skills = { { id = "review", mention = { start = 49, ["end"] = 56, text = "@review" } } } }
		local effect = sync.handle_server_event({ id = "evt_mentions", created = 10, type = "session.inbox.enqueued",
			data = { sessionID = "queue-test", inboxID = "mentions", item = { type = "user", delivery = "queue", payload = payload } } })
		pending.admit(effect.inbox)
		chat.do_render(); focus("mentions"); key("E"); cancels[1].callback(nil)
		key("<C-g>")
		local restored = assert(require("opencode.protocol.requests").prompt(sent[1].text, sent[1].opts, "resent"))
		assert.same(payload.files, restored.files)
		assert.same(payload.agents, restored.agents)
		assert.same(payload.skills, restored.skills)
	end)

	it("sends an edited steering input as queued when the queue key is pressed", function()
		seed("steer", "Edit and queue", nil, "steer")
		chat.do_render(); focus("steer"); key("E")
		cancels[1].callback(nil)
		assert.is_true(input.is_visible())
		vim.fn.maparg("<C-g>", "n", false, true).callback()
		assert.equals("Edit and queue", sent[1].text)
		assert.equals("queue", sent[1].opts.delivery)
		assert.equals("queue-test", sent[1].opts.session_id)
	end)

	it("preserves an existing draft instead of cancelling a queued message", function()
		seed("q", "Queued"); chat.do_render(); focus("q")
		history.set_pending("Unsent draft")
		key("E")
		assert.equals(0, #cancels)
		assert.equals("Unsent draft", history.get_pending())
	end)

	it("keeps the cancelled draft when another editor opens while cancellation is in flight", function()
		seed("q", "Recover this", { { uri = "file:///tmp/recover.txt" } })
		chat.do_render(); focus("q"); key("E")
		input.show({ winid = state.winid, text = "New draft" })
		cancels[1].callback(nil)
		assert.equals("New draft", input.get_pending_text())
		input.close(false)
		vim.api.nvim_set_current_win(state.winid)
		chat.do_render(); key("E")
		assert.is_false(input.is_visible())
		assert.same({ { value = "E", mode = "n" } }, fallbacks)
		assert.is_true(chat.focus_input())
		assert.equals("Recover this", input.get_pending_text())
		key("<C-g>")
		assert.equals("file:///tmp/recover.txt", sent[1].opts.parts[1].uri or sent[1].opts.parts[1].url)
		assert.equals(1, #cancels)
	end)

	it("uses the pressed composer key to override restored draft delivery", function()
		history.set_pending("Queue this", nil, "queue-test")
		history.set_pending_options({ session_id = "queue-test", delivery = "steer" }, "queue-test")
		assert.is_true(chat.focus_input())
		vim.fn.maparg("<C-g>", "n", false, true).callback()
		assert.equals("Queue this", sent[1].text)
		assert.equals("queue", sent[1].opts.delivery)
		assert.equals("queue-test", sent[1].opts.session_id)

		history.set_pending("Steer this", nil, "queue-test")
		history.set_pending_options({ session_id = "queue-test", delivery = "queue" }, "queue-test")
		assert.is_true(chat.focus_input())
		vim.fn.maparg("<C-x><C-s>", "n", false, true).callback()
		assert.equals("Steer this", sent[2].text)
		assert.equals("steer", sent[2].opts.delivery)
		assert.equals("queue-test", sent[2].opts.session_id)
	end)

	it("recovers multiple cancelled drafts in order after each composer send", function()
		seed("q", "First recovery", { { uri = "file:///tmp/first.txt" } })
		seed("q2", "Second recovery", { { uri = "file:///tmp/second.txt" } })
		chat.do_render(); focus("q"); key("E"); focus("q2"); key("E")
		input.show({ winid = state.winid, text = "New draft" })
		cancels[1].callback(nil); cancels[2].callback(nil)
		input.close(false)
		require("opencode.cleanup").clear_transient({ reset_state = false })
		assert.is_true(chat.focus_input())
		assert.equals("First recovery", input.get_pending_text())
		key("<C-g>")
		assert.is_true(chat.focus_input())
		assert.equals("Second recovery", input.get_pending_text())
		key("<C-g>")
		assert.equals("file:///tmp/first.txt", sent[1].opts.parts[1].uri or sent[1].opts.parts[1].url)
		assert.equals("file:///tmp/second.txt", sent[2].opts.parts[1].uri or sent[2].opts.parts[1].url)
	end)

	for _, case in ipairs({
		{ name = "clearing input history", clear = function() input.clear_history() end },
		{ name = "deleting its session", clear = function() require("opencode.cleanup").clear_session("queue-test") end },
	}) do
		it("does not revive a deferred edit after " .. case.name, function()
			seed("q", "Discard this")
			chat.do_render(); focus("q"); key("E")
			input.show({ winid = state.winid, text = "Another draft" })
			cancels[1].callback(nil)
			input.close(false)
			history.set_pending("Keep this", nil, "other-session")
			case.clear()
			assert.is_false(require("opencode.ui.chat.pending_inputs").resume_edit())
			assert.is_false(input.is_visible())
			assert.equals(case.name == "deleting its session" and "Keep this" or "", history.get_pending("other-session"))
		end)
	end

	it("preserves an explicit legacy send_alt as queue after configuration merge", function()
		local config = require("opencode.config")
		app.set_config(config.merge({ input = { history_file = app.get_config().input.history_file,
			keymaps = { send_alt = "<C-x><C-s>" } } }))
		history.set_pending("Legacy queue", nil, "queue-test")
		assert.is_true(chat.focus_input())
		vim.fn.maparg("<C-x><C-s>", "n", false, true).callback()
		assert.equals("Legacy queue", sent[1].text)
		assert.equals("queue", sent[1].opts.delivery)
	end)

	it("uses configured keys in mappings and hints and supports disabling them", function()
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.bufnr, "n")) do
			vim.keymap.del("n", mapping.lhs, { buffer = state.bufnr })
		end
		app.set_config(vim.tbl_deep_extend("force", app.get_config(), {
			chat = { keymaps = { cancel_pending = "gC", edit_pending = false, steer_pending = "gs", queue_pending = "gq" } },
		}))
		chat.setup({})
		keymaps.setup_buffer(state.bufnr, {})
		seed("q", "Queued"); chat.do_render(); focus("q")
		assert.is_truthy(text():find("Queued · gC cancel", 1, true))
		assert.is_nil(text():find("E edit", 1, true))
		assert.is_truthy(text():find("gs steer", 1, true))
		assert.equals("", vim.fn.maparg("C", "n"))
		assert.equals("", vim.fn.maparg("E", "n"))
		assert.equals("", vim.fn.maparg("S", "n"))
		assert.equals("", vim.fn.maparg("Q", "n"))
		key("gs")
		assert.equals("q", steers[1].id)
		steers[1].callback(nil); chat.do_render(); focus("q")
		assert.is_truthy(text():find("gq queue", 1, true))
		key("gq")
		assert.equals("queue", steers[2].delivery)
		key("gC")
		assert.equals("q", cancels[1].id)
	end)

	it("can disable the steering key and hint", function()
		vim.keymap.del("n", "S", { buffer = state.bufnr })
		chat.setup({ keymaps = { steer_pending = false } })
		keymaps.setup_buffer(state.bufnr, {})
		seed("q", "Queued"); chat.do_render()
		assert.equals("", vim.fn.maparg("S", "n"))
		assert.is_nil(text():find("S steer", 1, true))
	end)

	it("can disable the queue key and hint", function()
		vim.keymap.del("n", "Q", { buffer = state.bufnr })
		chat.setup({ keymaps = { queue_pending = false } })
		keymaps.setup_buffer(state.bufnr, {})
		seed("steer", "Steering", nil, "steer"); chat.do_render()
		assert.equals("", vim.fn.maparg("Q", "n"))
		assert.is_nil(text():find("Q queue", 1, true))
	end)
end)
