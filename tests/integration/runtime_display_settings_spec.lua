local app, sync = require("opencode.state"), require("opencode.sync")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat = require("opencode.ui.chat")
local projection = require("opencode.protocol.messages")
local tree = require("opencode.ui.chat.widget_tree")
local function text() return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n") end
local function seed(parts)
	sync.handle_session_messages("settings", { projection.project("settings", {
		id = "msg_settings", type = "assistant", time = { completed = 100 }, content = parts,
	}) })
end
local function group(kind)
	for id, node in pairs(state.tools) do
		if node.activity_group and node.activity_group.kind == kind then return id, node end
	end
end
local function part_id(call_id)
	for _, part in ipairs(sync.get_parts("msg_settings")) do if part.callID == call_id then return part.id end end
end
local function key(value)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), "mx", false)
end
local function config(values)
	app.set_config(vim.tbl_deep_extend("force", {}, app.get_config(), values))
	chat.do_render()
end

describe("runtime transcript display settings", function()
	local previous_buffer
	before_each(function()
		app.reset(); sync.clear_all()
		app.set_config(vim.deepcopy(require("opencode.config").defaults))
		app.set_session("settings", "Settings")
		require("opencode.ui.chat.render_state").reset_chat_surface({ reset_expansions = true })
		state.session_stack = {}; state.render_scheduled = false
		require("opencode.events").setup()
		chat.setup({ session_tabs = { enabled = true } })
		previous_buffer = vim.api.nvim_get_current_buf()
		state.bufnr = chat.create()
		state.winid = vim.api.nvim_get_current_win(); state.visible = true
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr, {})
	end)
	after_each(function()
		require("opencode.ui.chat.tasks").stop_task_animation_timer()
		vim.api.nvim_win_set_buf(state.winid, previous_buffer)
		vim.api.nvim_buf_delete(state.bufnr, { force = true })
		state.bufnr, state.winid, state.visible = nil, nil, false
		require("opencode.ui.chat.render_state").reset_chat_surface({ reset_expansions = true })
		require("opencode.permission.state").clear_all()
		sync.clear_all(); app.reset()
	end)

	it("keeps legacy disabled thinking collapsed and keyboard-reachable with rendered Markdown", function()
		seed({ { type = "reasoning", text = "[REDACTED]" },
			{ type = "reasoning", text = "First\n\n**Bold body**", time = { created = 1, completed = 80 } },
			{ type = "text", text = "Final answer" } })
		config({ thinking = { enabled = false } })
		local _, node = group("thought")
		assert.is_truthy(node); assert.is_truthy(text():find("+ Thought", 1, true))
		assert.is_nil(text():find("Bold body", 1, true)); assert.is_nil(text():find("REDACTED", 1, true))
		vim.api.nvim_win_set_cursor(state.winid, { node.start_line + 1, 0 }); key("<CR>")
		assert.is_truthy(text():find("▏  Bold body", 1, true))
		assert.is_nil(text():find("**Bold body**", 1, true))
		assert.is_truthy(text():find("Final answer", 1, true))
	end)

	it("opens show mode by default and preserves an explicit manual collapse through rerenders", function()
		seed({ { type = "reasoning", text = "Visible thought", time = { completed = 80 } } })
		config({ session = { thinking = "show" } })
		local id, node = group("thought")
		assert.is_truthy(text():find("▏  Visible thought", 1, true))
		vim.api.nvim_win_set_cursor(state.winid, { node.start_line + 1, 0 }); key("O")
		assert.is_false(state.expanded_tools[id]); chat.do_render()
		assert.is_nil(text():find("Visible thought", 1, true))
		key("O"); assert.is_truthy(text():find("Visible thought", 1, true))
	end)

	it("turns grouping off without losing standalone leaves and opens summaries by default at high verbosity", function()
		seed({ { id = "read", type = "tool", name = "read", state = { status = "completed", input = { path = "config.lua" } } },
			{ id = "search", type = "tool", name = "grep", state = { status = "completed", input = { pattern = "setup" } } } })
		config({ session = { grouping = "none" } })
		assert.is_nil(group("explore")); assert.is_truthy(state.tools[part_id("read")]); assert.is_truthy(state.tools[part_id("search")])
		config({ session = { grouping = "auto", verbosity = "high" } })
		local id, node = group("explore")
		assert.is_truthy(text():find("config.lua", 1, true))
		assert.is_truthy(tree.find(state.tools, part_id("read")))
		vim.api.nvim_win_set_cursor(state.winid, { node.start_line + 1, 0 }); key("O")
		assert.is_false(state.expanded_tools[id]); assert.is_nil(text():find("config.lua", 1, true))
	end)

	it("summarizes low detail while keeping failed tools and questions outside protected folds", function()
		seed({ { type = "reasoning", text = "Private thought", time = { completed = 1 } },
			{ id = "read", type = "tool", name = "read", state = { status = "completed", input = { path = "config.lua" } } },
			{ id = "shell", type = "tool", name = "shell", state = { status = "error", input = { command = "false" }, error = "Failed command" } },
			{ id = "question", type = "tool", name = "question", state = { status = "completed", input = {} } },
			{ type = "text", text = "Final answer" } })
		config({ session = { verbosity = "low" } })
		local _, node = group("activity")
		assert.equals(3, #node.activity_group.refs)
		assert.is_truthy(text():find("Activity · 2 tools, 1 thought · 1 failed", 1, true))
		assert.is_truthy(text():find("Failed command", 1, true))
		assert.is_truthy(state.tools[part_id("question")]); assert.is_truthy(text():find("Final answer", 1, true))
		assert.is_nil(text():find("Private thought", 1, true)); assert.is_nil(text():find("config.lua", 1, true))
		vim.api.nvim_win_set_cursor(state.winid, { node.start_line + 1, 0 }); key("O")
		local thought
		for _, child in pairs(state.tools[node.id].children) do if child.activity_group then thought = child end end
		assert.is_truthy(thought)
		vim.api.nvim_win_set_cursor(state.winid, { thought.start_line + 1, 0 }); key("O")
		assert.is_truthy(text():find("Private thought", 1, true))
	end)

	it("keeps review permission rows visible when low verbosity would otherwise fold the tool", function()
		seed({ { id = "read", type = "tool", name = "read", state = { status = "running", input = { path = "config.lua" } } } })
		local part = sync.get_parts("msg_settings")[1]
		require("opencode.permission.state").add_permission("permission", "settings", "read", {
			tool_call_id = part.callID, message_id = "msg_settings", patterns = { "config.lua" },
		})
		config({ session = { verbosity = "low" } })
		assert.is_nil(group("activity")); assert.is_truthy(state.permissions.permission)
	end)

	it("switches cached final text between rendered and source Markdown through config refresh", function()
		seed({ { type = "text", text = "**Final answer**" } })
		chat.do_render(); assert.is_nil(text():find("**Final answer**", 1, true))
		config({ session = { markdown = "source" } })
		assert.is_true(vim.wait(500, function() return text():find("**Final answer**", 1, true) ~= nil end, 5))
		config({ session = { markdown = "rendered" } })
		assert.is_true(vim.wait(500, function() return text():find("**Final answer**", 1, true) == nil end, 5))
	end)
end)
