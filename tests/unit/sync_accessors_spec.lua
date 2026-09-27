local sync = require("opencode.sync")
local events = require("opencode.events")

describe("sync render accessors and task ownership", function()
	before_each(function() sync.clear_all(); events.clear() end)
	after_each(function() sync.clear_all(); events.clear() end)

	it("filters synthetic text", function()
		sync.handle_part_updated({
			id = "text-visible",
			messageID = "msg_synthetic_filter",
			sessionID = "session_synthetic_filter",
			type = "text",
			text = "visible",
		})
		sync.handle_part_updated({
			id = "text-synthetic",
			messageID = "msg_synthetic_filter",
			sessionID = "session_synthetic_filter",
			type = "text",
			text = "hidden",
			synthetic = true,
		})
		assert(
			sync.get_message_text("msg_synthetic_filter", { include_synthetic = false }) == "visible",
			"synthetic text parts should be excluded when include_synthetic=false"
		)
	end)

	it("streams text and reasoning", function()
		local seq = 0
		local function event(kind, data)
			seq = seq + 1
			return sync.handle_v2_event({ id = "evt_stream_smoke_" .. seq, created = seq,
				type = "session." .. kind, data = vim.tbl_extend("force", {
					sessionID = "session_stream", assistantMessageID = "msg_stream", ordinal = 0,
				}, data or {}) })
		end
		event("step.started", { started = 1, agent = "build", model = { providerID = "test", id = "test" } })
		event("text.started")
		for _, delta in ipairs({ "hel", "lo", " world" }) do event("text.delta", { delta = delta }) end
		assert(sync.get_parts("msg_stream")[1].text == "hello world", "v2 text deltas should accumulate")
		event("text.ended", { text = "authoritative" })
		assert(sync.get_parts("msg_stream")[1].text == "authoritative", "v2 ended text should replace deltas")
		event("reasoning.started")
		event("reasoning.delta", { delta = "because" })
		assert(sync.get_message_render_parts("msg_stream").reasoning == "because", "v2 reasoning should stream")
	end)

	it("returns ordered parts and revision metadata", function()
		sync.handle_message_updated({
			id = "msg_render_accessor",
			sessionID = "session_render_accessor",
			role = "user",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "a_text",
			messageID = "msg_render_accessor",
			sessionID = "session_render_accessor",
			type = "text",
			text = "visible",
		})
		sync.handle_part_updated({
			id = "b_synthetic",
			messageID = "msg_render_accessor",
			sessionID = "session_render_accessor",
			type = "text",
			text = "hidden",
			synthetic = true,
		})
		sync.handle_part_updated({
			id = "c_reason",
			messageID = "msg_render_accessor",
			sessionID = "session_render_accessor",
			type = "reasoning",
			text = "why",
		})
		sync.handle_part_updated({
			id = "d_tool",
			messageID = "msg_render_accessor",
			sessionID = "session_render_accessor",
			type = "tool",
			tool = "bash",
			state = { status = "completed" },
		})
		local render_parts = sync.get_message_render_parts("msg_render_accessor", { include_synthetic = false })
		assert(render_parts.content == "visible", "render accessor should honor include_synthetic=false")
		assert(render_parts.reasoning == "why", "render accessor should collect reasoning")
		assert(#render_parts.tool_parts == 1 and render_parts.tool_parts[1].id == "d_tool", "render accessor should collect tools")
		assert(render_parts.parts[1].id == "a_text" and render_parts.parts[4].id == "d_tool", "render accessor should preserve part order")
		assert(render_parts.message_revision > 0, "render accessor should include message revision")
		assert(render_parts.part_revisions.a_text > 0, "render accessor should include part revisions")
	end)

	it("replaces and removes indexed task children", function()
		local event_util_for_tasks = require("opencode.events.util")
		sync.handle_message_updated({
			id = "task_index_message",
			sessionID = "task_parent",
			role = "assistant",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "task_index_part",
			messageID = "task_index_message",
			sessionID = "task_parent",
			type = "tool",
			tool = "task",
			metadata = { sessionId = "task_child_a" },
		})
		assert(sync.get_task_parent_session("task_child_a") == "task_parent", "task child index should record parent")
		assert(event_util_for_tasks.session_owns_task_child("task_parent", "task_child_a"), "task ownership should use index")
		sync.handle_part_updated({
			id = "task_index_part",
			messageID = "task_index_message",
			sessionID = "task_parent",
			type = "tool",
			tool = "task",
			metadata = { sessionId = "task_child_b" },
		})
		assert(sync.get_task_parent_session("task_child_a") == nil, "task index should clear replaced child")
		assert(sync.get_task_parent_session("task_child_b") == "task_parent", "task index should record replacement child")
		sync.handle_part_removed("task_index_message", "task_index_part")
		assert(sync.get_task_parent_session("task_child_b") == nil, "task index should clear removed child")
	end)

	it("records late child mappings through the action boundary", function()
		local event_util_for_tasks = require("opencode.events.util")
		local actions_for_tasks = require("opencode.actions")

		sync.handle_message_updated({
			id = "task_state_message",
			sessionID = "task_state_parent",
			role = "assistant",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "task_state_part",
			messageID = "task_state_message",
			sessionID = "task_state_parent",
			type = "tool",
			tool = "task",
			state = { metadata = { sessionID = "task_state_child" } },
		})
		assert(sync.get_task_parent_session("task_state_child") == "task_state_parent", "state.metadata sessionID should index child")

		local sync_changed = 0
		events.on("sync_changed", function(data)
			if
				data
				and data.session_id == "task_state_parent"
				and data.message_id == "task_state_message"
				and data.part_id == "task_state_late_part"
			then
				sync_changed = sync_changed + 1
			end
		end)
		sync.handle_part_updated({
			id = "task_state_late_part",
			messageID = "task_state_message",
			sessionID = "task_state_parent",
			type = "tool",
			tool = "task",
			state = {
				status = "running",
				input = { subagent_type = "build", description = "late child" },
			},
		})
		sync.handle_message_updated({
			id = "task_state_late_child_msg",
			sessionID = "task_state_late_child",
			role = "assistant",
			time = { created = 2 },
		})
		sync.handle_part_updated({
			id = "task_state_late_child_tool",
			messageID = "task_state_late_child_msg",
			sessionID = "task_state_late_child",
			type = "tool",
			tool = "read",
			state = { status = "running", input = { filePath = "/tmp/late.lua" } },
		})
		assert(
			actions_for_tasks.record_task_child_session(
				"task_state_parent",
				"task_state_message",
				"task_state_late_part",
				"task_state_late_child"
			) == true,
			"action boundary should record late child mapping"
		)
		assert(sync_changed == 1, "late child mapping should emit one parent part sync_changed event")
		assert(
			event_util_for_tasks.session_owns_task_child("task_state_parent", "task_state_late_child"),
			"late mapped child should be relevant to the parent"
		)
	end)
end)
