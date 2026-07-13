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

		-- Event without payload should always be accepted
		assert_true(sse._should_accept({ type = "test" }), "non-payload event should be accepted")

		-- Event with nil directory should be accepted
		assert_true(sse._should_accept({ payload = { type = "test" } }), "nil directory event should be accepted")

		-- Event matching cwd should be accepted
		assert_true(
			sse._should_accept({ directory = cwd, payload = { type = "test" } }),
			"cwd-matched event should be accepted"
		)

		-- Event matching active session directory should be accepted
		assert_true(
			sse._should_accept({ directory = session_dir, payload = { type = "test" } }),
			"active session directory event should be accepted"
		)

		-- Foreign directory event should be rejected
		assert_true(
			not sse._should_accept({ directory = foreign_dir, payload = { type = "test" } }),
			"foreign directory event should be rejected"
		)

		state.reset()
	end)

	it("tracks a permission once despite duplicate events", function()
		local bus = require("opencode.events.bus")
		bus.clear()
		bus.clear_history()

		local state = require("opencode.state")
		local permission_state = require("opencode.permission.state")
		state.reset()
		permission_state.clear_all()

		state.set_session("recovery_test_session", "Recovery Test")

		require("opencode.events.handlers.permission").setup(bus)

		local pending_count = 0
		bus.on("permission_pending", function()
			pending_count = pending_count + 1
		end)

		local perm_data = {
			requestID = "perm_recovery_idempotent",
			permission = "bash",
			sessionID = "recovery_test_session",
			time = { created = os.time() },
		}

		bus.emit("permission", perm_data)
		bus.emit("permission", perm_data)

		wait_for(function()
			return permission_state.has_permission("perm_recovery_idempotent")
		end, "permission should be tracked after first event")

		assert_true(permission_state.has_permission("perm_recovery_idempotent"), "permission should be tracked")
		assert_eq(pending_count, 1, "duplicate permission event should emit permission_pending once")

		bus.clear()
		bus.clear_history()
		state.reset()
		permission_state.clear_all()
	end)

	it("list_permissions scopes to directory header and query", function()
		local http = require("opencode.client.http")
		local client = require("opencode.client")

		local captured_with_dir = {}
		local captured_without_dir = {}
		local call_count = 0
		local original_get = http.get
		http.get = function(path, callback, opts)
			call_count = call_count + 1
			if call_count == 1 then
				captured_with_dir = { path = path, opts = opts, has_callback = callback ~= nil }
			elseif call_count == 2 then
				captured_without_dir = { path = path, opts = opts, has_callback = callback ~= nil }
			end
		end

		client.list_permissions({ directory = "/tmp/__opencode_test_scope__" }, function() end)
		client.list_permissions(function() end)

		http.get = original_get

		assert_eq(captured_with_dir.path, "/permission", "list_permissions should target /permission")
		assert_eq(
			captured_with_dir.opts.headers["x-opencode-directory"],
			"/tmp/__opencode_test_scope__",
			"should pass directory header"
		)
		assert_eq(
			captured_with_dir.opts.query.directory,
			"/tmp/__opencode_test_scope__",
			"should pass directory query param"
		)
		assert_true(captured_with_dir.has_callback, "should pass callback")

		assert_eq(captured_without_dir.path, "/permission", "backward-compat list_permissions should target /permission")
		assert_eq(captured_without_dir.opts, nil, "backward-compat list_permissions should not pass request opts")
		assert_true(captured_without_dir.has_callback, "backward-compat list_permissions should pass callback")
	end)

	it("respond_permission scopes to directory header", function()
		local http = require("opencode.client.http")
		local client = require("opencode.client")

		local captured_with_dir = {}
		local captured_without_dir = {}
		local call_count = 0
		local original_post = http.post
		http.post = function(path, body, callback, opts)
			call_count = call_count + 1
			if call_count == 1 then
				captured_with_dir = { path = path, body = body, opts = opts, has_callback = callback ~= nil }
			elseif call_count == 2 then
				captured_without_dir = { path = path, body = body, opts = opts, has_callback = callback ~= nil }
			end
		end

		client.respond_permission("perm_test", "once", { directory = "/tmp/__opencode_test_reply__" }, function() end)
		client.respond_permission("perm_test2", "reject", { message = "no" }, function() end)

		http.post = original_post

		assert_eq(captured_with_dir.path, "/permission/perm_test/reply", "respond_permission should target /permission/:id/reply")
		assert_eq(
			captured_with_dir.opts.headers["x-opencode-directory"],
			"/tmp/__opencode_test_reply__",
			"should pass directory header"
		)
		assert_eq(captured_with_dir.body.reply, "once", "should pass reply in body")
		assert_true(captured_with_dir.has_callback, "should pass callback")

		assert_eq(captured_without_dir.path, "/permission/perm_test2/reply", "respond_permission without dir should target /permission/:id/reply")
		assert_eq(captured_without_dir.opts, nil, "respond_permission without dir should not pass request opts")
		assert_eq(captured_without_dir.body.reply, "reject", "should pass reply in body without dir")
		assert_eq(captured_without_dir.body.message, "no", "should pass message in body without dir")
	end)

	it("permission_matches_tool requires call_id when present", function()
		local bus = require("opencode.events.bus")
		bus.clear()
		bus.clear_history()

		local state = require("opencode.state")
		local permission_state = require("opencode.permission.state")
		local sync = require("opencode.sync")
		state.reset()
		permission_state.clear_all()
		sync.clear_all()

		state.set_session("match_test_session", "Match Test")

		sync.handle_message_updated({
			id = "match_msg",
			sessionID = "match_test_session",
			role = "assistant",
			time = { created = 1 },
		})

		require("opencode.events.handlers.permission").setup(bus)

		local pending_ids = {}
		bus.on("permission_pending", function(data)
			table.insert(pending_ids, data.permission_id)
		end)

		bus.emit("permission", {
			requestID = "perm_a",
			permission = "bash",
			sessionID = "match_test_session",
			messageID = "match_msg",
			callID = "call_a",
			time = { created = 10 },
		})
		wait_for(function()
			return permission_state.has_permission("perm_a")
		end, "permission A should be tracked")

		bus.emit("permission", {
			requestID = "perm_b",
			permission = "bash",
			sessionID = "match_test_session",
			messageID = "match_msg",
			callID = "call_b",
			time = { created = 20 },
		})
		wait_for(function()
			return permission_state.has_permission("perm_b")
		end, "permission B should be tracked")

		assert_eq(#pending_ids, 2, "both permissions should be pending")
		assert_eq(pending_ids[1], "perm_a", "first permission should be perm_a")
		assert_eq(pending_ids[2], "perm_b", "second permission should be perm_b")

		bus.clear()
		bus.clear_history()
		state.reset()
		permission_state.clear_all()
		sync.clear_all()
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
