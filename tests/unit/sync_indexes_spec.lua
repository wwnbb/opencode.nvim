local projection = require("opencode.protocol.messages")

local function new_store()
	return assert(loadfile("lua/opencode/sync.lua"))()
end

local function message(id, created, session_id)
	return { id = id, sessionID = session_id or "s", role = "assistant", type = "assistant",
		time = { created = created } }
end

describe("private sync message indexes and metadata generations", function()
	local sync, original_insert, original_remove
	before_each(function()
		sync = new_store()
		original_insert, original_remove = table.insert, table.remove
	end)
	after_each(function()
		table.insert, table.remove = original_insert, original_remove
		sync.clear_all()
	end)

	it("keeps lookup positions correct across insertion, reorder, removal and session moves", function()
		for _, item in ipairs({ message("b", 20), message("a", 20), message("c", 40), message("z", nil) }) do
			sync.handle_message_updated(item)
		end
		local array = sync.get_messages("s")
		assert.same({ "a", "b", "c", "z" }, vim.tbl_map(function(item) return item.id end, array))
		sync.handle_message_updated(message("z", 10))
		assert.equals("z", array[1].id)
		sync.handle_message_removed("s", "a")
		assert.is_nil(sync.get_message("s", "a"), "removed ID must no longer resolve after chronological sorting")
		sync.handle_message_updated(message("b", 30, "other"))
		assert.is_nil(sync.get_message("s", "b"))
		assert.equals("other", sync.find_message_session_id("b"))
		assert.equals("b", sync.get_message("other", "b").id)
		assert.equals(array, sync.get_messages("s"))
		for _, item in ipairs(array) do assert.equals(item, sync.get_message("s", item.id)) end
		assert.same({ "z", "c" }, vim.tbl_map(function(item) return item.id end, array))
	end)

	it("replaces unchanged sort keys without shifting the live backing array", function()
		for index = 1, 30 do sync.handle_message_updated(message("m" .. index, index)) end
		local array = sync.get_messages("s")
		local inserts, removes = 0, 0
		table.insert = function(target, ...)
			if target == array then inserts = inserts + 1 end
			return original_insert(target, ...)
		end
		table.remove = function(target, ...)
			if target == array then removes = removes + 1 end
			return original_remove(target, ...)
		end
		local replacement = vim.deepcopy(sync.get_message("s", "m15"))
		replacement.agent = "changed"
		assert.is_true(sync.handle_message_updated(replacement))
		assert.equals(replacement, array[15])
		assert.equals(0, inserts)
		assert.equals(0, removes)
		assert.equals(replacement, sync.get_message("s", "m15"))
	end)

	it("normalizes invalid sort times and reorders an updated live message", function()
		sync.handle_message_updated(message("b", math.huge))
		sync.handle_message_updated(message("a", nil))
		sync.handle_message_updated(message("c", 1))
		assert.same({ "c", "a", "b" }, vim.tbl_map(function(item) return item.id end, sync.get_messages("s")))
		local live = sync.get_message("s", "b")
		live.time.created = 0
		sync.handle_message_updated(live)
		assert.equals(live, sync.get_messages("s")[1])
		assert.equals(live, sync.get_message("s", "b"))
	end)

	it("keeps scalar history generations stable across deltas and equal replacements", function()
		sync.handle_session_messages("s", projection.page("s", {
			{ id = "u", type = "user", text = "prompt", time = { created = 1 } },
		}))
		local sequence = 1
		local function event(kind, data)
			sequence = sequence + 1
			return sync.handle_server_event({ id = "evt" .. sequence, created = sequence, type = "session." .. kind,
				data = vim.tbl_extend("force", { sessionID = "s", assistantMessageID = "a" }, data or {}) })
		end
		event("step.started", { started = 2, agent = "build", model = { id = "test", providerID = "test" } })
		event("text.started")
		event("reasoning.started")
		event("tool.input.started", { id = "call", name = "read" })
		local generation = sync.get_history_metadata_generation("s")
		for _, item in ipairs({ { "text.delta", { delta = "text" } },
			{ "reasoning.delta", { delta = "reason" } }, { "tool.input.delta", { id = "call", delta = "{" } } }) do
			event(item[1], item[2])
			assert.equals(generation, sync.get_history_metadata_generation("s"))
		end
		local replacement = vim.deepcopy(sync.get_message("s", "a"))
		assert.is_false(sync.handle_message_updated(replacement))
		assert.equals(generation, sync.get_history_metadata_generation("s"))
		-- This fallback commit transiently strips and restores the derived parent.
		event("text.delta", { delta = " more" })
		assert.equals("u", sync.get_message("s", "a").parentID)
		assert.equals(generation, sync.get_history_metadata_generation("s"))
	end)

	it("invalidates all scalar metadata dependencies and never resurrects a cleared generation", function()
		sync.handle_message_updated(message("a", 1))
		local changes = {
			function(item) item.agent = "plan" end,
			function(item) item.parentID = "parent" end,
			function(item) item.time.streamed = 10 end,
			function(item) item.tokens = { output = 10, reasoning = 1 } end,
			function(item) item.provisional = true end,
			function(item) item.type = "synthetic" end,
			function(item) item.role = "system" end,
		}
		for _, change in ipairs(changes) do
			local generation = sync.get_history_metadata_generation("s")
			local next_message = vim.deepcopy(sync.get_message("s", "a"))
			change(next_message)
			sync.handle_message_updated(next_message)
			assert.is_true(sync.get_history_metadata_generation("s") > generation)
		end
		local generation = sync.get_history_metadata_generation("s")
		sync.clear_session_messages("s")
		assert.is_true(sync.get_history_metadata_generation("s") > generation)
		generation = sync.get_history_metadata_generation("s")
		sync.handle_message_updated(message("a", 1))
		sync.clear_all()
		assert.is_true(sync.get_history_metadata_generation("s") > generation)
		assert.is_nil(sync.get_message("s", "a"))
		sync.handle_message_updated(message("a", 1))
		assert.equals(sync.get_messages("s")[1], sync.get_message("s", "a"))
	end)

	it("updates metadata generations for finalize_inflight in-place timing changes", function()
		sync.handle_message_updated(message("a", 1))
		local generation = sync.get_history_metadata_generation("s")
		sync.finalize_inflight("s")
		assert.is_true(sync.get_history_metadata_generation("s") > generation)
	end)

	for _, clear in ipairs({ "clear_session", "clear_session_messages" }) do
		it("clears message indexes and caches with the status semantics of " .. clear, function()
			sync.handle_message_updated(message("a", 1))
			sync.handle_part_updated({ id = "task", messageID = "a", sessionID = "s", type = "tool",
				tool = "task", state = { metadata = { sessionID = "child" } } })
			sync.handle_session_status("s", { type = "busy" })
			sync.get_message_render_parts("a")
			local other = message("b", 2, "other")
			sync.handle_message_updated(other)
			local revision = sync.get_session_revision("s")
			local generation = sync.get_history_metadata_generation("s")
			local summary_revision = sync.get_task_summary_revision("s")
			local snapshot = sync.capture_session_snapshot("s")

			sync[clear]("s")

			assert.same({}, sync.get_messages("s"))
			assert.is_nil(sync.get_message("s", "a"))
			assert.is_nil(sync.find_message_session_id("a"))
			assert.same({}, sync.get_parts("a"))
			assert.same({}, sync.get_message_render_parts("a").tool_parts)
			assert.equals(0, sync.get_part_revision("a", "task"))
			assert.is_nil(sync.get_task_child_session("a", "task"))
			assert.is_nil(sync.get_task_parent_session("child"))
			assert.is_nil(sync.get_task_child_owner("child"))
			assert.is_true(sync.get_history_metadata_generation("s") > generation)
			assert.equals(summary_revision + 1, sync.get_task_summary_revision("s"))
			assert.equals(snapshot.session_generation + 1, sync.capture_session_snapshot("s").session_generation)
			assert.equals(other, sync.get_message("other", "b"))
			if clear == "clear_session" then
				assert.is_nil(sync.get_session_status("s"))
				assert.equals(0, sync.get_session_revision("s"))
			else
				assert.same({ type = "busy" }, sync.get_session_status("s"))
				assert.equals(revision + 1, sync.get_session_revision("s"))
			end
		end)
	end
end)
