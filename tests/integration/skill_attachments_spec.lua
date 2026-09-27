local sync = require("opencode.sync")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local tasks = require("opencode.ui.chat.tasks")
local pending = require("opencode.session.pending")
local render_state = require("opencode.ui.chat.render_state")
local projection = require("opencode.protocol.v2.messages")

local function apply_history(skills, opts)
	opts = opts or {}
	sync.handle_session_messages("skill-attachments", projection.page("skill-attachments", {
		{ id = "user", type = "user", time = { created = 1 }, text = "Use the attached skills",
			skills = skills, files = opts.files, agents = opts.agents, provisional = opts.provisional },
		{ id = "answer", type = "assistant", time = { created = 2 },
			content = { { type = "text", text = "Following answer" } } },
	}))
	local result = {}
	for _, part in ipairs(sync.get_parts("user")) do
		if part.type == "skill" then result[#result + 1] = part end
	end
	return result
end

local function seed(skills, opts)
	local parts = apply_history(skills, opts)
	chat.do_render()
	return parts
end

local function text()
	return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
end

local function key(keycode)
	local mapping = vim.fn.maparg(keycode, "n", false, true)
	assert.is_function(mapping.callback)
	mapping.callback()
end

local function focus(id)
	local node = assert(state.tools[id], "Missing skill attachment " .. id)
	vim.api.nvim_win_set_cursor(state.winid, { node.start_line + 1, 0 })
	assert.equals(id, tasks.get_tool_at_cursor())
	return node
end

local function assert_native_part(id, skill_id)
	local part = assert(sync.get_part("user", id))
	assert.equals("skill", part.type)
	assert.equals(skill_id, part.skillID)
	assert.is_nil(part.tool)
	assert.is_nil(part.state)
	assert.are_not.equals(skill_id, part.id)
end

describe("native user skill attachments in the chat buffer", function()
	local original_buffer
	before_each(function()
		sync.clear_all()
		pending.clear_all()
		app.reset()
		app.set_config(vim.deepcopy(require("opencode.config").defaults))
		app.set_session("skill-attachments", "Skill attachments")
		render_state.reset_chat_surface({ reset_expansions = true })
		state.render_scheduled = false
		state.session_stack = {}
		chat.setup({ session_tabs = { enabled = true } })
		original_buffer = vim.api.nvim_get_current_buf()
		state.bufnr = vim.api.nvim_create_buf(false, true)
		state.winid = vim.api.nvim_get_current_win()
		state.visible = true
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr, {})
	end)
	after_each(function()
		tasks.stop_task_animation_timer()
		vim.api.nvim_win_set_buf(state.winid, original_buffer)
		vim.api.nvim_buf_delete(state.bufnr, { force = true })
		state.bufnr, state.winid, state.visible = nil, nil, false
		render_state.reset_chat_surface({ reset_expansions = true })
		sync.clear_all()
		pending.clear_all()
		app.reset()
	end)

	it("renders confirmed attachments as independent expandable rows without inventing tool calls", function()
		local native = {
			{ id = "catalog-first", name = "first", text = "# First\n\nFIRST_ATTACHMENT_BODY\nMore instructions" },
			{ id = "catalog-second", name = "second", text = "SECOND_ATTACHMENT_BODY" },
		}
		local parts = seed(native)
		local first, second = parts[1].id, parts[2].id
		assert.equals(2, vim.tbl_count(state.tools))
		assert.same(native, sync.get_message("skill-attachments", "user")._v2.skills)
		for index, id in ipairs({ first, second }) do
			assert_native_part(id, native[index].id)
			assert.equals("tool", state.tools[id].kind)
			assert.is_nil(state.tools[id].activity_group)
			assert.is_true(state.tools[id].end_line - state.tools[id].start_line <= 1)
		end
		assert.is_truthy(text():find('Skill "first" · Attached', 1, true))
		assert.is_truthy(text():find('Skill "second" · Attached', 1, true))
		assert.is_nil(text():find("FIRST_ATTACHMENT_BODY", 1, true))
		local second_start = state.tools[second].start_line
		focus(first)
		key("<CR>")
		assert.is_true(state.expanded_tools[first])
		assert.is_nil(state.expanded_tools[second])
		assert.is_truthy(text():find("FIRST_ATTACHMENT_BODY", 1, true))
		assert.is_nil(text():find("SECOND_ATTACHMENT_BODY", 1, true))
		assert.is_true(state.tools[second].start_line > second_start)
		focus(second)
		key("O")
		assert.is_truthy(text():find("SECOND_ATTACHMENT_BODY", 1, true))
		chat.do_render()
		assert.equals(second, tasks.get_tool_at_cursor())
		assert.is_true(state.expanded_tools[first])
		assert.is_true(state.expanded_tools[second])
		key("<CR>")
		focus(first)
		key("O")
		assert.equals(second_start, state.tools[second].start_line)
		assert.is_nil(text():find("FIRST_ATTACHMENT_BODY", 1, true))
		assert.is_nil(text():find("SECOND_ATTACHMENT_BODY", 1, true))
		assert.is_truthy(text():find("Following answer", 1, true))
		assert_native_part(first, "catalog-first")
		assert_native_part(second, "catalog-second")
	end)

	it("distinguishes unconfirmed content from a confirmed empty attachment without a loading spinner", function()
		local parts = seed({
			{ id = "catalog-pending", name = "pending" },
			{ id = "catalog-empty", name = "empty", text = "" },
		}, { provisional = true })
		assert.is_truthy(text():find('Skill "pending" · Unconfirmed', 1, true))
		assert.is_truthy(text():find('Skill "empty" · Attached', 1, true))
		assert.is_nil(text():find('Skill "pending" · Attached', 1, true))
		for _, part in ipairs(parts) do assert.is_false(tasks.is_animating_tool_part(part)) end
		focus(parts[1].id)
		key("<CR>")
		assert.is_truthy(text():find("Skill instructions are not available in this message", 1, true))
		assert.is_false(tasks.update_animation_frames_in_place())
		assert.same({}, vim.api.nvim_buf_get_extmarks(state.bufnr, cs.chat_anim_ns, 0, -1, {}))
		key("O")
		focus(parts[2].id)
		key("<CR>")
		assert.is_nil(text():find("Skill instructions are not available in this message", 1, true))
	end)

	it("hydrates the same attachment identity from server history while preserving cursor and following ranges", function()
		local parts = seed({ { id = "catalog-live", name = "live" } }, { provisional = true })
		local id = parts[1].id
		local following = sync.get_parts("answer")[1]
		local block_key = render_state.stream_block_key("skill-attachments", "answer", following.id, "text")
		assert.is_true(state.stream_blocks[block_key].start_line < state.tools[id].start_line)
		focus(id)
		key("O")
		local updated = apply_history({ { id = "catalog-live", name = "live", text = "SERVER_INSTRUCTIONS\nSecond line\nThird line" } })
		assert.equals(id, updated[1].id)
		assert.is_true(tasks.rerender_tool(id))
		assert.is_true(state.expanded_tools[id])
		assert.equals(id, tasks.get_tool_at_cursor())
		assert.is_truthy(text():find('Skill "live" · Attached', 1, true))
		assert.is_truthy(text():find("SERVER_INSTRUCTIONS", 1, true))
		assert.is_nil(text():find("Skill instructions are not available in this message", 1, true))
		chat.do_render()
		assert.equals(id, tasks.get_tool_at_cursor())
		assert.is_true(state.expanded_tools[id])
		assert.is_true(state.stream_blocks[block_key].start_line > state.tools[id].end_line)
		key("<CR>")
		local closed_start = state.stream_blocks[block_key].start_line
		key("O")
		assert.is_true(state.stream_blocks[block_key].start_line > closed_start)
		following = vim.deepcopy(sync.get_part("answer", following.id))
		following.text = "Following answer\nUpdated after attachment folding"
		sync.handle_part_updated(following)
		assert.is_true(chat.update_stream_part_block("skill-attachments", "answer", following.id))
		assert.is_truthy(text():find("Following answer\nUpdated after attachment folding", 1, true))
		assert.is_truthy(text():find("SERVER_INSTRUCTIONS", 1, true))
		assert.is_truthy(text():find("Updated after attachment folding", 1, true))
		key("O")
		assert.equals(closed_start, state.stream_blocks[block_key].start_line)
		assert.is_truthy(text():find("Updated after attachment folding", 1, true))
		assert_native_part(id, "catalog-live")
	end)

	it("keeps queued prompt controls outside the expandable attachment range", function()
		pending.begin({ session_id = "skill-attachments", message_id = "user", status = "queued" })
		local parts = seed({ { id = "catalog-queued", name = "queued", text = "QUEUED_ATTACHMENT_BODY\nMore details" } },
			{ provisional = true })
		local id = parts[1].id
		local range = assert(state.pending_inputs.user)
		local start_line, end_line = range.start_line, range.end_line
		assert.is_truthy(text():find("Queued", 1, true))
		assert.is_true(end_line < state.tools[id].start_line)
		assert.is_truthy(vim.api.nvim_buf_get_lines(state.bufnr, end_line, end_line + 1, false)[1]:find("Queued", 1, true))
		focus(id)
		key("O")
		assert.is_truthy(text():find("QUEUED_ATTACHMENT_BODY", 1, true))
		assert.equals(start_line, state.pending_inputs.user.start_line)
		assert.equals(end_line, state.pending_inputs.user.end_line)
		assert.is_true(state.pending_inputs.user.end_line < state.tools[id].start_line)
		chat.do_render()
		assert.equals(end_line, state.pending_inputs.user.end_line)
		assert.equals(id, tasks.get_tool_at_cursor())
		key("<CR>")
		assert.equals(end_line, state.pending_inputs.user.end_line)
		assert.is_truthy(text():find("Queued", 1, true))
		assert.equals("queued", pending.get("skill-attachments", "user").status)
	end)

	it("restores expandable skill content from a cold server history reload", function()
		local native = { { id = "catalog-history", name = "history", text = "HISTORICAL_INSTRUCTIONS" } }
		local id = seed(native)[1].id
		focus(id)
		key("O")
		assert.is_truthy(text():find("HISTORICAL_INSTRUCTIONS", 1, true))
		sync.clear_all()
		render_state.reset_chat_surface({ reset_expansions = true })
		local restored = seed(native)[1]
		assert.equals(id, restored.id)
		assert.is_nil(state.expanded_tools[id])
		assert.is_truthy(text():find('Skill "history" · Attached', 1, true))
		assert.is_nil(text():find("HISTORICAL_INSTRUCTIONS", 1, true))
		focus(id)
		key("<CR>")
		assert.is_truthy(text():find("HISTORICAL_INSTRUCTIONS", 1, true))
		assert_native_part(id, "catalog-history")
	end)

	it("keeps file and agent attachments in the user bubble above the skill widget", function()
		local parts = seed({ { id = "catalog-mixed", name = "mixed", text = "MIXED_ATTACHMENT_BODY" } }, {
			files = { { uri = "file:///tmp/notes.md", name = "notes.md", mime = "text/plain" } },
			agents = { { name = "explore" } },
		})
		local id = parts[1].id
		assert.equals(1, vim.tbl_count(state.tools))
		assert.is_truthy(text():find("file notes.md", 1, true))
		assert.is_truthy(text():find("agent explore", 1, true))
		assert.is_nil(text():find("skill mixed", 1, true))
		local last_bubble_line = -1
		for index, line in ipairs(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)) do
			if line:sub(1, #"┃") == "┃" then last_bubble_line = index - 1 end
		end
		assert.is_true(last_bubble_line >= 0)
		assert.is_true(last_bubble_line < state.tools[id].start_line)
		focus(id)
		key("<CR>")
		assert.is_truthy(text():find("MIXED_ATTACHMENT_BODY", 1, true))
		assert.is_truthy(text():find("file notes.md", 1, true))
		assert.is_truthy(text():find("agent explore", 1, true))
		local raw = sync.get_parts("user")
		assert.equals("file", raw[2].type)
		assert.equals("file:///tmp/notes.md", raw[2].url)
		assert.equals("agent", raw[3].type)
		assert.equals("explore", raw[3].name)
		assert_native_part(id, "catalog-mixed")
	end)
end)
