local sync = require("opencode.sync")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local tasks = require("opencode.ui.chat.tasks")
local render_state = require("opencode.ui.chat.render_state")
local projection = require("opencode.protocol.v2.messages")

local function skill(id, status, output)
	return { type = "tool", id = id, name = "skill", state = {
		status = status or "completed", input = { name = id },
		content = output and { { type = "text", text = output } } or {},
	} }
end

local function seed(content)
	sync.handle_session_messages("skill-test", { projection.project("skill-test", {
		id = "message", type = "assistant", time = { created = 1 }, content = content,
	}) })
	chat.do_render()
	return sync.get_parts("message")
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
	local node = assert(state.tools[id], "Missing standalone skill " .. id)
	vim.api.nvim_win_set_cursor(state.winid, { node.start_line + 1, 0 })
	assert.equals(id, tasks.get_tool_at_cursor())
	return node
end

local function update(id, status, output, err)
	local part = vim.deepcopy(sync.get_part("message", id))
	part.state.status, part.state.output, part.state.error = status, output, err
	sync.handle_part_updated(part)
	assert.is_true(tasks.rerender_tool(id))
	return part
end

describe("standalone skill widgets in the chat buffer", function()
	local original_buffer
	before_each(function()
		sync.clear_all()
		app.reset()
		app.set_config(vim.deepcopy(require("opencode.config").defaults))
		app.set_session("skill-test", "Skills")
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
		app.reset()
	end)

	it("keeps consecutive skills independent and toggles them with Enter and O", function()
		local parts = seed({
			skill("first", "completed", "# First skill\n\nFIRST_INSTRUCTIONS\nMore details"),
			skill("second", "completed", "SECOND_INSTRUCTIONS"),
			{ type = "text", text = "Following answer" },
		})
		local first, second = parts[1].id, parts[2].id
		assert.equals(2, vim.tbl_count(state.tools))
		for _, id in ipairs({ first, second }) do
			assert.equals("tool", state.tools[id].kind)
			assert.is_nil(state.tools[id].activity_group)
			assert.is_true(state.tools[id].end_line - state.tools[id].start_line <= 1)
		end
		assert.is_truthy(text():find('→ Skill "first"', 1, true))
		assert.is_truthy(text():find('→ Skill "second"', 1, true))
		assert.is_nil(text():find("FIRST_INSTRUCTIONS", 1, true))
		local second_start = state.tools[second].start_line
		focus(first)
		key("<CR>")
		assert.is_true(state.expanded_tools[first])
		assert.is_nil(state.expanded_tools[second])
		assert.is_truthy(text():find("FIRST_INSTRUCTIONS", 1, true))
		assert.is_nil(text():find("SECOND_INSTRUCTIONS", 1, true))
		assert.is_true(state.tools[second].start_line > second_start)
		key("j")
		assert.equals(first, tasks.get_tool_at_cursor())
		key("k")
		assert.equals(state.tools[first].start_line + 1, vim.api.nvim_win_get_cursor(state.winid)[1])
		focus(second)
		key("O")
		assert.is_truthy(text():find("SECOND_INSTRUCTIONS", 1, true))
		chat.do_render()
		assert.equals(second, tasks.get_tool_at_cursor())
		assert.is_true(state.expanded_tools[first])
		assert.is_true(state.expanded_tools[second])
		key("<CR>")
		assert.is_nil(state.expanded_tools[second])
		assert.is_true(state.expanded_tools[first])
		focus(first)
		key("O")
		assert.is_nil(state.expanded_tools[first])
		assert.equals(second_start, state.tools[second].start_line)
		assert.is_truthy(text():find("Following answer", 1, true))
	end)

	it("preserves expansion, cursor and following stream ranges through pending, streaming and completed updates", function()
		local parts = seed({ skill("live", "pending"), { type = "text", text = "Following answer" } })
		local id, following = parts[1].id, parts[2]
		local block_key = render_state.stream_block_key("skill-test", "message", following.id, "text")
		local closed_start = state.stream_blocks[block_key].start_line
		focus(id)
		key("<CR>")
		assert.is_true(tasks.is_animating_tool_part(sync.get_part("message", id)))
		update(id, "streaming", "STREAMING_INSTRUCTIONS\nSecond line\nThird line")
		assert.is_true(state.expanded_tools[id])
		assert.equals(id, tasks.get_tool_at_cursor())
		assert.is_true(tasks.is_animating_tool_part(sync.get_part("message", id)))
		assert.is_truthy(text():find("STREAMING_INSTRUCTIONS", 1, true))
		assert.is_true(state.stream_blocks[block_key].start_line > closed_start)
		key("j")
		update(id, "completed", "COMPLETED_INSTRUCTIONS\nSecond line\nThird line\nFinal line")
		assert.is_false(tasks.is_animating_tool_part(sync.get_part("message", id)))
		assert.is_nil(text():find("STREAMING_INSTRUCTIONS", 1, true))
		assert.is_truthy(text():find("COMPLETED_INSTRUCTIONS", 1, true))
		assert.equals(id, tasks.get_tool_at_cursor())
		chat.do_render()
		assert.is_true(state.expanded_tools[id])
		assert.equals(id, tasks.get_tool_at_cursor())
		key("O")
		assert.equals(id, tasks.get_tool_at_cursor())
		assert.is_nil(text():find("COMPLETED_INSTRUCTIONS", 1, true))
		assert.equals(closed_start, state.stream_blocks[block_key].start_line)
		following = vim.deepcopy(sync.get_part("message", following.id))
		following.text = "Following answer\nUpdated after folding"
		sync.handle_part_updated(following)
		assert.is_true(chat.update_stream_part_block("skill-test", "message", following.id))
		assert.is_truthy(text():find("Following answer\nUpdated after folding", 1, true))
		key("<CR>")
		assert.is_truthy(text():find("COMPLETED_INSTRUCTIONS", 1, true))
		assert.is_truthy(text():find("Updated after folding", 1, true))
	end)

	it("keeps failed skills folded and reachable after a live error update", function()
		local parts = seed({ skill("broken", "running"), { type = "text", text = "Following answer" } })
		local id = parts[1].id
		focus(id)
		update(id, "error", nil, "SKILL_LOOKUP_FAILED")
		assert.is_false(tasks.is_animating_tool_part(sync.get_part("message", id)))
		assert.is_nil(state.expanded_tools[id])
		assert.equals(id, tasks.get_tool_at_cursor())
		assert.is_true(state.tools[id].end_line - state.tools[id].start_line <= 1)
		key("<CR>")
		assert.is_truthy(text():find("SKILL_LOOKUP_FAILED", 1, true))
		assert.is_true(state.expanded_tools[id])
		chat.do_render()
		assert.equals(id, tasks.get_tool_at_cursor())
		key("O")
		assert.is_nil(state.expanded_tools[id])
		assert.is_truthy(text():find("Following answer", 1, true))
	end)

	it("refreshes cached completed skill details when the skill catalog changes", function()
		sync.handle_skills({ { name = "catalog", description = "OLD_CATALOG_DESCRIPTION", location = "/skills/old/SKILL.md" } })
		local parts = seed({ skill("catalog", "completed", "UNCHANGED_INSTRUCTIONS") })
		local id = parts[1].id
		focus(id)
		key("<CR>")
		chat.do_render()
		assert.is_truthy(text():find("OLD_CATALOG_DESCRIPTION", 1, true))
		assert.is_truthy(text():find("/skills/old", 1, true))
		local original = vim.deepcopy(sync.get_part("message", id))
		sync.handle_skills({ { name = "catalog", description = "NEW_CATALOG_DESCRIPTION", location = "/skills/new/SKILL.md" } })
		chat.do_render()
		assert.same(original, sync.get_part("message", id))
		assert.is_nil(text():find("OLD_CATALOG_DESCRIPTION", 1, true))
		assert.is_nil(text():find("/skills/old", 1, true))
		assert.is_truthy(text():find("NEW_CATALOG_DESCRIPTION", 1, true))
		assert.is_truthy(text():find("/skills/new", 1, true))
		assert.is_truthy(text():find("UNCHANGED_INSTRUCTIONS", 1, true))
		assert.is_true(state.expanded_tools[id])
		assert.equals(id, tasks.get_tool_at_cursor())
	end)

	it("animates only the declared header row and leaves slash text in the body untouched", function()
		for _, status in ipairs({ "pending", "running", "streaming" }) do
			state.task_anim_frame = 1
			local parts = seed({ skill("loading", status, "Use the / command\nBody ends in /") })
			local id = parts[1].id
			focus(id)
			if not state.expanded_tools[id] then key("O") end
			tasks.stop_task_animation_timer()
			local pos = state.tools[id]
			local before = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
			assert.is_truthy(table.concat(before, "\n"):find("Body ends in /", 1, true))
			state.task_anim_frame = 2
			assert.is_true(tasks.update_animation_frames_in_place(), status)
			local marks = vim.api.nvim_buf_get_extmarks(state.bufnr, cs.chat_anim_ns, 0, -1, { details = true })
			assert.equals(1, #marks)
			assert.equals(pos.start_line, marks[1][2])
			assert.equals("/", marks[1][4].virt_text[1][1])
			assert.same(before, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
			-- A stale completed header must not redirect the spinner to body text.
			vim.bo[state.bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.start_line + 2, false, {
				'↘ Skill "loading"', "Body ends in /",
			})
			vim.bo[state.bufnr].modifiable = false
			assert.is_false(tasks.update_animation_frames_in_place(), status)
			assert.same({}, vim.api.nvim_buf_get_extmarks(state.bufnr, cs.chat_anim_ns, 0, -1, {}))
		end
	end)
end)
