local reducer = require("opencode.sync.v2")
local projection = require("opencode.protocol.v2.messages")

-- The reference deliberately omits the private reducer hooks. It still executes
-- the original full native copy, projection, hydration, and ancestry pass.
local function fresh_store()
	return assert(loadfile("lua/opencode/sync.lua"))()
end

local function pack(...)
	return { n = select("#", ...), ... }
end

local observed_fields = {
	"message", "part", "session_status", "message_session", "message_revision",
	"part_revision", "session_revision", "session_generation", "snapshot_generation",
	"task_summary_revision", "task_summary_revision_counter", "task_child_parent",
	"task_child_owner", "task_part_child",
}

local function observation(sync)
	local raw = sync.get_store()
	local result = { store = {}, messages = {}, parts = {}, rendered = {}, snapshots = {}, tasks = {} }
	for _, key in ipairs(observed_fields) do result.store[key] = vim.deepcopy(raw[key]) end
	local message_ids = {}
	for sid, messages in pairs(raw.message) do
		result.messages[sid] = vim.deepcopy(sync.get_messages(sid))
		result.snapshots[sid] = sync.capture_session_snapshot(sid)
		for _, message in ipairs(messages) do
			message_ids[message.id] = true
			assert.same(message, sync.get_message(sid, message.id))
			assert.equals(sid, sync.find_message_session_id(message.id))
		end
	end
	-- Include orphan parts as well as messages with an empty content array.
	for mid in pairs(raw.part) do message_ids[mid] = true end
	for mid in pairs(message_ids) do
		result.parts[mid] = vim.deepcopy(sync.get_parts(mid))
		result.rendered[mid] = {
			all = vim.deepcopy(sync.get_message_render_parts(mid)),
			visible = vim.deepcopy(sync.get_message_render_parts(mid, { include_synthetic = false })),
		}
		for _, part in ipairs(result.parts[mid]) do
			assert.same(part, sync.get_part(mid, part.id))
			assert.equals(result.rendered[mid].all.part_revisions[part.id], sync.get_part_revision(mid, part.id))
		end
	end
	for child in pairs(raw.task_child_parent) do
		result.tasks[child] = {
			parent = sync.get_task_parent_session(child),
			owner = pack(sync.get_task_child_owner(child)),
		}
	end
	return result
end

local function new_pair()
	local pair = { reference = fresh_store(), optimized = fresh_store(), sequence = 0 }

	function pair:check(label)
		assert.same(observation(self.reference), observation(self.optimized), label)
	end

	function pair:call(method, ...)
		local args = pack(...)
		local expected_args, actual_args = vim.deepcopy(args), vim.deepcopy(args)
		local expected = pack(self.reference[method](unpack(expected_args, 1, expected_args.n)))
		local actual = pack(self.optimized[method](unpack(actual_args, 1, actual_args.n)))
		assert.same(expected, actual, method .. " return values")
		self:check(method)
		return unpack(expected, 1, expected.n)
	end

	function pair:page(sid, messages, opts)
		return self:call("handle_session_messages", sid, projection.page(sid, messages), opts)
	end

	function pair:event(kind, data, sid, mid)
		self.sequence = self.sequence + 1
		data = vim.deepcopy(data or {})
		data.sessionID, data.assistantMessageID = sid or "s", mid or "a"
		local event = { id = "evt_trace_" .. self.sequence, created = 100 + self.sequence,
			type = "session." .. kind, data = data }
		local expected = reducer.apply(self.reference, vim.deepcopy(event))
		local actual = self.optimized.handle_v2_event(vim.deepcopy(event))
		assert.same(expected, actual, kind .. " return values")
		self:check(kind)
		return expected
	end

	return pair
end

local function assistant(id, created, content, parent)
	return { id = id, type = "assistant", time = { created = created }, parentID = parent,
		agent = "build", model = { providerID = "test", id = "model" }, content = content }
end

local function text(value, synthetic)
	return { type = "text", text = value, synthetic = synthetic }
end

local function tool(id, status, input, name, metadata)
	return { type = "tool", id = id, name = name or "read", time = { created = 21 },
		state = { status = status, input = input, metadata = metadata or {} } }
end

describe("native delta fast path full-reducer equivalence", function()
	local pair
	before_each(function() pair = new_pair() end)
	after_each(function()
		pair.reference.clear_all()
		pair.optimized.clear_all()
	end)

	it("keeps the no-hooks oracle on full projection while a warm delta bypasses it", function()
		pair:page("s", { assistant("a", 20, { text("before") }) })
		pair:event("text.delta", { ordinal = 0, delta = "+warm" })
		local event = { id = "evt_work", created = 200, type = "session.text.delta",
			data = { sessionID = "s", assistantMessageID = "a", ordinal = 0, delta = "+next" } }
		local original_project, calls = projection.project, 0
		projection.project = function(...)
			calls = calls + 1
			return original_project(...)
		end
		local expected, actual, reference_calls, optimized_calls
		local ok, err = pcall(function()
			expected = reducer.apply(pair.reference, vim.deepcopy(event))
			reference_calls, calls = calls, 0
			actual = pair.optimized.handle_v2_event(vim.deepcopy(event))
			optimized_calls = calls
		end)
		projection.project = original_project
		assert.is_true(ok, err)
		assert.equals(1, reference_calls)
		assert.equals(0, optimized_calls)
		assert.same(expected, actual)
		pair:check("warm delta and full oracle work")
	end)

	it("matches every mixed streaming, ending, retry, and restarted-step event", function()
		pair:page("s", { { id = "user", type = "user", time = { created = 10 }, text = "prompt" } })
		pair:event("execution.started")
		pair:event("step.started", { started = 20, agent = "build", model = { providerID = "test", id = "model" } })
		pair:event("text.started", { ordinal = 0 })
		pair:event("text.delta", { ordinal = 0, delta = "first " })
		pair:event("reasoning.started", { ordinal = 0, state = { phase = "thinking", nested = { 1, 2 } } })
		pair:event("reasoning.delta", { ordinal = 0, delta = "why λ" })
		pair:event("text.delta", { ordinal = 0, delta = "🙂\nsecond" })
		pair:event("tool.input.started", { id = "call:one", name = "read" })
		pair:event("tool.input.delta", { id = "call:one", delta = '{"path":' })
		pair:event("tool.input.delta", { id = "call:one", delta = '"λ.lua"}' })
		pair:event("tool.input.ended", { id = "call:one", text = '{"path":"final.lua"}' })
		pair:event("tool.called", { id = "call:one", input = { path = "final.lua", options = { range = { 1, 2 } } } })
		pair:event("tool.progress", { id = "call:one", metadata = { old = true } })
		pair:event("tool.progress", { id = "call:one", metadata = { title = "Read", nested = { count = 1 } } })
		pair:event("tool.input.delta", { id = "call:one", delta = "ignored while running" })
		pair:event("tool.success", { id = "call:one", metadata = { title = "Complete" }, content = {
			{ type = "text", text = "line\n" }, { type = "file", uri = "file:///tmp/λ", name = "λ", mime = "text/plain" },
		} })
		pair:event("tool.input.delta", { id = "call:one", delta = "ignored after completion" })
		pair:event("text.started", { ordinal = 1 })
		pair:event("text.delta", { ordinal = 1, delta = "tail" })
		pair:event("text.delta", { ordinal = 1, delta = "" })
		pair:event("text.ended", { ordinal = 0, text = "replaced completely" })
		pair:event("text.delta", { ordinal = 0, delta = " + late delta" })
		pair:event("reasoning.ended", { ordinal = 0, text = "final reason", state = { phase = "done" } })
		pair:event("reasoning.delta", { ordinal = 0, delta = " + late reason" })
		pair:event("retry.scheduled", { attempt = 2, at = 1000, error = { message = "temporary" } })
		pair:event("step.failed", { error = { type = "failure", message = "retry exhausted" }, tokens = { input = 3 } })
		pair:event("step.started", { started = 30, agent = "build", model = { providerID = "test", id = "model" } })
		pair:event("text.delta", { ordinal = 1, delta = " after restart" })
		pair:event("step.ended", { finish = "stop", tokens = { input = 3, output = 8 }, cost = 0.1 })
		pair:event("execution.succeeded")
		assert.equals("replaced completely + late deltatail after restart", pair.optimized.get_message_text("a"))
		assert.equals("idle", pair.optimized.get_session_status("s").type)
	end)

	it("preserves out-of-order recovery and ambiguous or unsupported content fallbacks", function()
		for index = 1, 3 do
			local result = pair:event("text.delta", { ordinal = 5, delta = tostring(index) })
			assert.is_true(result.reconcile)
			assert.equals(index, #pair.optimized.get_message("s", "a")._v2.content)
		end
		pair:event("text.delta", { ordinal = 0, delta = " now existing" })
		pair:event("reasoning.delta", { ordinal = 3, delta = "orphan reason", state = { phase = "late" } })
		pair:event("tool.input.delta", { id = "late:tool", delta = "partial" })
		pair:event("tool.input.delta", { id = "late:tool", delta = "+next" })
		pair:event("message.content.updated", { content = {
			{ type = "future-kind", payload = { nested = { "opaque" } } }, text("known"),
			tool("duplicate", "streaming", "first"), tool("duplicate", "streaming", "second"),
		} })
		pair:event("text.delta", { ordinal = 0, delta = "+unknown sibling" })
		pair:event("tool.input.delta", { id = "duplicate", delta = "+only first native match" })
		local current = pair.optimized.get_message("s", "a")
		assert.equals("first+only first native match", current._v2.content[3].state.input)
		assert.equals("second", pair.optimized.get_part("a", projection.part_id("s", "a", "tool", "duplicate")).state.input)
		pair:event("message.content.updated", { content = { text("shorter"), text("hidden", true) } })
		pair:event("text.delta", { ordinal = 0, delta = "+fresh" })
		pair:event("text.ended", { ordinal = 1, text = "replacement synthetic" })
		assert.equals("shorter+fresh", pair.optimized.get_message_text("a", { include_synthetic = false }))
	end)

	it("detaches old message and every sibling part while preserving live backing arrays", function()
		local completed = tool("read", "completed", { path = "a.lua", options = { range = { 1, 3 } } })
		completed.state.content = {
			{ type = "text", text = "output" }, { type = "file", uri = "file:///tmp/a", name = "a", extra = { version = 1 } },
		}
		pair:page("s", { assistant("a", 20, {
			text("a"), { type = "reasoning", text = "reason", state = { nested = { value = 1 } }, time = { created = 20 } }, completed,
		}) })
		pair:event("text.delta", { ordinal = 0, delta = "b" })
		local held = {}
		for _, sync in ipairs({ pair.reference, pair.optimized }) do
			local message, parts = sync.get_message("s", "a"), sync.get_parts("a")
			held[#held + 1] = { sync = sync, message = message, parts = parts,
				message_value = vim.deepcopy(message), parts_value = vim.deepcopy(parts),
				messages_array = sync.get_messages("s"), parts_array = sync.get_store().part.a }
		end
		pair:event("text.delta", { ordinal = 0, delta = "c" })
		for _, old in ipairs(held) do
			local current, parts = old.sync.get_message("s", "a"), old.sync.get_parts("a")
			assert.same(old.message_value, old.message)
			assert.same(old.parts_value, old.parts)
			assert.is_false(rawequal(old.message, current))
			assert.is_true(rawequal(old.messages_array, old.sync.get_messages("s")))
			assert.is_true(rawequal(old.parts_array, old.sync.get_store().part.a))
			assert.is_true(rawequal(current, old.messages_array[1]))
			for index, part in ipairs(parts) do
				assert.is_false(rawequal(old.parts[index], part), "unchanged siblings must also be detached")
				assert.is_false(rawequal(current.content[index], current._v2.content[index]))
				assert.is_false(rawequal(part, current.content[index]))
				assert.is_false(rawequal(part, current._v2.content[index]))
			end
			assert.is_false(rawequal(current.content[3].state.input, current._v2.content[3].state.input))
			assert.is_false(rawequal(parts[3].state.input.options, current._v2.content[3].state.input.options))
			assert.is_false(rawequal(parts[3].state.files[1], parts[3].state.content[2]))
			local stable = observation(old.sync)
			old.message.content[1].text = "stale projected mutation"
			old.message._v2.content[3].state.input.options.range[1] = 999
			old.parts[2].state.nested.value = 999
			old.parts[3].state.input.options.range[2] = 999
			old.parts[3].state.content[2].extra.version = 999
			old.parts[3].state.files[1].extra.version = 998
			assert.same(stable, observation(old.sync), "held nested values must not alias the current store")
		end
		pair:check("mutations through detached old references")
		pair:event("reasoning.delta", { ordinal = 0, delta = "+new" })
	end)

	it("preserves ancestry revision effects after late parents, reorder, and equal replacements", function()
		for _, scenario in ipairs({ { sid = "none" }, { sid = "derived", parent = "native-old" }, { sid = "same", parent = "user-same" } }) do
			local sid, mid = scenario.sid, "a-" .. scenario.sid
			local page = { assistant(mid, 20, { text("initial"), tool("call", "streaming", "") }, scenario.parent) }
			if sid ~= "none" then table.insert(page, 1, { id = "user-" .. sid, type = "user", time = { created = 10 }, text = "parent" }) end
			pair:page(sid, page)
			pair:event("text.delta", { ordinal = 0, delta = "+first" }, sid, mid)
			local empty = pair:event("text.delta", { ordinal = 0, delta = "" }, sid, mid)
			assert.equals(sid == "derived", empty.changed)
			assert.is_nil(pair:event("unknown.event", {}, sid, mid).changed)
			pair:event("tool.input.delta", { id = "call", delta = '{"x":' }, sid, mid)
			pair:call("handle_message_updated", vim.deepcopy(pair.reference.get_message(sid, mid)))
			pair:call("handle_part_updated", vim.deepcopy(pair.reference.get_parts(mid)[1]))
			pair:event("text.delta", { ordinal = 0, delta = "+after equal replacement" }, sid, mid)
			pair:page(sid, { { id = "late-user-" .. sid, type = "user", time = { created = 15 }, text = "late parent" } })
			pair:event("text.delta", { ordinal = 0, delta = "+after late parent" }, sid, mid)
			assert.equals("late-user-" .. sid, pair.optimized.get_message(sid, mid).parentID)
			pair:event("step.started", { started = 5, agent = "build", model = { providerID = "test", id = "model" } }, sid, mid)
			pair:event("text.delta", { ordinal = 0, delta = "+after reorder" }, sid, mid)
			assert.equals(mid, pair.optimized.get_messages(sid)[1].id)
			assert.is_nil(pair.optimized.get_message(sid, mid).parentID)
		end
	end)

	it("keeps task binding side effects on the full path even for unchanged siblings", function()
		pair:page("s", { assistant("a", 20, {
			text("body"), tool("task-one", "running", { agent = "explore", prompt = "inspect" }, "subagent", { sessionID = "child-one" }),
			tool("task-two", "streaming", "", "subagent"),
		}) })
		pair:event("text.delta", { ordinal = 0, delta = "+bound sibling" })
		pair:event("text.delta", { ordinal = 0, delta = "+bound sibling again" })
		local second = projection.part_id("s", "a", "tool", "task-two")
		pair:call("record_task_child_session", "s", "a", second, "child-two")
		assert.equals("child-two", pair.optimized.get_task_child_session("a", second))
		pair:event("tool.input.delta", { id = "task-two", delta = "input" })
		-- A binding known only to the index is cleared by the original reprojection.
		assert.is_nil(pair.optimized.get_task_child_session("a", second))
		pair:event("tool.progress", { id = "task-one", metadata = { sessionID = "child-moved", title = "new owner" } })
		pair:event("text.delta", { ordinal = 0, delta = "+rebound" })
		assert.is_nil(pair.optimized.get_task_parent_session("child-one"))
		assert.equals("s", pair.optimized.get_task_parent_session("child-moved"))
		pair:call("record_task_child_session", "s", "a", second, "child-moved")
		pair:event("text.delta", { ordinal = 0, delta = "+transferred owner" })
		pair:call("handle_part_removed", "a", second)
		pair:event("tool.input.delta", { id = "task-two", delta = "+restored from native" })
	end)

	it("protects every live delta from stale HTTP pages and stale cleared-session snapshots", function()
		local original = {
			{ id = "user", type = "user", time = { created = 10 }, text = "prompt" },
			assistant("a", 20, { text("before"), tool("call", "streaming", "") }),
			assistant("ghost", 25, { text("remove on complete page") }),
			assistant("removed", 30, { text("remove during request") }),
		}
		pair:page("s", original)
		pair:event("text.delta", { ordinal = 0, delta = "+warm" })
		local snapshot = pair:call("capture_session_snapshot", "s")
		pair:event("text.delta", { ordinal = 0, delta = "+during request" })
		pair:event("tool.input.delta", { id = "call", delta = "live input" })
		pair:call("handle_message_removed", "s", "removed")
		pair:event("text.delta", { ordinal = 0, delta = "new live message" }, "s", "new")
		pair:page("s", { original[1], original[2], original[4] }, { snapshot = snapshot, reconcile = true, complete = true })
		assert.equals("before+warm+during request", pair.optimized.get_message_text("a"))
		assert.is_nil(pair.optimized.get_message("s", "removed"))
		assert.is_nil(pair.optimized.get_message("s", "ghost"))
		assert.is_not_nil(pair.optimized.get_message("s", "new"))
		pair:event("text.delta", { ordinal = 0, delta = "+after response" })
		local before_revert = pair:call("capture_session_snapshot", "s")
		pair:event("revert.committed", { to = "new" })
		pair:page("s", original, { snapshot = before_revert, reconcile = true, complete = true })
		for _, clear in ipairs({ "clear_session", "clear_session_messages", "clear_all" }) do
			local pending = pair:call("capture_session_snapshot", "s")
			pair:call(clear, "s")
			pair:page("s", original, { snapshot = pending, reconcile = true, complete = true })
			assert.same({}, pair.optimized.get_messages("s"))
			pair:page("s", original, { snapshot = pair:call("capture_session_snapshot", "s") })
			pair:event("text.delta", { ordinal = 0, delta = "+new generation" })
		end
	end)

	it("recovers after projected public mutations, part removal, finalization, and session moves", function()
		pair:page("s", { assistant("a", 20, { text("native"), tool("call", "streaming", "") }) })
		pair:event("text.delta", { ordinal = 0, delta = "+warm" })
		local first_id = projection.part_id("s", "a", "text", 0)
		local replacement = vim.deepcopy(pair.reference.get_part("a", first_id))
		replacement.text = "public projected replacement"
		pair:call("handle_part_updated", replacement)
		pair:event("text.delta", { ordinal = 0, delta = "+from native" })
		assert.equals("native+warm+from native", pair.optimized.get_message_text("a"))
		pair:call("handle_part_removed", "a", first_id)
		pair:event("text.delta", { ordinal = 0, delta = "+restored" })
		local original_now = vim.uv.now
		vim.uv.now = function() return 500 end
		local ok, err = pcall(function() pair:call("finalize_inflight", "s", { reason = "interrupted" }) end)
		vim.uv.now = original_now
		assert.is_true(ok, err)
		pair:event("tool.input.delta", { id = "call", delta = "+native streaming still authoritative" })
		local moved = projection.project("other", vim.deepcopy(pair.reference.get_message("s", "a")._v2))
		pair:call("handle_session_messages", "other", { moved })
		pair:event("text.delta", { ordinal = 0, delta = "+after move" }, "other", "a")
		assert.is_nil(pair.optimized.get_message("s", "a"))
		assert.equals("other", pair.optimized.find_message_session_id("a"))
		pair:event("text.delta", { ordinal = 0, delta = "out-of-order old session" }, "s", "a")
		assert.equals("s", pair.optimized.find_message_session_id("a"))
	end)
end)
