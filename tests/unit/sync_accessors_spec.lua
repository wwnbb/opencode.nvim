local sync = require("opencode.sync")
local events = require("opencode.events")
local event_util = require("opencode.events.util")

describe("sync task ownership index", function()
	before_each(function() sync.clear_all(); events.clear() end)
	after_each(function() sync.clear_all(); events.clear() end)

	local function message(id, sid) sync.handle_message_updated({ id = id, sessionID = sid, role = "assistant", time = { created = 1 } }) end
	local function task(id, mid, sid, fields)
		sync.handle_part_updated(vim.tbl_extend("force", { id = id, messageID = mid, sessionID = sid, type = "tool", tool = "task" }, fields))
	end

	it("replaces and removes indexed task children", function()
		message("m", "parent")
		task("p", "m", "parent", { metadata = { sessionId = "child_a" } })
		assert.equals("parent", sync.get_task_parent_session("child_a"))
		assert.is_true(event_util.session_owns_task_child("parent", "child_a"))
		task("p", "m", "parent", { metadata = { sessionId = "child_b" } })
		assert.is_nil(sync.get_task_parent_session("child_a"))
		assert.equals("parent", sync.get_task_parent_session("child_b"))
		sync.handle_part_removed("m", "p")
		assert.is_nil(sync.get_task_parent_session("child_b"))
	end)

	it("records late child mappings through the action boundary with one parent change", function()
		message("m", "parent")
		task("p", "m", "parent", { state = { metadata = { sessionID = "indexed" } } })
		assert.equals("parent", sync.get_task_parent_session("indexed"))
		local changed = 0
		events.on("sync_changed", function(data)
			if data and data.session_id == "parent" and data.message_id == "m" and data.part_id == "late" then changed = changed + 1 end
		end)
		task("late", "m", "parent", { state = { status = "running", input = { subagent_type = "build", description = "late" } } })
		message("child_msg", "late_child")
		assert.is_true(require("opencode.actions").record_task_child_session("parent", "m", "late", "late_child"))
		assert.equals(1, changed)
		assert.is_true(event_util.session_owns_task_child("parent", "late_child"))
	end)
end)
