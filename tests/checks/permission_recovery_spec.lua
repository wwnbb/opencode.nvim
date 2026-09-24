-- Permission recovery and SSE filter tests.
-- Run with: ./tests/run.sh checks

local function stub_module(name, value)
	package.preload[name] = package.preload[name] or function()
		return value
	end
end

-- Defensively stub nui/plenary in case transitive deps need them.
local popup = {}
popup.__index = popup
function popup:new(opts)
	return setmetatable({ opts = opts or {}, bufnr = 1, winid = 1 }, self)
end
function popup:mount() end
function popup:unmount() end
function popup:map() end
function popup:on() end
setmetatable(popup, {
	__call = function(_, opts)
		return popup:new(opts)
	end,
})

local line = {}
line.__index = line
function line:new()
	return setmetatable({ _content = "" }, self)
end
function line:append(text)
	self._content = self._content .. tostring(text or "")
end
setmetatable(line, {
	__call = function()
		return line:new()
	end,
})

stub_module("nui.popup", popup)
stub_module("nui.input", popup)
stub_module("nui.split", popup)
stub_module("nui.layout", { new = function() return popup:new() end })
stub_module("nui.line", line)
stub_module("nui.text", function(text) return text end)
stub_module("nui.utils.autocmd", { event = setmetatable({}, { __index = function(_, key) return key end }) })
stub_module("plenary.job", {
	new = function(_, opts)
		return { pid = 0, start = function() end, shutdown = function() end, opts = opts or {} }
	end,
})

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_true(value, message)
	if not value then
		error(message)
	end
end

local function wait_for(predicate, message)
	assert_true(vim.wait(500, predicate, 10), message)
end

describe("opencode permission recovery", function()
	it("should_accept_global_event filters by cwd and active session directory", function()
		local state = require("opencode.state")
		state.reset()

		local sse = require("opencode.client.sse")
		local cwd = vim.fn.getcwd()
		local session_dir = "/tmp/__opencode_test_session_dir__"
		local foreign_dir = "/tmp/__opencode_test_foreign_dir__"

		state.upsert_session({ id = "sse-filter-session", directory = session_dir })
		state.set_session("sse-filter-session", "SSE Filter Session")

		-- Global native events without a location apply to all projects.
		assert_true(sse._should_accept({ type = "test", data = {} }), "location-free event should be accepted")

		-- Event with nil directory should be accepted
		assert_true(sse._should_accept({ location = {}, type = "test", data = {} }), "nil directory event should be accepted")

		-- Event matching cwd should be accepted
		assert_true(
			sse._should_accept({ location = { directory = cwd }, type = "test", data = {} }),
			"cwd-matched event should be accepted"
		)

		-- Event matching active session directory should be accepted
		assert_true(
			sse._should_accept({ location = { directory = session_dir }, type = "test", data = {} }),
			"active session directory event should be accepted"
		)

		-- Foreign directory event should be rejected
		assert_true(
			not sse._should_accept({ location = { directory = foreign_dir }, type = "test", data = {} }),
			"foreign directory event should be rejected"
		)

		state.reset()
	end)

	it("tracks a native permission once despite duplicate events", function()
		local bus = require("opencode.events.bus")
		local state = require("opencode.state")
		local permission_state = require("opencode.permission.state")
		bus.clear(); bus.clear_history(); state.reset(); permission_state.clear_all()
		state.set_session("recovery_test_session", "Recovery Test")
		require("opencode.events.handlers.interactions_v2").setup(bus)
		local pending_count = 0
		bus.on("permission_pending", function() pending_count = pending_count + 1 end)
		local event = { id = "evt_perm", type = "permission.asked", created = 1000, data = {
			id = "perm_recovery_idempotent", action = "bash", sessionID = "recovery_test_session",
			source = { type = "tool", messageID = "msg", callID = "call" },
		} }
		bus.emit("v2_interaction", event)
		bus.emit("v2_interaction", event)
		assert_true(permission_state.has_permission("perm_recovery_idempotent"), "native permission should be tracked")
		assert_eq(permission_state.get_permission("perm_recovery_idempotent").call_id, "call", "source.callID should be retained")
		assert_eq(pending_count, 1, "duplicate native permission should emit once")
		bus.clear(); bus.clear_history(); state.reset(); permission_state.clear_all()
	end)

	it("keeps permission builders pure and terminal rerenders status-aware", function()
		local permission_state = require("opencode.permission.state")
		local permission_widget = require("opencode.ui.permission_widget")
		local sync = require("opencode.sync")
		local chat_state = require("opencode.ui.chat.state").state
		local chat_permissions = require("opencode.ui.chat.permissions")

		permission_state.clear_all()
		sync.clear_all()
		sync.handle_part_updated({
			id = "permission_purity_part",
			messageID = "permission_purity_message",
			sessionID = "permission_purity_session",
			type = "tool",
			tool = "bash",
			callID = "permission_purity_call",
			state = { status = "pending", input = { command = "echo resolved" } },
		})

		local pstate = permission_state.add_permission("permission_purity", "permission_purity_session", "bash", {
			message_id = "permission_purity_message",
			call_id = "permission_purity_call",
		})
		local before = vim.deepcopy(pstate)
		permission_widget.get_lines_for_permission("permission_purity", pstate)
		permission_widget.get_approved_lines("permission_purity", pstate)
		permission_widget.get_rejected_lines("permission_purity", pstate)
		assert_true(vim.deep_equal(pstate, before), "permission builders must not mutate permission state")

		local pending_lines = permission_widget.get_lines_for_permission("permission_purity", pstate)
		local bufnr = vim.api.nvim_create_buf(false, true)
		local old_bufnr = chat_state.bufnr
		local old_permissions = chat_state.permissions
		chat_state.bufnr = bufnr
		chat_state.permissions = {
			permission_purity = { start_line = 0, end_line = #pending_lines - 1, status = "pending" },
		}
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, pending_lines)
		permission_state.mark_approved("permission_purity", "once")
		chat_permissions.rerender_permission("permission_purity")
		local approved_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
		assert_true(approved_text:find("Permission allowed", 1, true) ~= nil, "approved rerender should use approved builder")
		assert_true(approved_text:find("Allow once", 1, true) == nil, "approved rerender should not show pending options")
		assert_eq(chat_state.permissions.permission_purity.status, "approved", "approved rerender should update position status")

		-- Start a distinct pending lifecycle before checking the rejected view.
		permission_state.add_permission("permission_purity", "permission_purity_session", "bash", {})
		permission_state.mark_rejected("permission_purity")
		chat_permissions.rerender_permission("permission_purity")
		local rejected_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
		assert_true(rejected_text:find("Permission rejected", 1, true) ~= nil, "rejected rerender should use rejected builder")
		assert_true(rejected_text:find("Allow always", 1, true) == nil, "rejected rerender should not show pending options")
		assert_eq(chat_state.permissions.permission_purity.status, "rejected", "rejected rerender should update position status")

		vim.api.nvim_buf_delete(bufnr, { force = true })
		chat_state.bufnr = old_bufnr
		chat_state.permissions = old_permissions
		permission_state.clear_all()
		sync.clear_all()
	end)

	it("scopes permission lists and replies to the immutable session ID", function()
		local http, client = require("opencode.client.http"), require("opencode.client")
		local old_get, old_post = http.get, http.post
		local gets, posts = {}, {}
		http.get = function(path, cb, opts) gets[#gets + 1] = { path = path, opts = opts } end
		http.post = function(path, body, cb, opts) posts[#posts + 1] = { path = path, body = body, opts = opts } end
		client.list_permissions({ session_id = "ses/a" }, function() end)
		client.list_permissions(function() end)
		client.respond_permission("per/a", "once", { session_id = "ses/a" }, function() end)
		client.respond_permission("per_b", "reject", { session_id = "ses_b", message = "no" }, function() end)
		http.get, http.post = old_get, old_post
		assert.equals("/api/session/ses%2Fa/permission", gets[1].path)
		assert.equals("/api/permission/request", gets[2].path)
		assert.is_nil(gets[1].opts.headers)
		assert.equals("/api/session/ses%2Fa/permission/per%2Fa/reply", posts[1].path)
		assert.same({ decision = "once" }, posts[1].body)
		assert.same({ decision = "reject", message = "no" }, posts[2].body)
		assert.is_nil(posts[1].opts.headers)
	end)

	it("keeps native permissions from concurrent tool calls distinct", function()
		local bus = require("opencode.events.bus")
		local state = require("opencode.state")
		local permission_state = require("opencode.permission.state")
		bus.clear(); bus.clear_history(); state.reset(); permission_state.clear_all()
		state.set_session("match_test_session", "Match Test")
		require("opencode.events.handlers.interactions_v2").setup(bus)
		for _, call in ipairs({ "call_a", "call_b" }) do
			bus.emit("v2_interaction", { id = "event_" .. call, type = "permission.asked", created = 1000,
				data = { id = "perm_" .. call, action = "bash", sessionID = "match_test_session",
					source = { type = "tool", messageID = "match_msg", callID = call } } })
		end
		assert_eq(permission_state.get_permission("perm_call_a").call_id, "call_a", "first call owns its permission")
		assert_eq(permission_state.get_permission("perm_call_b").call_id, "call_b", "second call owns its permission")
		bus.clear(); bus.clear_history(); state.reset(); permission_state.clear_all()
	end)

	it("actions.respond_permission resolves reply directory from session", function()
		local state = require("opencode.state")
		local permission_state = require("opencode.permission.state")
		state.reset()
		permission_state.clear_all()

		local session_dir = "/tmp/__opencode_reply_scope__"
		state.upsert_session({ id = "reply_scope_session", directory = session_dir })
		state.set_session("reply_scope_session", "Reply Scope")

		-- Register a pending permission owned by that session.
		permission_state.add_permission("perm_reply_resolve", "reply_scope_session", "bash", {
			message_id = "msg_x",
			call_id = "call_x",
			timestamp = os.time(),
		})

		local actions = require("opencode.actions")
		local client = require("opencode.client")
		local captured
		local original_respond = client.respond_permission
		client.respond_permission = function(permission_id, reply, opts, callback)
			captured = { permission_id = permission_id, reply = reply, directory = opts and opts.directory }
			if callback then
				callback(nil, true)
			end
		end

		actions.respond_permission("perm_reply_resolve", "once", {}, function() end)

		client.respond_permission = original_respond

		assert_eq(captured.permission_id, "perm_reply_resolve", "should reply to the right permission")
		assert_eq(captured.reply, "once", "should pass reply")
		assert_eq(
			captured.directory,
			state.normalize_directory(session_dir),
			"reply should be scoped to the permission's session directory, not cwd"
		)

		state.reset()
		permission_state.clear_all()
	end)
end)
