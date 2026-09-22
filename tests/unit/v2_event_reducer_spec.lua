local sync = require("opencode.sync")
local projection = require("opencode.protocol.v2.messages")

describe("v2 event reduction", function()
	before_each(function() sync.clear_all() end)
	after_each(function() sync.clear_all() end)
	local function fixture(name)
		return vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/runtime/" .. name .. ".json"), "\n"))
	end

	it("reconstructs the recorded MiMo response with the same identities and content as HTTP", function()
		local events, history = fixture("events"), fixture("history")
		local sid = fixture("session").data.id
		for _, event in ipairs(events) do
			if event.type == "session.execution.succeeded" then
				sync.handle_v2_event(event)
				break -- The fixture subsequently exercises duplicate admission.
			end
			sync.handle_v2_event(event)
		end
		local live = {}
		for _, message in ipairs(sync.get_messages(sid)) do
			live[message.id] = { info = vim.deepcopy(message), parts = vim.deepcopy(sync.get_parts(message.id)) }
		end
		local cold = projection.page(sid, history.data)
		for _, message in ipairs(cold) do
			assert.is_not_nil(live[message.info.id])
			assert.same(message.parts, live[message.info.id].parts)
			assert.same(message.info._v2, live[message.info.id].info._v2)
		end
		assert.equals("idle", sync.get_session_status(sid).type)
	end)

	it("replaces ended text, keeps tool progress metadata exact, and preserves order", function()
		local seq = 0
		local function event(kind, data)
			seq = seq + 1
			data.sessionID, data.assistantMessageID = "ses_test", "msg_test"
			return sync.handle_v2_event({ id = "evt_" .. seq, created = seq, type = "session." .. kind, data = data })
		end
		event("step.started", { agent = "build", model = { providerID = "test", id = "test" }, started = 1 })
		event("text.started", { ordinal = 0 })
		event("text.delta", { ordinal = 0, delta = "stale partial" })
		event("text.ended", { ordinal = 0, text = "Final" })
		event("tool.input.started", { id = "call_1", name = "rg" })
		event("tool.input.delta", { id = "call_1", delta = '{"pattern":' })
		event("tool.called", { id = "call_1", input = { pattern = "a" } })
		event("tool.progress", { id = "call_1", metadata = { old = true } })
		event("tool.progress", { id = "call_1", metadata = { title = "Searching" } })
		local parts = sync.get_parts("msg_test")
		assert.equals("Final", parts[1].text)
		assert.same({ title = "Searching" }, parts[2].state.metadata)
		local identity = parts[2].id
		event("tool.success", { id = "call_1", content = { { type = "text", text = "a.lua:1" } }, metadata = { title = "Search" } })
		event("text.started", { ordinal = 1 })
		event("text.ended", { ordinal = 1, text = "Done" })
		event("step.ended", { finish = "tool-calls" })
		parts = sync.get_parts("msg_test")
		assert.same({ "text", "tool", "text" }, vim.tbl_map(function(p) return p.type end, parts))
		assert.equals(identity, parts[2].id)
		assert.equals("a.lua:1", parts[2].state.output)
		assert.same({ pattern = "a" }, parts[2].state.input)
		event("step.started", { agent = "build", model = { providerID = "test", id = "test" }, started = 20 })
		assert.is_nil(sync.get_message("ses_test", "msg_test").finish)
		assert.is_nil(sync.get_message("ses_test", "msg_test").time.completed)
	end)

	it("retains a provisional unknown message and requests reconciliation", function()
		local result = sync.handle_v2_event({ id = "evt_orphan", created = 1, type = "session.text.delta",
			data = { sessionID = "ses_test", assistantMessageID = "msg_test", ordinal = 0, delta = "part" } })
		assert.is_true(result.reconcile)
		assert.equals("part", sync.get_parts("msg_test")[1].text)
		local snapshot = sync.capture_session_snapshot("ses_test")
		sync.handle_v2_event({ id = "evt_end", created = 2, type = "session.text.ended",
			data = { sessionID = "ses_test", assistantMessageID = "msg_test", ordinal = 0, text = "Full" } })
		sync.handle_session_messages("ses_test", projection.page("ses_test", { { id = "msg_test", type = "assistant", content = {}, time = { created = 1 } } }), { snapshot = snapshot })
		assert.equals("Full", sync.get_parts("msg_test")[1].text)
	end)
	it("drops committed undo messages and ignores an older in-flight history snapshot", function()
		local page = projection.page("s", {
			{ id = "msg_1", type = "user", text = "first" },
			{ id = "msg_2", type = "user", text = "second" },
			{ id = "msg_3", type = "assistant", content = { { type = "text", text = "last" } } },
		})
		sync.handle_session_messages("s", page)
		local snapshot = sync.capture_session_snapshot("s")
		sync.handle_v2_event({ id = "evt_4", created = 4, type = "session.revert.committed", data = { sessionID = "s", to = "msg_2" } })
		sync.handle_session_messages("s", page, { snapshot = snapshot, reconcile = true, complete = true })
		assert.equals(1, #sync.get_messages("s"))
		assert.equals("msg_1", sync.get_messages("s")[1].id)
		assert.same({}, sync.get_parts("msg_3"))
	end)

	it("prunes absence only from an explicitly complete history, preserving newer live messages", function()
		local page = projection.page("s", { { id = "msg_1", type = "user", text = "first" }, { id = "msg_2", type = "user", text = "removed" } })
		sync.handle_session_messages("s", page)
		sync.handle_session_messages("s", { page[1] }, { reconcile = true })
		assert.equals(2, #sync.get_messages("s"))
		local snapshot = sync.capture_session_snapshot("s")
		sync.handle_session_messages("s", projection.page("s", { { id = "msg_3", type = "user", text = "live" } }))
		sync.handle_session_messages("s", { page[1] }, { reconcile = true, complete = true, snapshot = snapshot })
		assert.equals(2, #sync.get_messages("s"))
		assert.is_nil(sync.get_message("s", "msg_2"))
		assert.is_not_nil(sync.get_message("s", "msg_3"))
	end)

end)
