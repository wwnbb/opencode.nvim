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
local projection = require("opencode.protocol.v2.messages")
local render_state = require("opencode.ui.chat.render_state")

describe("queued inputs in the chat buffer", function()
	local original_buffer, saved, cancels, sent, notices, fallbacks
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
	local function seed(id, value, files)
		local effect = sync.handle_v2_event({ id = "evt_" .. id, created = 10, type = "session.inbox.enqueued",
			data = { sessionID = "queue-test", inboxID = id, item = { type = "user", delivery = "queue",
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
		bus.clear(); sync.clear_all(); pending.clear_all(); app.reset(); history.clear_pending()
		local config = vim.deepcopy(require("opencode.config").defaults)
		config.input.history_file = vim.fn.tempname()
		app.set_config(config)
		app.set_session("queue-test", "Queue")
		app.set_session_status("queue-test", { type = "busy" })
		render_state.reset_chat_surface({ reset_expansions = true })
		state.render_scheduled, state.session_stack = false, {}
		chat.setup({ session_tabs = { enabled = true }, todo = { enabled = false }, auto_scroll = false })
		original_buffer = vim.api.nvim_get_current_buf()
		state.bufnr = vim.api.nvim_create_buf(false, true)
		state.winid, state.visible = vim.api.nvim_get_current_win(), true
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)
		keymaps.setup_buffer(state.bufnr, {})
		saved = { cancel = client.cancel_input, messages = client.get_messages, send = actions.send,
			connect = lifecycle.ensure_connected, refresh = sessions.refresh_status, notify = vim.notify }
		cancels, sent, notices, fallbacks = {}, {}, {}, {}
		lifecycle.ensure_connected = function(cb) cb() end
		sessions.refresh_status = function() end
		client.cancel_input = function(sid, id, cb) cancels[#cancels + 1] = { sid = sid, id = id, callback = cb } end
		actions.send = function(value, opts) sent[#sent + 1] = { text = value, opts = opts } end
		vim.notify = function(value) notices[#notices + 1] = value end
	end)
	after_each(function()
		input.close(false)
		history.clear_pending()
		client.cancel_input, client.get_messages, actions.send = saved.cancel, saved.messages, saved.send
		lifecycle.ensure_connected, sessions.refresh_status, vim.notify = saved.connect, saved.refresh, saved.notify
		require("opencode.ui.chat.tasks").stop_task_animation_timer()
		vim.api.nvim_win_set_buf(state.winid, original_buffer)
		vim.api.nvim_buf_delete(state.bufnr, { force = true })
		state.bufnr, state.winid, state.visible = nil, nil, false
		render_state.reset_chat_surface({ reset_expansions = true })
		bus.clear(); pending.clear_all(); sync.clear_all(); app.reset()
	end)

	it("removes the queue badge from a delivered message without removing its text", function()
		seed("q", "продолжай"); chat.do_render()
		assert.is_truthy(text():find("Queued · C cancel · E edit", 1, true))
		sync.handle_v2_event({ id = "evt_delivered", created = 20, type = "session.inbox.delivered",
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
		key("C"); key("E")
		focus("assistant"); key("C"); key("E")
		assert.equals(0, #cancels)
		assert.equals(0, #notices)
		assert.equals(4, #fallbacks)
		vim.api.nvim_win_set_cursor(state.winid, { pos.end_line + 1, 0 })
		key("C")
		assert.equals("q", cancels[1].id)
		assert.equals(4, #fallbacks)
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

	it("tracks the queued widget as streaming text before it changes height", function()
		sync.handle_session_messages("queue-test", projection.page("queue-test", {
			{ id = "assistant", type = "assistant", time = { created = 1 },
				content = { { type = "text", text = "First" } } },
		}))
		seed("q", "Queued text"); chat.do_render()
		local previous_start = state.pending_inputs.q.start_line
		local part = vim.deepcopy(sync.get_parts("assistant")[1])
		part.text = "First\nSecond"
		sync.handle_part_updated(part)
		assert.is_true(chat.update_stream_part_block("queue-test", "assistant", part.id))
		assert.equals(previous_start + 1, state.pending_inputs.q.start_line)
		focus("q"); key("C")
		assert.equals("q", cancels[1].id)
		assert.equals(0, #fallbacks)
	end)

	it("edits multiline text with attachments and sends back to its original session", function()
		seed("q", "Line one\nLine two", { { uri = "file:///tmp/fixture.txt", name = "fixture.txt" } })
		chat.do_render(); focus("q"); key("E")
		assert.is_false(input.is_visible())
		cancels[1].callback(nil)
		assert.is_true(input.is_visible())
		assert.equals("Line one\nLine two", input.get_pending_text())
		input.set_pending_text("Edited\nmessage")
		app.set_session("other", "Other")
		key("<C-g>")
		assert.equals(1, #sent)
		assert.equals("Edited\nmessage", sent[1].text)
		assert.equals("queue-test", sent[1].opts.session_id)
		assert.equals("file:///tmp/fixture.txt", sent[1].opts.parts[1].uri)
		assert.is_nil(sync.get_message("queue-test", "q"))
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
		assert.equals("file:///tmp/recover.txt", sent[1].opts.parts[1].uri)
		assert.equals(1, #cancels)
	end)

	it("uses configured keys in mappings and hints and supports disabling them", function()
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.bufnr, "n")) do
			vim.keymap.del("n", mapping.lhs, { buffer = state.bufnr })
		end
		chat.setup({ keymaps = { cancel_pending = "gC", edit_pending = false } })
		keymaps.setup_buffer(state.bufnr, {})
		seed("q", "Queued"); chat.do_render(); focus("q")
		assert.is_truthy(text():find("Queued · gC cancel", 1, true))
		assert.is_nil(text():find("E edit", 1, true))
		assert.equals("", vim.fn.maparg("C", "n"))
		assert.equals("", vim.fn.maparg("E", "n"))
		key("gC")
		assert.equals("q", cancels[1].id)
	end)
end)
