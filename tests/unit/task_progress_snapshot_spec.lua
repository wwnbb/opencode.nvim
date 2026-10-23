local sync = require("opencode.sync")
local projection = require("opencode.protocol.messages")
local children = require("opencode.ui.chat.task_children")

describe("task progress across HTTP history snapshots", function()
	local sequence, history
	local function event(kind, data)
		sequence = sequence + 1
		data = vim.tbl_extend("force", { sessionID = "parent", assistantMessageID = "message" }, data or {})
		sync.handle_server_event({ id = "evt_progress_" .. sequence, created = sequence,
			type = "session." .. kind, data = data })
	end
	local function part(id)
		return sync.get_part("message", projection.part_id("parent", "message", "tool", id))
	end
	local function hydrate(native)
		local snapshot = sync.capture_session_snapshot("parent")
		sync.handle_session_messages("parent", { projection.project("parent", native or history) }, { snapshot = snapshot })
	end
	local function assert_children()
		local message = sync.get_message("parent", "message")
		for i, id in ipairs({ "first", "second" }) do
			local expected = { sessionID = "child-" .. id, status = "running" }
			local current = part(id)
			assert.same(expected, current.state.metadata)
			assert.same(expected, message._native.content[i].state.metadata)
			assert.same(expected, message.content[i].state.metadata)
			assert.equals(expected.sessionID, sync.get_task_child_session("message", current.id))
			local resolved
			children.resolve_task_child_session_id(current, function(err, child)
				assert.is_nil(err)
				resolved = child
			end)
			assert.equals(expected.sessionID, resolved)
		end
	end

	before_each(function()
		sync.clear_all()
		sequence = 0
		event("step.started", { started = 1, agent = "build" })
		for _, id in ipairs({ "first", "second" }) do
			event("tool.input.started", { id = id, name = "subagent" })
			event("tool.called", { id = id, input = { agent = "general", description = "Same task" } })
		end
		-- Progress is ephemeral: REST retains the running calls with empty metadata.
		history = vim.deepcopy(sync.get_message("parent", "message")._native)
		for _, id in ipairs({ "first", "second" }) do
			event("tool.progress", { id = id, metadata = { sessionID = "child-" .. id, status = "running" } })
		end
	end)
	after_each(function() sync.clear_all() end)

	it("retains exact parallel child links when the HTTP request starts after progress", function()
		assert_children()
		hydrate()
		assert_children()
		event("text.started", { ordinal = 0 })
		event("text.delta", { ordinal = 0, delta = "Still working" })
		assert_children()
		assert.same({}, history.content[1].state.metadata)
		assert.same({}, history.content[2].state.metadata)
	end)

	it("keeps replacement progress authoritative after hydration", function()
		hydrate()
		event("tool.progress", { id = "first", metadata = { sessionID = "replacement", status = "running" } })
		assert.equals("replacement", children.get_task_child_session_id(part("first")))
		event("tool.progress", { id = "first", metadata = {} })
		assert.is_nil(children.get_task_child_session_id(part("first")))
		hydrate()
		assert.is_nil(children.get_task_child_session_id(part("first")))
	end)

	it("does not reuse progress when the same call ID has a different execution time", function()
		local restarted = vim.deepcopy(history)
		restarted.content[1].time.ran = 100
		hydrate(restarted)
		assert.same({}, part("first").state.metadata)
		assert.is_nil(children.get_task_child_session_id(part("first")))
		assert.equals("child-second", children.get_task_child_session_id(part("second")))
	end)

	for _, status in ipairs({ "completed", "error" }) do
		it("accepts terminal " .. status .. " history without reviving progress", function()
			hydrate()
			local terminal = vim.deepcopy(history)
			terminal.content[1].state = { status = status, input = {}, metadata = {}, content = {} }
			hydrate(terminal)
			assert.equals(status, part("first").state.status)
			assert.is_nil(children.get_task_child_session_id(part("first")))
			event("text.started", { ordinal = 0 })
			assert.is_nil(children.get_task_child_session_id(part("first")))
		end)
	end

	it("uses terminal event metadata and clears it for a new execution", function()
		hydrate()
		event("tool.success", { id = "first", metadata = { sessionID = "finished-child", status = "completed" }, content = {} })
		assert.equals("finished-child", children.get_task_child_session_id(part("first")))
		event("tool.failed", { id = "second", metadata = {}, error = { message = "Failed" } })
		assert.is_nil(children.get_task_child_session_id(part("second")))
		event("tool.called", { id = "first", input = { agent = "general", description = "Retry" } })
		assert.is_nil(children.get_task_child_session_id(part("first")))
		hydrate(sync.get_message("parent", "message")._native)
		assert.is_nil(children.get_task_child_session_id(part("first")))
	end)

	it("forgets progress when a call is removed or its session history is cleared", function()
		hydrate()
		local removed = vim.deepcopy(history)
		removed.content = {}
		hydrate(removed)
		assert.is_nil(part("first"))
		hydrate()
		assert.is_nil(children.get_task_child_session_id(part("first")))
		event("tool.progress", { id = "first", metadata = { sessionID = "child-first" } })
		sync.clear_session_messages("parent")
		hydrate()
		assert.is_nil(children.get_task_child_session_id(part("first")))
	end)
end)
