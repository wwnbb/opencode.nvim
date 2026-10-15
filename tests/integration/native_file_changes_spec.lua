local chat_surface = require("tests.helpers.chat_surface")
local chat = require("opencode.ui.chat")
local chat_state = require("opencode.ui.chat.state").state
local chat_edits = require("opencode.ui.chat.edits")
local chat_tasks = require("opencode.ui.chat.tasks")
local edit_state = require("opencode.edit.state")
local projection = require("opencode.protocol.messages")
local sync = require("opencode.sync")

describe("native file changes in chat", function()
	local surface
	local session_id = "native_file_changes"
	local message_id = "native_message"
	local call_id = "native_call"
	local part_id = projection.part_id(session_id, message_id, "tool", call_id)
	local preview_id = "tool-preview:" .. session_id .. ":" .. message_id .. ":" .. part_id

	before_each(function()
		surface = chat_surface.setup()
		edit_state.clear_all()
		require("opencode.permission.state").clear_all()
		require("opencode.question.state").clear_all()
		require("opencode.state").set_session(session_id, "Native file changes")
	end)

	after_each(function()
		edit_state.clear_all()
		chat_surface.restore(surface)
	end)

	local function render_tool(name, state)
		sync.handle_session_messages(session_id, { projection.project(session_id, {
			id = message_id,
			type = "assistant",
			time = { created = 1000, completed = state.status == "completed" and 2000 or nil },
			content = { { type = "tool", id = call_id, name = name, state = state } },
		}) })
		chat.do_render()
		return table.concat(vim.api.nvim_buf_get_lines(surface.bufnr, 0, -1, false), "\n")
	end

	local function expand_file(index)
		local position = chat_state.edits[preview_id]
		assert.is_not_nil(position, "completed tool should be an interactive diff preview")
		local range = position.meta.file_ranges[index]
		vim.api.nvim_win_set_cursor(surface.winid, { position.start_line + range.start_line + 1, 0 })
		assert.equals(preview_id, chat_edits.get_diffable_edit_at_cursor())
		chat_edits.handle_edit_toggle_diff()
		return table.concat(vim.api.nvim_buf_get_lines(surface.bufnr, 0, -1, false), "\n")
	end

	local function toggle_write()
		local position = chat_state.tools[part_id]
		assert.is_not_nil(position, "write should have its own tool widget")
		vim.api.nvim_win_set_cursor(surface.winid, { position.start_line + 1, 0 })
		local selected = chat_tasks.get_tool_at_cursor()
		assert.equals(part_id, selected)
		chat_tasks.handle_tool_toggle(selected)
		return table.concat(vim.api.nvim_buf_get_lines(surface.bufnr, 0, -1, false), "\n")
	end

	it("shows a separate write widget and folds its submitted content", function()
		local input = { path = "new.txt", content = "first new line\nsecond new line\n" }
		render_tool("write", { status = "running", input = input, metadata = {} })
		assert.is_nil(edit_state.get_edit(preview_id))

		local rendered = render_tool("write", {
			status = "completed", input = input,
			content = { { type = "text", text = "Created file successfully: new.txt" } },
		})
		assert.is_truthy(rendered:find("new.txt", 1, true))
		assert.is_truthy(rendered:find("Write", 1, true))
		assert.is_nil(rendered:find("+0 -0", 1, true))
		assert.is_nil(rendered:find("first new line", 1, true))
		assert.is_nil(edit_state.get_edit(preview_id), "write should not become an edit preview")
		assert.is_nil(chat_state.edits[preview_id])
		local expanded = toggle_write()
		assert.is_truthy(expanded:find("first new line", 1, true))
		assert.is_truthy(expanded:find("second new line", 1, true))
		assert.is_nil(toggle_write():find("first new line", 1, true))
	end)

	it("expands native edit metadata files[].patch from completed history", function()
		local rendered = render_tool("edit", {
			status = "completed",
			input = { path = "edited.txt", oldString = "old edit text", newString = "new edit text" },
			content = { { type = "text", text = "Edited edited.txt (1 replacement)" } },
			metadata = { files = { {
				file = "edited.txt", status = "modified", additions = 1, deletions = 1,
				patch = "Index: edited.txt\n===================================================================\n--- edited.txt\n+++ edited.txt\n@@ -1,1 +1,1 @@\n-old edit text\n+new edit text\n",
			} } },
		})
		assert.is_truthy(rendered:find("+1 -1", 1, true))
		local expanded = expand_file(1)
		assert.is_truthy(expanded:find("old edit text", 1, true))
		assert.is_truthy(expanded:find("new edit text", 1, true))
	end)

	it("distinguishes a recorded empty edit diff from an unavailable diff", function()
		local rendered = render_tool("edit", {
			status = "completed", input = { path = "unchanged.txt" },
			content = { { type = "text", text = "Edited unchanged.txt (1 replacement)" } },
			metadata = { files = { {
				file = "unchanged.txt", status = "modified", additions = 0, deletions = 0, patch = "",
			} } },
		})
		assert.is_truthy(rendered:find("unchanged.txt", 1, true))
		assert.is_truthy(rendered:find("+0 -0", 1, true))
		assert.is_nil(rendered:find("Diff unavailable", 1, true))
	end)

	it("expands added and deleted files from native apply_patch metadata", function()
		local rendered = render_tool("apply_patch", {
			status = "completed",
			input = { patchText = "*** Begin Patch\n*** Add File: added.txt\n+added by patch\n*** Delete File: deleted.txt\n*** End Patch" },
			content = { { type = "text", text = "Success. Updated the following files:\nA added.txt\nD deleted.txt" } },
			metadata = { files = {
				{ file = "added.txt", status = "added", additions = 1, deletions = 0,
					patch = "--- added.txt\n+++ added.txt\n@@ -0,0 +1,1 @@\n+added by patch\n" },
				{ file = "deleted.txt", status = "deleted", additions = 0, deletions = 1,
					patch = "--- deleted.txt\n+++ deleted.txt\n@@ -1,1 +0,0 @@\n-deleted by patch\n" },
			} },
		})
		assert.is_truthy(rendered:find("+1 -1", 1, true))
		assert.is_truthy(rendered:find("A added.txt", 1, true))
		assert.is_truthy(rendered:find("D deleted.txt", 1, true))
		assert.is_truthy(expand_file(1):find("added by patch", 1, true))
		assert.is_truthy(expand_file(2):find("deleted by patch", 1, true))
	end)

	it("shows submitted overwrite content without inventing a history diff", function()
		local rendered = render_tool("write", {
			status = "completed",
			input = { path = "existing.txt", content = "replacement content\n" },
			content = { { type = "text", text = "Wrote file successfully: existing.txt" } },
		})
		assert.is_truthy(rendered:find("existing.txt", 1, true))
		assert.is_truthy(rendered:find("Write", 1, true))
		assert.is_nil(rendered:find("+0 -0", 1, true))
		assert.is_nil(rendered:find("replacement content", 1, true))
		assert.is_nil(edit_state.get_edit(preview_id))
		assert.is_nil(chat_state.edits[preview_id])
		local expanded = toggle_write()
		assert.is_truthy(expanded:find("replacement content", 1, true))
		assert.is_truthy(expanded:find("Content sent to write (before server formatting)", 1, true))
		assert.is_nil(toggle_write():find("replacement content", 1, true))
	end)
end)
