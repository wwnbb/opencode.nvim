local chat_surface = require("tests.helpers.chat_surface")
local app = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local tasks = require("opencode.ui.chat.tasks")
local projection = require("opencode.protocol.messages")
local client = require("opencode.client")
local details = require("opencode.ui.chat.execute_details")

local parent_id, child_id = "task-tools-parent", "task-tools-child"

local function shell(id, command, output, status)
	return { type = "tool", id = id, name = "shell", time = { created = 10, ran = 11 }, state = {
		status = status or "completed", input = { command = command },
		content = { { type = "text", text = output or "" } }, metadata = {},
	} }
end

local function child_messages(content)
	return projection.page(child_id, {
		{ id = "child-prompt", type = "user", time = { created = 1 }, text = "Inspect child tools" },
		{ id = "child-answer", type = "assistant", time = { created = 2 }, content = content },
	})
end

local function seed(content, task_count)
	sync.handle_session_messages(child_id, child_messages(content))
	local parent_content = {}
	for index = 1, task_count or 1 do
		parent_content[#parent_content + 1] = { type = "tool", id = "task-" .. index, name = "subagent",
			time = { created = 3, ran = 4, completed = 5 }, state = {
				status = "completed", input = { agent = "general", description = "Inspect tools " .. index },
				metadata = { sessionID = child_id }, content = {},
			} }
	end
	parent_content[#parent_content + 1] = { type = "text", text = "Following parent answer" }
	local projected = projection.project(parent_id, {
		id = "parent-answer", type = "assistant", time = { created = 3, completed = 6 }, content = parent_content,
	})
	sync.handle_session_messages(parent_id, { projected })
	chat.do_render()
	local ids = {}
	for index = 1, task_count or 1 do ids[index] = projected.parts[index].id end
	return unpack(ids)
end

local function block_text(id)
	local pos = assert(state.tasks[id], "Missing owning Task")
	return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, pos.start_line, pos.end_line + 1, false), "\n")
end

local function contains(text, value)
	assert.is_truthy(text:find(value, 1, true), "Missing literal text: " .. value)
end

local function absent(text, value)
	assert.is_nil(text:find(value, 1, true), "Unexpected literal text: " .. value)
end

local function key(lhs)
	local mapping = vim.fn.maparg(lhs, "n", false, true)
	assert.equals(1, mapping.buffer)
	assert.is_function(mapping.callback)
	mapping.callback()
end

local function focus_task(id)
	vim.api.nvim_set_current_win(state.winid)
	vim.api.nvim_win_set_cursor(state.winid, { state.tasks[id].start_line + 1, 0 })
	assert.equals(id, tasks.get_task_at_cursor())
end

local function focus_line(id, marker)
	local pos = assert(state.tasks[id])
	for index, line in ipairs(vim.api.nvim_buf_get_lines(state.bufnr, pos.start_line, pos.end_line + 1, false)) do
		if line:find(marker, 1, true) then
			vim.api.nvim_set_current_win(state.winid)
			vim.api.nvim_win_set_cursor(state.winid, { pos.start_line + index, 0 })
			return
		end
	end
	error("Missing child row: " .. marker .. "\n" .. block_text(id))
end

local function expand_task(id)
	focus_task(id)
	key("O")
	assert.is_true(state.expanded_tasks[id])
end

describe("child tools inside expanded Tasks", function()
	local surface, columns, saved_client
	before_each(function()
		columns = vim.o.columns
		vim.o.columns = 140
		surface = chat_surface.setup()
		state.config = vim.deepcopy(app.get_config().chat)
		state.config.session_tabs.enabled = false
		app.set_session(parent_id, "Parent")
		app.set_connection("connected")
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr, {})
		saved_client = {}
		for _, name in ipairs({ "get_session", "get_messages", "get_session_statuses" }) do saved_client[name] = client[name] end
	end)
	after_each(function()
		details.close(false)
		vim.wait(30, function() return false end, 5)
		for name, method in pairs(saved_client) do client[name] = method end
		require("opencode.session.lock").clear_all()
		require("opencode.session.pending").clear_all()
		chat_surface.restore(surface)
		vim.o.columns = columns
	end)

	it("opens native shell command and output with Enter or O without folding the Task", function()
		local native = shell("shell", "printf child-command", "CHILD_OUTPUT\nSecond output line")
		local original = vim.deepcopy(native)
		local task = seed({ native })
		expand_task(task)
		contains(block_text(task), "Shell printf child-command")
		absent(block_text(task), "CHILD_OUTPUT")
		focus_line(task, "Shell printf child-command")
		key("<CR>")
		assert.is_true(state.expanded_tasks[task])
		contains(block_text(task), "$ printf child-command")
		contains(block_text(task), "CHILD_OUTPUT")
		contains(block_text(task), "Second output line")
		key("<CR>")
		assert.is_true(state.expanded_tasks[task])
		absent(block_text(task), "CHILD_OUTPUT")
		key("O")
		contains(block_text(task), "CHILD_OUTPUT")
		focus_line(task, "Second output line")
		key("O")
		assert.is_true(state.expanded_tasks[task])
		absent(block_text(task), "CHILD_OUTPUT")
		assert.same(original, native)
		contains(table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n"), "Following parent answer")
	end)

	it("reads fresh child output after output-only updates and full rerenders", function()
		local native = shell("shell", "printf stream-command", "INITIAL_OUTPUT", "running")
		local task = seed({ native })
		expand_task(task)
		focus_line(task, "Shell printf stream-command")
		key("<CR>")
		contains(block_text(task), "INITIAL_OUTPUT")
		focus_line(task, "INITIAL_OUTPUT")
		local selected, selected_pos = tasks.get_tool_at_cursor()
		assert.is_string(selected)
		tasks.stop_task_animation_timer()
		local before = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
		state.task_anim_frame = 2
		assert.is_true(tasks.update_animation_frames_in_place())
		local marks = vim.api.nvim_buf_get_extmarks(state.bufnr, cs.chat_anim_ns, 0, -1, { details = true })
		assert.is_true(vim.iter(marks):any(function(mark)
			return mark[2] >= selected_pos.start_line and mark[2] <= selected_pos.end_line
				and before[mark[2] + 1]:find("# Shell", 1, true) ~= nil
		end), "The running child needs its own header spinner overlay")
		assert.same(before, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
		native.state.content[1].text = "UPDATED_OUTPUT\nAppended line"
		local updated = child_messages({ native })[2].parts[1]
		sync.handle_part_updated(updated)
		tasks.rerender_task(task)
		contains(block_text(task), "UPDATED_OUTPUT")
		absent(block_text(task), "INITIAL_OUTPUT")
		assert.equals(selected, tasks.get_tool_at_cursor())
		chat.do_render()
		assert.is_true(state.expanded_tasks[task])
		contains(block_text(task), "Appended line")
		assert.equals(selected, tasks.get_tool_at_cursor())
		key("<CR>")
		assert.is_true(state.expanded_tasks[task])
		absent(block_text(task), "UPDATED_OUTPUT")
	end)

	it("expands sibling tools independently and keeps later widget ranges correct", function()
		local task, later = seed({ shell("a", "printf first-command", "FIRST_OUTPUT"),
			shell("b", "printf second-command", "SECOND_OUTPUT") }, 2)
		expand_task(task)
		local initial_later_line = state.tasks[later].start_line
		focus_line(task, "Shell printf first-command")
		key("<CR>")
		contains(block_text(task), "FIRST_OUTPUT")
		absent(block_text(task), "SECOND_OUTPUT")
		assert.is_true(state.tasks[later].start_line > initial_later_line)
		focus_line(task, "Shell printf second-command")
		key("O")
		contains(block_text(task), "SECOND_OUTPUT")
		focus_line(task, "FIRST_OUTPUT")
		key("<CR>")
		absent(block_text(task), "FIRST_OUTPUT")
		contains(block_text(task), "SECOND_OUTPUT")
		focus_line(task, "SECOND_OUTPUT")
		key("O")
		assert.equals(initial_later_line, state.tasks[later].start_line)
		assert.is_true(state.expanded_tasks[task])
	end)

	it("keeps the same child tool independent when two Tasks reference its session", function()
		local first, second = seed({ shell("shared", "printf shared-command", "SHARED_OUTPUT") }, 2)
		expand_task(first)
		expand_task(second)
		focus_line(first, "Shell printf shared-command")
		key("<CR>")
		contains(block_text(first), "SHARED_OUTPUT")
		absent(block_text(second), "SHARED_OUTPUT")
		chat.do_render()
		contains(block_text(first), "SHARED_OUTPUT")
		absent(block_text(second), "SHARED_OUTPUT")
		focus_line(second, "Shell printf shared-command")
		key("O")
		contains(block_text(second), "SHARED_OUTPUT")
		focus_line(first, "SHARED_OUTPUT")
		key("O")
		absent(block_text(first), "SHARED_OUTPUT")
		contains(block_text(second), "SHARED_OUTPUT")
		assert.is_true(state.expanded_tasks[first])
		assert.is_true(state.expanded_tasks[second])
	end)

	it("opens the selected execute inspector and folds Calls back to its own child row", function()
		local code = 'const value = await tools["catalog"].task_details({});\nreturn value;'
		local output = '{"title":"Child execute result","value":"NATIVE_EXECUTE_OUTPUT"}'
		local first, second = seed({ { type = "tool", id = "execute", name = "execute", state = {
			status = "completed", input = { code = code }, content = { { type = "text", text = output } },
			metadata = { toolCalls = { { tool = "catalog.task_details", status = "completed" } } },
		} } }, 2)
		expand_task(first)
		expand_task(second)
		focus_line(second, "↳ Execute")
		local invocation = tasks.get_tool_at_cursor()
		key("<CR>")
		contains(block_text(second), "↳ ✓ catalog.task_details")
		absent(block_text(first), "catalog.task_details")
		focus_line(second, "↳ ✓ catalog.task_details")
		local calls = tasks.get_tool_at_cursor()
		assert.is_not.equals(invocation, calls)
		key("<CR>")
		assert.is_true(details.is_open())
		local function inspector_text()
			return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
		end
		contains(inspector_text(), "catalog.task_details")
		key("2")
		assert.equals(output, inspector_text())
		key("3")
		assert.equals(code, inspector_text())
		key("q")
		assert.is_false(details.is_open())
		assert.equals(state.bufnr, vim.api.nvim_get_current_buf())
		assert.equals(calls, tasks.get_tool_at_cursor())
		key("O")
		assert.is_true(state.expanded_tasks[first])
		assert.is_true(state.expanded_tasks[second])
		assert.equals(invocation, tasks.get_tool_at_cursor())
		contains(block_text(second), "↳ Execute")
		absent(block_text(second), "catalog.task_details")
		absent(block_text(first), "catalog.task_details")
		key("<CR>")
		contains(block_text(second), "↳ ✓ catalog.task_details")
		absent(block_text(first), "catalog.task_details")
	end)

	it("closes child details with their Task and reopens only its summary", function()
		local task = seed({ shell("shell", "printf collapse-command", "COLLAPSED_OUTPUT") })
		expand_task(task)
		focus_line(task, "Shell printf collapse-command")
		key("O")
		contains(block_text(task), "COLLAPSED_OUTPUT")
		focus_task(task)
		key("O")
		assert.is_nil(state.expanded_tasks[task])
		absent(block_text(task), "COLLAPSED_OUTPUT")
		expand_task(task)
		contains(block_text(task), "Shell printf collapse-command")
		absent(block_text(task), "COLLAPSED_OUTPUT")
		chat.do_render()
		absent(block_text(task), "COLLAPSED_OUTPUT")
		focus_line(task, "Shell printf collapse-command")
		key("<CR>")
		contains(block_text(task), "COLLAPSED_OUTPUT")
	end)

	it("keeps gd navigation to the exact child while its tool details are open", function()
		local content = { shell("shell", "printf navigation-command", "NAVIGATION_OUTPUT") }
		local task = seed(content)
		expand_task(task)
		focus_line(task, "Shell printf navigation-command")
		key("<CR>")
		contains(block_text(task), "NAVIGATION_OUTPUT")
		local requested = {}
		client.get_session = function(id, callback)
			requested[#requested + 1] = id
			callback(nil, { id = child_id, parentID = parent_id, title = "Exact child", agent = "general",
				model = { providerID = "test", id = "model" } })
		end
		client.get_messages = function(id, _, callback)
			assert.equals(child_id, id)
			callback(nil, child_messages(content))
		end
		client.get_session_statuses = function(callback) callback(nil, {}) end
		focus_line(task, "NAVIGATION_OUTPUT")
		key("gd")
		assert.is_true(vim.wait(300, function() return app.get_session().id == child_id end, 5))
		assert.same({ child_id }, requested)
		assert.equals(parent_id, state.session_stack[1].id)
		assert.equals(child_id, require("opencode.session.lock").get(child_id).child_session.id)
	end)
end)
