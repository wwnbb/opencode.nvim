local sync = require("opencode.sync")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local state = require("opencode.ui.chat.state").state
local tasks = require("opencode.ui.chat.tasks")
local render_state = require("opencode.ui.chat.render_state")
local projection = require("opencode.protocol.v2.messages")
local tree = require("opencode.ui.chat.widget_tree")
local execute = require("opencode.ui.chat.execute")
local details = require("opencode.ui.chat.execute_details")

local function native_tool(id, opts)
	opts = opts or {}
	return {
		type = "tool", id = id, name = "execute",
		time = { created = 100, ran = 150, completed = opts.completed },
		state = {
			status = opts.status or "completed",
			input = { code = opts.code or 'return await tools["catalog"].list({});' },
			content = opts.output and { { type = "text", text = opts.output } } or {},
			error = opts.error,
			metadata = { error = opts.failed, toolCalls = opts.calls or {
				{ tool = "catalog.list", status = "completed" },
			} },
		},
	}
end

local function project(content, completed)
	return projection.project("execute-test", {
		id = "message", type = "assistant", time = { created = 1, completed = completed }, content = content,
	})
end

local function seed(content, completed)
	sync.handle_session_messages("execute-test", { project(content, completed) })
end

local function buffer_text(bufnr)
	return table.concat(vim.api.nvim_buf_get_lines(bufnr or state.bufnr, 0, -1, false), "\n")
end

local function key(keycode)
	local mapping = vim.fn.maparg(keycode, "n", false, true)
	assert.is_function(mapping.callback)
	mapping.callback()
end

local function focus(id)
	local node = assert(tree.find(state.tools, id), "Missing execute section " .. id)
	vim.api.nvim_set_current_win(state.winid)
	vim.api.nvim_win_set_cursor(state.winid, { node.start_line + 1, 0 })
	assert.equals(id, tasks.get_tool_at_cursor())
	return node
end

local function group_id(part_id)
	local _, id = tree.find(state.tools, part_id)
	assert.is_truthy(id, "Missing execute group for " .. part_id)
	assert.equals("execute", state.tools[id].activity_group.kind)
	return id
end

local function open_group(part_id)
	local id = group_id(part_id)
	if not state.expanded_tools[id] then focus(id); key("O") end
	return id
end

local function open_call(part_id)
	open_group(part_id)
	if not state.expanded_tools[part_id] then focus(part_id); key("<CR>") end
end

local function inspector_text()
	assert.is_true(details.is_open())
	local winid = details.get_winids()[1]
	assert.equals(winid, vim.api.nvim_get_current_win())
	return buffer_text(vim.api.nvim_win_get_buf(winid))
end

local function section(id, name)
	return execute.section_id(id, name)
end

describe("execute widgets in the chat buffer", function()
	local original_buffer
	before_each(function()
		sync.clear_all()
		app.reset()
		app.set_config(vim.deepcopy(require("opencode.config").defaults))
		app.set_session("execute-test", "Execute")
		render_state.reset_chat_surface({ reset_expansions = true })
		state.render_scheduled = false
		state.session_stack = {}
		chat.setup({ layout = "vertical", width = 60, session_tabs = { enabled = true } })
		original_buffer = vim.api.nvim_get_current_buf()
		state.bufnr = vim.api.nvim_create_buf(false, true)
		state.winid = vim.api.nvim_get_current_win()
		state.visible = true
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr, {})
	end)
	after_each(function()
		details.close(false)
		tasks.stop_task_animation_timer()
		local bufnr = state.bufnr
		if state.visible then chat.close() end
		vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), original_buffer)
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		state.bufnr, state.winid, state.visible = nil, nil, false
		render_state.reset_chat_surface({ reset_expansions = true })
		sync.clear_all()
		app.reset()
	end)

	it("keeps the transcript limited to calls and opens the complete result through the inspector", function()
		local raw = vim.json.encode({ title = "A large MCP result", body = string.rep("long result ", 10000) .. "END_OF_RESULT" })
		seed({ native_tool("large", { output = raw }), { type = "text", text = "Following answer" } }, 500)
		chat.do_render()
		local part = sync.get_parts("message")[1]
		assert.equals(raw, part.state.output)
		assert.is_truthy(buffer_text():find("→ Executed — 1 call", 1, true))
		assert.equals("activity:execute:" .. part.id, group_id(part.id))
		assert.is_nil(buffer_text():find("catalog.list", 1, true))
		open_group(part.id)
		assert.is_truthy(buffer_text():find("catalog.list", 1, true))
		assert.is_nil(buffer_text():find("END_OF_RESULT", 1, true))
		assert.is_nil(buffer_text():find("Input:", 1, true))
		assert.is_true(tree.find(state.tools, part.id).end_line - tree.find(state.tools, part.id).start_line < 12)
		focus(part.id)
		key("<CR>")
		assert.is_true(state.expanded_tools[part.id])
		assert.is_truthy(buffer_text():find("✓ execute", 1, true))
		assert.is_truthy(buffer_text():find("↳ ✓ catalog.list", 1, true))
		assert.is_nil(buffer_text():find("A large MCP result", 1, true))
		assert.is_nil(buffer_text():find("Result", 1, true))
		assert.is_nil(buffer_text():find("Code", 1, true))
		assert.is_nil(buffer_text():find("return await", 1, true))
		assert.is_true(tree.find(state.tools, part.id).end_line - tree.find(state.tools, part.id).start_line < 6)
		assert.is_truthy(buffer_text():find("Following answer", 1, true))
		focus(section(part.id, "calls"))
		key("<CR>")
		assert.is_truthy(inspector_text():find("catalog.list", 1, true))
		key("1")
		assert.is_truthy(inspector_text():find("END_OF_RESULT", 1, true))
		key("2")
		assert.equals(raw, inspector_text())
		key("q")
		assert.is_false(details.is_open())
		assert.equals(state.winid, vim.api.nvim_get_current_win())
		assert.is_true(state.expanded_tools[part.id])
	end)

	it("opens code for the selected execute after rerenders and closing and reopening chat", function()
		local code = "const FIRST_CODE = 1;\nreturn FIRST_CODE;"
		seed({ native_tool("first", { code = code, output = "first result" }),
			native_tool("second", { code = "return SECOND_CODE;", output = "second result" }) }, 500)
		chat.do_render()
		local parts = sync.get_parts("message")
		local first, second = parts[1].id, parts[2].id
		open_group(first)
		for _, id in ipairs({ first, second }) do focus(id); key("O") end
		assert.is_nil(buffer_text():find("const FIRST_CODE = 1;", 1, true))
		assert.is_nil(buffer_text():find("return SECOND_CODE;", 1, true))
		chat.do_render()
		chat.do_render()
		focus(section(first, "calls")); key("<CR>"); key("3")
		assert.equals(code, inspector_text())
		chat.close()
		assert.is_false(details.is_open())
		chat.open()
		assert.is_true(state.expanded_tools[first])
		assert.is_true(state.expanded_tools[second])
		assert.is_nil(buffer_text():find("const FIRST_CODE = 1;", 1, true))
		assert.is_nil(buffer_text():find("return SECOND_CODE;", 1, true))
		focus(section(second, "calls")); key("<CR>"); key("3")
		assert.equals("return SECOND_CODE;", inspector_text())
		key("q")
		chat.do_render()
		assert.is_nil(buffer_text():find("const FIRST_CODE = 1;", 1, true))
		assert.is_nil(buffer_text():find("return SECOND_CODE;", 1, true))
		assert.equals(section(second, "calls"), tasks.get_tool_at_cursor())
	end)

	it("reveals only the selected execute and clears its nested expansion when the group closes", function()
		seed({ native_tool("one", { output = "FIRST_UNIQUE_RESULT", code = "return FIRST_UNIQUE_CODE;" }),
			native_tool("two", { output = "SECOND_UNIQUE_RESULT", calls = {
				{ tool = "catalog.find", status = "completed" }, { tool = "catalog.read", status = "completed" },
			} }), { type = "text", text = "Following answer" } }, 500)
		chat.do_render()
		local parts = sync.get_parts("message")
		local first, second = parts[1].id, parts[2].id
		local parent = group_id(first)
		assert.equals(parent, group_id(second))
		assert.is_nil(state.tools[first], "execute belongs to its activity, not a separate root")
		assert.is_truthy(buffer_text():find("→ Executed — 2 calls", 1, true))
		assert.is_nil(tree.find(state.tools, first).start_line)
		assert.is_nil(tree.find(state.tools, second).start_line)
		focus(parent); key("<CR>")
		for _, id in ipairs({ first, second }) do
			local node = tree.find(state.tools, id)
			assert.equals(node.start_line, node.end_line, "closed execute must occupy one line")
			assert.is_nil(state.expanded_tools[id])
		end
		assert.is_nil(buffer_text():find("FIRST_UNIQUE_RESULT", 1, true))
		assert.is_nil(buffer_text():find("SECOND_UNIQUE_RESULT", 1, true))
		focus(first); key("<CR>")
		assert.is_true(state.expanded_tools[first])
		assert.is_nil(state.expanded_tools[second])
		assert.is_truthy(buffer_text():find("↳ ✓ catalog.list", 1, true))
		assert.is_nil(buffer_text():find("↳ ✓ catalog.find", 1, true))
		assert.is_nil(buffer_text():find("FIRST_UNIQUE_RESULT", 1, true))
		assert.is_nil(buffer_text():find("SECOND_UNIQUE_RESULT", 1, true))
		assert.is_nil(buffer_text():find("FIRST_UNIQUE_CODE", 1, true))
		focus(section(first, "calls")); key("O")
		assert.is_nil(state.expanded_tools[first])
		assert.is_true(state.expanded_tools[parent], "O in the calls should fold only its execute")
		assert.equals(first, tasks.get_tool_at_cursor())
		focus(first); key("O")
		focus(section(first, "calls"))
		tasks.handle_tool_toggle(parent)
		assert.equals(parent, tasks.get_tool_at_cursor())
		assert.is_nil(state.expanded_tools[parent])
		assert.is_nil(state.expanded_tools[first])
		assert.is_nil(tree.find(state.tools, first).start_line)
		assert.is_truthy(buffer_text():find("Following answer", 1, true))
		key("O")
		assert.is_nil(buffer_text():find("FIRST_UNIQUE_RESULT", 1, true))
		assert.is_nil(buffer_text():find("FIRST_UNIQUE_CODE", 1, true))
	end)

	it("groups consecutive execute parts without crossing visible text or another activity", function()
		seed({ native_tool("one"), native_tool("two"),
			{ type = "text", text = "Intermediate answer" }, native_tool("three"),
			{ type = "reasoning", text = "Another plan", time = { created = 1, completed = 2 } },
			native_tool("four"), { type = "tool", id = "read", name = "read", state = {
				status = "completed", input = { path = "README.md" },
			} }, native_tool("five"), { type = "text", text = "Final answer" } }, 500)
		chat.do_render()
		local parts = sync.get_parts("message")
		local first, second = group_id(parts[1].id), group_id(parts[2].id)
		assert.equals(first, second)
		assert.equals(2, #state.tools[first].activity_group.refs)
		local seen = { [first] = true }
		for _, index in ipairs({ 4, 6, 8 }) do
			local id = group_id(parts[index].id)
			assert.is_nil(seen[id])
			seen[id] = true
			assert.equals("activity:execute:" .. parts[index].id, id)
			assert.equals(1, #state.tools[id].activity_group.refs)
		end
		assert.equals(4, vim.tbl_count(seen))
		assert.is_truthy(buffer_text():find("Intermediate answer", 1, true))
		assert.is_truthy(buffer_text():find("Thought", 1, true))
		assert.is_truthy(buffer_text():find("Explored", 1, true))
		assert.is_truthy(buffer_text():find("Final answer", 1, true))
	end)

	it("shifts execute child ranges with an earlier widget and leaves following stream blocks usable", function()
		seed({ { type = "reasoning", text = "Plan\nAdditional details", time = { created = 1, completed = 2 } },
			native_tool("shifted", { code = "return SHIFTED_CODE;", output = "Shifted result" }),
			{ type = "text", text = "Following answer" } })
		chat.do_render()
		local parts = sync.get_parts("message")
		local id = parts[2].id
		open_call(id)
		local before = tree.find(state.tools, section(id, "calls")).start_line
		local thought
		for group_id, node in pairs(state.tools) do
			if node.activity_group and node.activity_group.kind == "thought" then thought = group_id end
		end
		focus(assert(thought)); key("O")
		assert.is_true(tree.find(state.tools, section(id, "calls")).start_line > before)
		local node = focus(section(id, "calls"))
		assert.is_true(node.start_line >= tree.find(state.tools, id).start_line)
		assert.is_true(node.end_line <= tree.find(state.tools, id).end_line)
		assert.is_nil(buffer_text():find("return SHIFTED_CODE;", 1, true))
		local following = vim.deepcopy(parts[3])
		following.text = "Following answer\nStreamed continuation"
		sync.handle_part_updated(following)
		assert.is_true(chat.update_stream_part_block("execute-test", "message", following.id))
		assert.is_truthy(buffer_text():find("Following answer\nStreamed continuation", 1, true))
		focus(section(id, "calls")); key("<CR>"); key("1")
		assert.equals("Shifted result", inspector_text())
		key("q")
		focus(section(id, "calls")); key("O")
		assert.is_nil(state.expanded_tools[id])
		assert.equals(id, tasks.get_tool_at_cursor())
		assert.is_true(state.expanded_tools[group_id(id)])
		assert.is_truthy(buffer_text():find("Streamed continuation", 1, true))
	end)

	it("updates a running execute and resolves current synchronized data before opening details", function()
		seed({ native_tool("streaming", { status = "running", output = "Partial output", calls = {
			{ tool = "database.query", status = "running" },
		} }) })
		chat.do_render()
		local id = sync.get_parts("message")[1].id
		open_call(id)
		focus(section(id, "calls"))
		local final = project({ native_tool("streaming", { status = "completed", completed = 2150,
			output = "Final synchronized result", calls = { { tool = "database.query", status = "completed" } },
		}) }, 2200).parts[1]
		sync.handle_part_updated(final)
		assert.is_true(tasks.rerender_tool(id))
		assert.is_truthy(buffer_text():find("✓ execute", 1, true))
		assert.is_truthy(buffer_text():find("✓ database.query", 1, true))
		assert.is_nil(buffer_text():find("Final synchronized result", 1, true))
		assert.is_nil(buffer_text():find("Partial output", 1, true))
		assert.equals(section(id, "calls"), tasks.get_tool_at_cursor())
		final = vim.deepcopy(final)
		final.state.output = "Newest result before render"
		final.state.metadata.toolCalls[1].tool = "database.latest_query"
		final.state.input.code = "return LATEST_CODE;"
		sync.handle_part_updated(final)
		focus(section(id, "calls")); key("<CR>")
		assert.is_truthy(inspector_text():find("database.latest_query", 1, true))
		key("1")
		assert.equals("Newest result before render", inspector_text())
		key("3")
		assert.equals("return LATEST_CODE;", inspector_text())
		key("q")
		chat.do_render()
		assert.is_truthy(buffer_text():find("database.latest_query", 1, true))
		assert.is_nil(buffer_text():find("Newest result before render", 1, true))
		assert.is_nil(buffer_text():find("LATEST_CODE", 1, true))
		assert.is_true(state.expanded_tools[id])
	end)

	it("updates a closed execute group without exposing output and preserves a selected leaf as new calls arrive", function()
		seed({ native_tool("stream", { status = "running", output = "PARTIAL_HIDDEN_RESULT" }) })
		chat.do_render()
		local id = sync.get_parts("message")[1].id
		local parent = group_id(id)
		assert.is_truthy(buffer_text():find("Executing", 1, true))
		assert.is_nil(buffer_text():find("PARTIAL_HIDDEN_RESULT", 1, true))
		local final = project({ native_tool("stream", { completed = 250, output = "FINAL_VISIBLE_RESULT" }) }, 300).parts[1]
		sync.handle_part_updated(final)
		assert.is_true(tasks.rerender_tool(id))
		assert.is_truthy(buffer_text():find("Executed — 1 call", 1, true))
		assert.is_nil(buffer_text():find("FINAL_VISIBLE_RESULT", 1, true))
		assert.is_nil(tree.find(state.tools, id).start_line)
		open_call(id)
		assert.is_nil(buffer_text():find("FINAL_VISIBLE_RESULT", 1, true))
		assert.is_truthy(buffer_text():find("↳ ✓ catalog.list", 1, true))
		focus(id)
		local next_part = project({ native_tool("stream", { completed = 250, output = "FINAL_VISIBLE_RESULT" }),
			native_tool("next", { status = "running", output = "NEXT_HIDDEN_RESULT" }),
		}).parts[2]
		sync.handle_part_updated(next_part)
		chat.do_render()
		assert.equals(parent, group_id(next_part.id))
		assert.is_true(state.expanded_tools[parent])
		assert.is_true(state.expanded_tools[id])
		assert.is_nil(state.expanded_tools[next_part.id])
		assert.equals(id, tasks.get_tool_at_cursor())
		assert.is_truthy(buffer_text():find("Executing — 2 calls", 1, true))
		assert.is_nil(buffer_text():find("FINAL_VISIBLE_RESULT", 1, true))
		assert.is_nil(buffer_text():find("NEXT_HIDDEN_RESULT", 1, true))
		assert.is_nil(tree.find(state.tools, section(next_part.id, "calls")))
	end)

	it("keeps the detail page stable while the hidden transcript receives updates", function()
		local raw = table.concat(vim.fn.range(1, 50), "\n")
		seed({ native_tool("reading", { output = raw }) }, 500)
		chat.do_render()
		local id = sync.get_parts("message")[1].id
		open_call(id)
		focus(section(id, "calls")); key("<CR>"); key("1")
		local win = details.get_winids()[1]
		local detail_buf = vim.api.nvim_win_get_buf(win)
		vim.api.nvim_win_set_cursor(win, { 5, 0 })
		local nav = vim.wo[win].winbar
		state.auto_scroll = true
		local final = project({ native_tool("reading", { output = "Updated while reading" }),
			{ type = "text", text = string.rep("New transcript line\n", 100) },
		}, 900)
		sync.handle_session_messages("execute-test", { final })
		chat.do_render()
		require("opencode.ui.chat.cursor").scroll_to_bottom()
		chat.update_winbar()
		assert.equals(detail_buf, vim.api.nvim_win_get_buf(win))
		assert.equals(raw, buffer_text(detail_buf))
		assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(win))
		assert.equals(nav, vim.wo[win].winbar)
		assert.is_nil(tasks.get_tool_at_cursor())
		assert.is_nil(buffer_text():find("Updated while reading", 1, true))
		assert.is_truthy(buffer_text():find("New transcript line", 1, true))
		key("q")
		assert.equals(state.bufnr, vim.api.nvim_win_get_buf(state.winid))
		assert.is_truthy(buffer_text():find("New transcript line", 1, true))
		focus(section(id, "calls")); key("<CR>"); key("1")
		assert.equals("Updated while reading", inspector_text())
	end)

	it("keeps failed execute rows discoverable in a closed group and opens their complete error text", function()
		seed({ native_tool("failed", { status = "error", error = { message = "MCP access denied\nNo matching credential" },
			calls = { { tool = "private.read", status = "error" } },
		}), native_tool("cancelled", { status = "completed", failed = true, output = "Execution cancelled." }) }, 500)
		chat.do_render()
		local parts = sync.get_parts("message")
		assert.is_nil(state.expanded_tools[parts[1].id])
		assert.is_nil(state.expanded_tools[parts[2].id])
		assert.is_nil(state.expanded_tools[group_id(parts[1].id)])
		assert.is_truthy(buffer_text():find("private.read", 1, true))
		assert.is_number(tree.find(state.tools, parts[1].id).start_line)
		assert.is_number(tree.find(state.tools, parts[2].id).start_line)
		assert.is_nil(buffer_text():find("No matching credential", 1, true))
		focus(parts[1].id); key("<CR>")
		assert.is_nil(buffer_text():find("MCP access denied", 1, true))
		assert.is_truthy(buffer_text():find("↳ ✗ private.read", 1, true))
		focus(section(parts[1].id, "calls")); key("<CR>"); key("1")
		assert.is_truthy(inspector_text():find("MCP access denied", 1, true))
		assert.is_truthy(inspector_text():find("No matching credential", 1, true))
		key("2")
		assert.equals("MCP access denied\nNo matching credential", inspector_text())
		key("q")
		focus(parts[2].id); key("<CR>")
		focus(section(parts[2].id, "calls")); key("<CR>"); key("1")
		assert.equals("Execution cancelled.", inspector_text())
	end)
end)
