local sync = require("opencode.sync")
local projection = require("opencode.protocol.v2.messages")
describe("native subagent projection", function()
	before_each(function() sync.clear_all() end)
	after_each(function() sync.clear_all() end)
	it("retains exact child IDs for identical titles and displays the recorded provider errors", function()
		local data = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/subagent/subagent-parent.json"), "\n"))
		local sid = "parent"
		sync.handle_session_messages(sid, projection.page(sid, data.data))
		local children, count = {}, 0
		for _, message in ipairs(sync.get_messages(sid)) do
			for _, part in ipairs(sync.get_parts(message.id)) do
				if part.raw_tool == "subagent" then
					count = count + 1
					assert.equals("task", part.tool)
					assert.equals("explore", part.state.input.subagent_type)
					assert.equals("Small test", part.state.input.description)
					local child = sync.get_task_child_session_for_part(part)
					assert.equals(part.state.metadata.sessionID, child)
					assert.is_nil(children[child]); children[child] = true
					local rendered = require("opencode.ui.chat.tasks").render_task_tool(part, false)
					assert.truthy(table.concat(rendered.lines, "\n"):find("free tier", 1, true))
					assert.equals("error", require("opencode.ui.chat.task_animation").task_status(part))
				end
			end
		end
		assert.equals(2, count)
	end)
	it("keeps background delegation animated until the child is idle", function()
		local item = projection.project("s", { id = "m", type = "assistant", content = {
			{ type = "tool", name = "subagent", id = "call", state = { status = "completed", input = { agent = "build" }, metadata = { sessionID = "child", status = "running" }, content = {} } },
		} })
		sync.handle_session_messages("s", { item })
		local part = sync.get_parts("m")[1]
		local animation = require("opencode.ui.chat.task_animation")
		sync.handle_session_status("child", { type = "busy" })
		assert.equals("running", animation.task_status(part))
		assert.is_true(animation.is_animating_tool_part(part))
		sync.handle_session_status("child", { type = "idle" })
		assert.equals("completed", animation.task_status(part))
		assert.is_false(animation.is_animating_tool_part(part))
	end)
end)
