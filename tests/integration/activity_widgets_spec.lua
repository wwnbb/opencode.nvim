local sync = require("opencode.sync")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local tasks = require("opencode.ui.chat.tasks")
local render_state = require("opencode.ui.chat.render_state")
local projection = require("opencode.protocol.v2.messages")

local function seed(content, completed)
	sync.handle_session_messages("activity-test", { projection.project("activity-test", {
		id = "message", type = "assistant", time = { created = 1, completed = completed }, content = content,
	}) })
end

local function text()
	return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
end

local function key(keycode)
	local mapping = vim.fn.maparg(keycode, "n", false, true)
	assert.is_function(mapping.callback)
	mapping.callback()
end

describe("activity widgets in the chat buffer", function()
	local original_buffer
	before_each(function()
		sync.clear_all()
		app.reset()
		app.set_config(vim.deepcopy(require("opencode.config").defaults))
		app.set_session("activity-test", "Activities")
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

	it("toggles both widgets using the real mappings and preserves following text and ranges", function()
		seed({
			{ type = "reasoning", text = "Plan\nmore details", time = { created = 100, completed = 316 } },
			{ type = "tool", id = "read", name = "read", state = { status = "completed", input = { path = "Cargo.toml" } } },
			{ type = "text", text = "Final answer" },
		}, 500)
		chat.do_render()
		local parts = sync.get_parts("message")
		local thought_id, read_id = parts[1].id, parts[2].id
		assert.is_truthy(text():find("+ Thought · 216ms", 1, true))
		assert.is_truthy(text():find("→ Explored — 1 read", 1, true))
		vim.api.nvim_win_set_cursor(state.winid, { state.tools[thought_id].start_line + 1, 0 })
		key("<CR>")
		assert.is_truthy(text():find("▏  more details", 1, true))
		vim.api.nvim_win_set_cursor(state.winid, { state.tools[read_id].start_line + 1, 0 })
		key("O")
		assert.is_truthy(text():find("→ Read Cargo.toml", 1, true))
		chat.do_render()
		assert.is_true(state.expanded_tools[read_id])
		assert.equals(read_id, tasks.get_tool_at_cursor())
		key("<CR>")
		assert.is_nil(text():find("Cargo.toml", 1, true))
		assert.is_truthy(text():find("Final answer", 1, true))
	end)

	it("streams into the open thought group without losing following ranges or highlights", function()
		seed({ { type = "reasoning", text = "first", time = { created = 100 } } })
		chat.do_render()
		local id = sync.get_parts("message")[1].id
		assert.is_truthy(text():find("Thinking", 1, true))
		vim.api.nvim_win_set_cursor(state.winid, { state.tools[id].start_line + 1, 0 })
		key("O")
		local part = vim.deepcopy(sync.get_part("message", id))
		part.text = "first\nstreamed continuation"
		sync.handle_part_updated(part)
		assert.is_true(chat.update_stream_part_block("activity-test", "message", id))
		assert.is_truthy(text():find("▏  streamed continuation", 1, true))
		assert.equals(id, tasks.get_tool_at_cursor())
		part.time.completed = 3700
		sync.handle_part_updated(part)
		chat.do_render()
		assert.is_truthy(text():find("- Thought · 3.6s", 1, true))
		assert.is_true(state.expanded_tools[id])
		sync.handle_part_updated({ id = "following", messageID = "message", sessionID = "activity-test",
			protocol = "v2", type = "text", text = "Following text", content_order = 2 })
		chat.do_render()
		local block_key = render_state.stream_block_key("activity-test", "message", "following", "text")
		local previous_start = state.stream_blocks[block_key].start_line
		vim.api.nvim_win_set_cursor(state.winid, { state.tools[id].start_line + 3, 0 })
		key("O")
		assert.equals(id, tasks.get_tool_at_cursor(), "collapsing from the body must keep the cursor on the thought")
		assert.is_true(state.stream_blocks[block_key].start_line < previous_start)
		sync.handle_part_updated({ id = "following", messageID = "message", sessionID = "activity-test",
			protocol = "v2", type = "text", text = "Following text\nupdated", content_order = 2 })
		assert.is_true(chat.update_stream_part_block("activity-test", "message", "following"))
		assert.is_truthy(text():find("Following text\n   updated", 1, true))
		key("O")
		local marks = vim.api.nvim_buf_get_extmarks(state.bufnr, cs.chat_hl_ns, 0, -1, { details = true })
		assert.is_true(vim.iter(marks):any(function(mark) return mark[4].hl_group == "OpenCodeThoughtBody" end))
	end)

	it("keeps a read permission visible beside collapsed exploration", function()
		local permissions = require("opencode.permission.state")
		seed({
			{ type = "tool", id = "done", name = "read", state = { status = "completed", input = { path = "README.md" } } },
			{ type = "tool", id = "pending", name = "read", state = { status = "pending", input = { path = "secret.txt" } } },
		})
		permissions.add_permission("permission", "activity-test", "read", {
			message_id = "message", call_id = "pending", tool_input = { filePath = "secret.txt" }, patterns = { "secret.txt" },
		})
		local ok, err = pcall(function()
			chat.do_render()
			assert.is_truthy(text():find("Explored — 1 read", 1, true))
			assert.is_truthy(text():find("Read secret.txt", 1, true))
			assert.is_not_nil(state.permissions.permission)
			assert.equals("pending", state.permissions.permission.status)
		end)
		permissions.clear_all()
		assert.is_true(ok, err)
	end)
end)
