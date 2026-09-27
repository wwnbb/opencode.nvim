-- Task navigation uses only the v2 child session ID carried by tool metadata.

describe("opencode task children", function()
	local children = require("opencode.ui.chat.task_children")

	local function task(id, child_id)
		return { id = id, messageID = "parent-message", tool = "task", state = {
			status = "running", input = { description = "Same task", subagent_type = "explore" },
			metadata = child_id and { sessionId = child_id } or {},
		} }
	end

	it("keeps parallel tasks with identical titles bound to their exact child IDs", function()
		local first, second = task("first", "child-one"), task("second", "child-two")
		assert.equals("child-one", children.get_task_child_session_id(first))
		assert.equals("child-two", children.get_task_child_session_id(second))
		second.state.metadata = { sessionID = "child-two" }
		assert.equals("child-two", children.get_task_child_session_id(second))
	end)

	it("does not guess a child when metadata arrives late", function()
		local part = task("late")
		local resolved
		children.resolve_task_child_session_id(part, function(err, id)
			assert.is_nil(err)
			resolved = id or false
		end)
		assert.is_false(resolved)
		part.state.metadata.sessionId = "child-late"
		assert.equals("child-late", children.get_task_child_session_id(part))
	end)

	it("ignores legacy aliases and empty IDs", function()
		local part = task("old")
		part.metadata = { childSessionID = "guessed", sessionId = "" }
		assert.is_nil(children.get_task_child_session_id(part))
	end)
end)
