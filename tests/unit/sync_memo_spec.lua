local memo = require("opencode.util.memo")

local function new_store() return assert(loadfile("lua/opencode/sync.lua"))() end
local function part(id, order, kind, fields)
	return vim.tbl_extend("force", { id = id, messageID = "m", sessionID = "s", type = kind,
		content_order = order }, fields or {})
end

describe("sync part sorting and derived memo ownership", function()
	local sync, original_sort, original_project
	before_each(function()
		memo.clear_all()
		sync = new_store()
		original_sort = table.sort
		original_project = require("opencode.protocol.v2.messages").project
	end)
	after_each(function()
		table.sort = original_sort
		require("opencode.protocol.v2.messages").project = original_project
		sync.clear_all()
		memo.clear_all()
	end)

	it("returns fresh sorted containers and current objects after equal replacements", function()
		local text = part("z", 1, "text", { text = "visible" })
		local synthetic = part("y", 2, "text", { text = "hidden", synthetic = true })
		local tool = part("a", 3, "tool", { tool = "read", state = { status = "completed", input = { path = "a" } } })
		for _, value in ipairs({ text, synthetic, tool }) do sync.handle_part_updated(value) end
		local first = sync.get_message_render_parts("m")
		assert.equals("visiblehidden", first.content)
		assert.equals("visible", sync.get_message_render_parts("m", { include_synthetic = false }).content)
		assert.equals(text, first.parts[1])
		assert.equals(tool, first.tool_parts[1])
		first.parts[1], first.tool_parts[1], first.part_revisions.a = nil, nil, -1
		local second = sync.get_message_render_parts("m")
		assert.equals(text, second.parts[1])
		assert.equals(tool, second.tool_parts[1])
		assert.is_true(second.part_revisions.a > 0)
		assert.is_not.equals(first, second)
		assert.is_not.equals(first.parts, second.parts)
		local replacement = vim.deepcopy(tool)
		local revision = sync.get_part_revision("m", "a")
		assert.is_false(sync.handle_part_updated(replacement))
		assert.equals(revision, sync.get_part_revision("m", "a"))
		assert.equals(replacement, sync.get_message_render_parts("m").tool_parts[1])
		assert.equals(replacement, sync.get_parts("m")[3])
	end)

	it("preserves the legacy live unsorted array and exposes fresh revision maps", function()
		local tool = part("a", nil, "tool", { tool = "task", state = { status = "running", input = {} } })
		sync.handle_message_updated({ id = "m", sessionID = "s", role = "assistant", time = { created = 1 } })
		sync.handle_part_updated(tool)
		local array = sync.get_store().part.m
		assert.equals(array, sync.get_parts("m"))
		assert.equals(array, sync.get_message_render_parts("m").parts)
		local old = sync.get_message_render_parts("m")
		sync.record_task_child_session("s", "m", "a", "child")
		local current = sync.get_message_render_parts("m")
		assert.is_true(current.part_revisions.a > old.part_revisions.a)
		assert.is_true(current.message_revision > old.message_revision)
		sync.finalize_inflight("s")
		assert.equals("interrupted", sync.get_message_tools("m")[1].state.status)
	end)

	it("does not share memo owners between independent stores with matching IDs", function()
		local other = new_store()
		sync.handle_part_updated(part("p", 1, "text", { text = "first" }))
		other.handle_part_updated(part("p", 1, "text", { text = "second" }))
		assert.equals("first", sync.get_message_text("m"))
		assert.equals("second", other.get_message_text("m"))
		sync.clear_all()
		assert.equals("second", other.get_message_text("m"))
		other.clear_all()
	end)

	it("reuses sorted history beyond the previous 1000-entry cache default", function()
		local sorts = 0
		table.sort = function(...)
			sorts = sorts + 1
			return original_sort(...)
		end
		for index = 1, 6000 do
			sync.handle_part_updated({ id = "p", messageID = "m" .. index, sessionID = "s", type = "text",
				content_order = 1, text = "text" })
			sync.get_message_render_parts("m" .. index)
		end
		assert.equals(6000, sorts)
		for index = 1, 6000 do assert.equals("text", sync.get_message_render_parts("m" .. index).content) end
		assert.equals(6000, sorts)
	end)

	it("recomputes exactly after owner replacement, removal and shared eviction", function()
		local sorts = 0
		table.sort = function(...)
			sorts = sorts + 1
			return original_sort(...)
		end
		sync.handle_part_updated(part("p", 1, "text", { text = "first" }))
		sync.get_parts("m"); sync.get_parts("m")
		assert.equals(1, sorts)
		sync.handle_part_updated(part("p", 1, "text", { text = "second" }))
		assert.equals("second", sync.get_message_text("m"))
		assert.equals(2, sorts)
		memo.clear_all()
		assert.equals("second", sync.get_message_text("m"))
		assert.equals(3, sorts)
		sync.handle_part_removed("m", "p")
		assert.same({}, sync.get_parts("m"))
		assert.equals("", sync.get_message_text("m"))
	end)

	it("bypasses projection for ordinary existing nonempty delta sequences", function()
		local projection = require("opencode.protocol.v2.messages")
		local calls, sequence = 0, 0
		projection.project = function(...)
			calls = calls + 1
			return original_project(...)
		end
		local function event(kind, data)
			sequence = sequence + 1
			return sync.handle_v2_event({ id = "evt" .. sequence, created = sequence, type = "session." .. kind,
				data = vim.tbl_extend("force", { sessionID = "s", assistantMessageID = "m" }, data or {}) })
		end
		event("step.started", { started = 1, agent = "build", model = { id = "test", providerID = "test" } })
		event("text.started"); event("reasoning.started"); event("tool.input.started", { id = "call", name = "read" })
		local structural_calls = calls
		for _ = 1, 3 do
			assert.is_true(event("text.delta", { delta = "text" }).changed)
			assert.is_true(event("reasoning.delta", { delta = "why" }).changed)
			assert.is_true(event("tool.input.delta", { id = "call", delta = "x" }).changed)
		end
		assert.equals(structural_calls, calls)
		event("text.ended", { text = "authoritative" })
		assert.equals(structural_calls + 1, calls)
		assert.equals("authoritative", sync.get_message_text("m"))
		event("text.delta", { delta = "" })
		assert.equals(structural_calls + 2, calls)
	end)
end)
