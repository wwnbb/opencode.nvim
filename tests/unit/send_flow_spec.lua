-- Unit checks for deterministic send-flow behavior.
-- Run with: ./tests/run.sh unit

describe("opencode send flow", function()
	it("handles session creation and send variants", function()
vim.opt.runtimepath:append(vim.fn.getcwd())

local calls = {}
local deferred = {}

local function fresh_calls()
	calls = {
		chat_messages = {},
		create_sessions = {},
		emitted = {},
		get_messages = {},
		notifications = {},
		send_async = {},
		send_sync = {},
		warnings = {},
		ensure_connected = 0,
	}
	deferred = {}
end

fresh_calls()

vim.schedule = function(fn)
	fn()
end

vim.defer_fn = function(fn, timeout)
	table.insert(deferred, { fn = fn, timeout = timeout })
end

vim.notify = function(message, level)
	table.insert(calls.notifications, { message = message, level = level })
end

local client_stub = {
	next_async_error = nil,
	next_create_error = nil,
	next_create_session = nil,
	next_messages = {},
	next_messages_error = nil,
	next_send_error = nil,
	next_send_response = nil,
}

function client_stub.setup(opts)
	calls.client_setup = opts
end

function client_stub.create_session(opts, callback)
	table.insert(calls.create_sessions, opts)
	callback(client_stub.next_create_error, client_stub.next_create_session or { id = "created", title = "Created" })
end

function client_stub.send_message_async(session_id, payload, callback)
	table.insert(calls.send_async, { session_id = session_id, payload = payload })
	callback(client_stub.next_async_error)
end

function client_stub.send_message(session_id, payload, opts, callback)
	table.insert(calls.send_sync, { session_id = session_id, payload = payload, opts = opts })
	callback(client_stub.next_send_error, client_stub.next_send_response)
end

function client_stub.get_messages(session_id, opts, callback)
	table.insert(calls.get_messages, { session_id = session_id, opts = opts })
	callback(client_stub.next_messages_error, client_stub.next_messages)
end

package.preload["opencode.client"] = function()
	return client_stub
end

package.preload["opencode.lifecycle"] = function()
	return {
		setup = function(opts)
			calls.lifecycle_setup = opts
		end,
		ensure_connected = function(callback)
			calls.ensure_connected = calls.ensure_connected + 1
			callback()
		end,
	}
end

package.preload["opencode.events"] = function()
	return {
		setup = function()
			calls.events_setup = true
		end,
		emit = function(event_type, data)
			table.insert(calls.emitted, { event_type = event_type, data = data })
		end,
	}
end

package.preload["opencode.ui.chat"] = function()
	return {
		add_message = function(role, message, opts)
			table.insert(calls.chat_messages, { role = role, message = message, opts = opts })
		end,
	}
end

package.preload["opencode.ui.chat.render_coordinator"] = function()
	return {
		request = function() end,
	}
end

package.preload["opencode.logger"] = function()
	return {
		debug = function() end,
		warn = function(_, data)
			table.insert(calls.warnings, data)
		end,
		error = function() end,
	}
end

package.preload["opencode.local"] = function()
	return {
		setup = function() end,
		agent = {
			current = function()
				return nil
			end,
		},
		model = {
			current = function()
				return nil
			end,
			parsed = function()
				return nil
			end,
		},
		variant = {
			current = function()
				return nil
			end,
		},
	}
end

package.preload["opencode.artifact.changes"] = function()
	return {
		setup = function() end,
		get_pending = function()
			return {}
		end,
	}
end

package.preload["opencode.ui.palette"] = function()
	return {
		setup = function() end,
	}
end

package.preload["opencode.slash"] = function()
	return {
		register_defaults = function() end,
	}
end

package.preload["opencode.components.lualine"] = function()
	return {
		setup = function() end,
	}
end

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_truthy(value, message)
	if not value then
		error(message)
	end
end

local function reset_client()
	client_stub.next_async_error = nil
	client_stub.next_create_error = nil
	client_stub.next_create_session = nil
	client_stub.next_messages = {}
	client_stub.next_messages_error = nil
	client_stub.next_send_error = nil
	client_stub.next_send_response = nil
end

local opencode = require("opencode")
opencode.setup({
	lualine = { enabled = false },
	session = {
		default_agent = "Build",
		default_model = { providerID = "p1", modelID = "m1" },
		parallel = {
			enabled = true,
			use_prompt_async = true,
		},
	},
})

local state = require("opencode.state")
local sync = require("opencode.sync")
local session_actions = require("opencode.session")

local function reset_world(use_prompt_async)
	state.reset()
	sync.clear_all()
	sync.handle_providers({
		{ id = "p1", name = "Provider 1", models = { m1 = { name = "Model 1" } } },
	})
	sync.handle_agents({
		{ id = "build", name = "Build" },
	})

	local cfg = state.get_config()
	cfg.session.default_agent = "Build"
	cfg.session.default_model = { providerID = "p1", modelID = "m1" }
	cfg.session.parallel = {
		enabled = true,
		use_prompt_async = use_prompt_async ~= false,
	}
	state.set_config(cfg)

	reset_client()
	fresh_calls()
end

local function has_event(event_type, action)
	for _, emitted in ipairs(calls.emitted) do
		if emitted.event_type == event_type and (not action or emitted.data.action == action) then
			return true
		end
	end
	return false
end

local function find_part(parts, predicate)
	for _, part in ipairs(parts) do
		if predicate(part) then
			return part
		end
	end
	return nil
end

reset_world(true)
session_actions.set_active("session_async", "Async", { preserve_cache = true })
fresh_calls()

opencode.send("hello async", {
	context = {
		{ type = "text", text = "context", _marker = { row = 1 } },
	},
	parts = {
		{ type = "file", mime = "image/png", filename = "shot.png", _marker = true },
	},
	variant = "fast",
})

assert_eq(calls.ensure_connected, 1, "public send should use lifecycle connection guard")
assert_eq(#calls.send_async, 1, "default config should send through prompt_async")
assert_eq(#calls.send_sync, 0, "async send should not call sync endpoint")

local async_payload = calls.send_async[1].payload
assert_truthy(async_payload.messageID:match("^msg_") ~= nil, "payload should include generated message id")
assert_eq(#async_payload.parts, 3, "payload should include text, context, and attachment parts")
assert_eq(async_payload.agent, "Build", "payload should use configured default agent")
assert_eq(async_payload.model.providerID, "p1", "payload should use configured provider")
assert_eq(async_payload.model.modelID, "m1", "payload should use configured model")
assert_eq(async_payload.variant, "fast", "payload should pass variant")
assert_eq(async_payload.parts[2]._marker, nil, "context markers should be stripped")
assert_eq(async_payload.parts[3]._marker, nil, "attachment markers should be stripped")
assert_truthy(async_payload.parts[2].id ~= nil, "context part should receive an id")
assert_truthy(async_payload.parts[3].id ~= nil, "attachment part should receive an id")

local async_messages = sync.get_messages("session_async")
assert_eq(#async_messages, 1, "async send should seed one local user message")
assert_eq(async_messages[1].id, async_payload.messageID, "seeded message id should match payload")
assert_eq(async_messages[1].role, "user", "seeded message should be a user message")
assert_eq(state.get_status(), "streaming", "async accepted send should remain streaming")
assert_truthy(has_event("sync_changed", "seeded"), "async send should emit seeded sync_changed event")

local async_parts = sync.get_parts(async_payload.messageID)
assert_truthy(find_part(async_parts, function(part)
	return part.text == "hello async" and part.sessionID == "session_async"
end), "seeded text part should include session id")
assert_truthy(find_part(async_parts, function(part)
	return part.type == "file" and part.filename == "shot.png" and part.messageID == async_payload.messageID
end), "seeded attachment should include message id")

reset_world(false)
session_actions.set_active("session_sync", "Sync", { preserve_cache = true })
fresh_calls()

client_stub.next_send_response = {
	info = {
		id = "msg_assistant_response",
		role = "assistant",
		time = { created = 2 },
	},
	parts = {
		{ id = "prt_assistant_response", messageID = "msg_assistant_response", type = "text", text = "done" },
	},
}
client_stub.next_messages = {
	client_stub.next_send_response,
}

opencode.send("hello sync")

assert_eq(#calls.send_sync, 1, "sync config should call /message endpoint")
assert_eq(#calls.send_async, 0, "sync config should not call prompt_async")
assert_eq(calls.send_sync[1].opts.timeout, 0, "sync send should keep unbounded response timeout")
assert_eq(#calls.get_messages, 1, "sync send should refresh session messages after response")
assert_eq(state.get_status(), "idle", "sync send should return status to idle after completion")
assert_truthy(sync.get_message("session_sync", "msg_assistant_response") ~= nil, "sync response should hydrate assistant message")
assert_truthy(has_event("sync_changed", "prompt_response"), "sync response should emit prompt_response sync_changed event")

reset_world(true)
client_stub.next_create_session = { id = "session_created", title = "Created Title" }

opencode.send("hello new", { title = "Requested Title" })

assert_eq(#calls.create_sessions, 1, "missing active session should create one")
assert_eq(calls.create_sessions[1].title, "Requested Title", "created session should use requested title")
assert_eq(state.get_session().id, "session_created", "created session should become active")
assert_eq(#calls.send_async, 1, "created session should send after activation")
assert_eq(calls.send_async[1].session_id, "session_created", "send should target created session")

reset_world(true)
session_actions.set_active("session_fail", "Fail", { preserve_cache = true })
client_stub.next_async_error = { message = "boom" }
fresh_calls()

opencode.send("hello failure")

assert_eq(#calls.send_async, 1, "failing async send should still attempt request")
assert_eq(state.get_status(), "idle", "failed send should return status to idle")
assert_eq(#calls.notifications, 1, "failed send should notify")
assert_truthy(
	calls.notifications[1].message:find("Failed to send message: boom", 1, true) ~= nil,
	"failed send notification should include error"
)
assert_eq(#calls.chat_messages, 1, "failed send should append system chat error")
assert_eq(calls.chat_messages[1].opts.session_id, "session_fail", "failed send chat error should target session")

print("Send flow checks passed")
	end)
end)
