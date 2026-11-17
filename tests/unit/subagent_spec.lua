local sync = require("opencode.sync")
local projection = require("opencode.protocol.messages")
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
	it("stops only the task whose subagent waits for the user", function()
		local function task(id, child)
			return { type = "tool", name = "subagent", id = id, state = { status = "completed", input = { agent = "build" },
				metadata = { sessionID = child, status = "running" }, content = {} } }
		end
		sync.handle_session_messages("s", { projection.project("s", { id = "m", type = "assistant",
			content = { task("call-a", "child-a"), task("call-b", "child-b") } }) })
		local parts = sync.get_parts("m")
		local animation = require("opencode.ui.chat.task_animation")
		local app, edits = require("opencode.state"), require("opencode.edit.state")
		sync.handle_session_status("child-a", { type = "busy" })
		sync.handle_session_status("child-b", { type = "busy" })
		-- The review belongs to a subagent nested under child-a.
		app.upsert_session({ id = "grandchild-a", parentID = "child-a" }, { touch = false })
		edits.add_edit("review-a", "grandchild-a", { { filePath = "a.lua", before = "", after = "x" } })
		local ok, failure = xpcall(function()
			assert.equals("waiting", animation.task_status(parts[1]))
			assert.equals("◈", animation.get_task_status_icon("waiting"))
			assert.is_false(animation.is_animating_tool_part(parts[1]))
			assert.equals("running", animation.task_status(parts[2]))
			assert.is_true(animation.is_animating_tool_part(parts[2]))
			edits.clear_all()
			assert.equals("running", animation.task_status(parts[1]))
			assert.is_true(animation.is_animating_tool_part(parts[1]))
		end, debug.traceback)
		edits.clear_all()
		assert.is_true(ok, failure)
	end)
	it("animates only the latest task call that resumed a child session", function()
		local function task(message_id, call_id, description, status)
			return projection.project("s", { id = message_id, type = "assistant", content = {
				{ type = "tool", name = "subagent", id = call_id, state = { status = status,
					input = { agent = "heavy_coder", description = description },
					metadata = { sessionID = "child" }, content = {} } },
			} })
		end
		sync.handle_session_messages("s", {
			task("m1", "call-first", "Fix scanner page review findings", "completed"),
			task("m2", "call-resume", "Resume frontend review fixes", "running"),
		})
		sync.handle_session_messages("child", { projection.project("child", { id = "cm", type = "assistant", content = {
			{ type = "tool", name = "bash", id = "shell", state = { status = "running", input = { command = "npx tsc --noEmit" }, content = {} } },
		} }) })
		sync.handle_session_status("child", { type = "busy" })
		local first, resumed = sync.get_parts("m1")[1], sync.get_parts("m2")[1]
		assert.equals("child", sync.get_task_child_session_for_part(first))
		assert.equals("child", sync.get_task_child_session_for_part(resumed))
		local animation = require("opencode.ui.chat.task_animation")
		local tasks = require("opencode.ui.chat.tasks")
		assert.equals("completed", animation.task_status(first))
		assert.is_false(animation.is_animating_tool_part(first))
		assert.equals("running", animation.task_status(resumed))
		assert.is_true(animation.is_animating_tool_part(resumed))
		local first_text = table.concat(tasks.render_task_tool(first, false).lines, "\n")
		local resumed_text = table.concat(tasks.render_task_tool(resumed, false).lines, "\n")
		assert.truthy(first_text:find("✓", 1, true), first_text)
		assert.is_nil(first_text:find("tsc", 1, true), first_text)
		assert.truthy(resumed_text:find("tsc", 1, true), resumed_text)
		sync.handle_session_status("child", { type = "idle", outcome = "failed" })
		assert.equals("completed", animation.task_status(first), "the earlier call keeps its own result")
		assert.equals("error", animation.task_status(resumed))
	end)
	it("renders streaming and interrupted tasks without reporting success", function()
		local animation = require("opencode.ui.chat.task_animation")
		local part = { tool = "task", state = { status = "streaming" } }
		assert.is_true(animation.is_animating_tool_part(part))
		part.state = { status = "completed", metadata = { sessionID = "child", status = "running" } }
		sync.handle_session_status("child", { type = "idle", outcome = "interrupted" })
		assert.equals("cancelled", animation.task_status(part))
		assert.is_false(animation.is_animating_tool_part(part))
		sync.handle_session_status("child", { type = "busy" })
		for _, status in ipairs({ "cancelled", "error" }) do
			part.state.status = status
			assert.equals(status, animation.task_status(part))
			assert.is_false(animation.is_animating_tool_part(part))
		end
	end)
end)
