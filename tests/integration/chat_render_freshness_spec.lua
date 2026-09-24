-- Native v2 event and HTTP snapshot freshness in the visible chat buffer.

describe("opencode v2 chat render freshness", function()
	require("opencode").setup({ server = { auto_start = false }, chat = { layout = "float", close_on_focus_lost = false }, lualine = { enabled = false } })
	local state = require("opencode.state")
	local sync = require("opencode.sync")
	local sessions = require("opencode.session")
	local events = require("opencode.events")
	local chat = require("opencode.ui.chat")
	local client = require("opencode.client")
	local project = require("opencode.protocol.v2.messages").project
	local original = {}
	local event_sequence = 0

	local function wait_for(predicate)
		assert.is_true(vim.wait(1000, predicate, 10))
	end

	local function buffer_text()
		local bufnr = chat.get_bufnr()
		return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	end

	local function wait_for_text(value)
		wait_for(function() return buffer_text():find(value, 1, true) ~= nil end)
	end

	local function emit(kind, sid, data)
		event_sequence = event_sequence + 1
		data = vim.tbl_extend("force", { sessionID = sid }, data or {})
		events.emit("v2_event", {
			id = "evt_fresh_" .. event_sequence,
			created = event_sequence * 1000,
			type = kind,
			location = { directory = vim.fn.getcwd() },
			data = data,
		})
	end

	local function assistant(sid, id, value)
		return project(sid, { id = id, type = "assistant", time = { created = 1 }, content = { { type = "text", text = value } } })
	end

	local function set_active(sid)
		sessions.set_active(sid, sid, { preserve_cache = true })
		chat.open()
	end

	before_each(function()
		for _, method in ipairs({ "get_messages", "get_all_messages", "get_session", "get_inbox" }) do original[method] = client[method] end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		client.get_all_messages = function(_, callback) callback(nil, {}) end
		client.get_session = function(_, callback) callback({ message = "not available" }) end
		client.get_inbox = function(_, callback) callback(nil, {}) end
		state.reset(); sync.clear_all()
		chat.create()
	end)

	after_each(function()
		chat.close()
		for method, value in pairs(original) do client[method] = value end
		state.reset(); sync.clear_all()
	end)

	it("renders native deltas only in the active session and refreshes on return", function()
		sync.handle_session_messages("stream-a", { assistant("stream-a", "msg_a", "ALPHA_BASE_") })
		sync.handle_session_messages("stream-b", { assistant("stream-b", "msg_b", "BRAVO_BASE") })
		set_active("stream-a")
		sessions.remember({ id = "stream-b", title = "stream-b" }, { touch = true })
		wait_for_text("ALPHA_BASE_")
		emit("session.text.delta", "stream-a", { assistantMessageID = "msg_a", ordinal = 0, delta = "VISIBLE" })
		wait_for_text("ALPHA_BASE_VISIBLE")
		sessions.set_active("stream-b", "stream-b", { preserve_cache = true })
		wait_for_text("BRAVO_BASE")
		assert.is_nil(buffer_text():find("ALPHA_BASE_VISIBLE", 1, true))
		emit("session.text.delta", "stream-a", { assistantMessageID = "msg_a", ordinal = 0, delta = "_HIDDEN" })
		wait_for(function() return sync.get_message_text("msg_a") == "ALPHA_BASE_VISIBLE_HIDDEN" end)
		assert.is_nil(buffer_text():find("ALPHA_BASE_VISIBLE_HIDDEN", 1, true))
		sessions.set_active("stream-a", "stream-a", { preserve_cache = true })
		wait_for_text("ALPHA_BASE_VISIBLE_HIDDEN")
	end)

	it("keeps live native text when an older HTTP snapshot arrives later", function()
		local history_callback
		client.get_messages = function(sid, opts, callback)
			assert.equals("snapshot-a", sid)
			assert.equals(100, opts.limit)
			history_callback = callback
		end
		sync.handle_session_messages("snapshot-a", { assistant("snapshot-a", "msg_snapshot", "PREFIX_") })
		set_active("snapshot-a")
		wait_for_text("PREFIX_")
		events.emit("v2_reconcile", { session_id = "snapshot-a" })
		wait_for(function() return history_callback ~= nil end)
		emit("session.text.delta", "snapshot-a", { assistantMessageID = "msg_snapshot", ordinal = 0, delta = "NEW" })
		wait_for_text("PREFIX_NEW")
		history_callback(nil, { assistant("snapshot-a", "msg_snapshot", "PREFIX_") })
		vim.wait(50)
		assert.equals("PREFIX_NEW", sync.get_message_text("msg_snapshot"))
		assert.is_truthy(buffer_text():find("PREFIX_NEW", 1, true))
	end)

	it("does not render a foreign session's native stream", function()
		sync.handle_session_messages("visible", { assistant("visible", "msg_visible", "VISIBLE_ONLY") })
		sync.handle_session_messages("foreign", { assistant("foreign", "msg_foreign", "FOREIGN_BASE_") })
		set_active("visible")
		wait_for_text("VISIBLE_ONLY")
		emit("session.text.delta", "foreign", { assistantMessageID = "msg_foreign", ordinal = 0, delta = "DELTA" })
		wait_for(function() return sync.get_message_text("msg_foreign") == "FOREIGN_BASE_DELTA" end)
		assert.is_nil(buffer_text():find("FOREIGN_BASE_DELTA", 1, true))
	end)
end)
