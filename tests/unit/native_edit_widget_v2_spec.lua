describe("native v2 edit result", function()
	it("renders a native write result with input.path and existed=false", function()
		local results = require("opencode.ui.chat.file_edit_results")
		local part = {
			tool = "write",
			state = {
				status = "completed",
				input = { path = "notes.txt", content = "hello\n" },
				metadata = { operation = "write", target = "/project/notes.txt", resource = "notes.txt", existed = false },
			},
		}
		local model = results.normalize_model(part)
		assert.is_not_nil(model)
		assert.equals("applied", model.status)
		assert.equals("notes.txt", model.files[1].filePath)
		assert.equals("add", model.files[1].type)
		assert.is_not_nil(results.render_tool(part, false))
	end)

	it("uses native apply_patch file status for added and deleted files", function()
		local results = require("opencode.ui.chat.file_edit_results")
		local part = {
			tool = "apply_patch",
			state = {
				status = "completed",
				input = { patchText = "*** Begin Patch\n*** End Patch" },
				metadata = { files = {
					{ file = "new.txt", patch = "--- a/new.txt\n+++ b/new.txt\n+created", status = "added", additions = 1, deletions = 0 },
					{ file = "old.txt", patch = "--- a/old.txt\n+++ b/old.txt\n-removed", status = "deleted", additions = 0, deletions = 1 },
				} },
			},
		}
		local model = results.normalize_model(part)
		assert.is_not_nil(model)
		assert.equals("applied", model.status)
		assert.equals("add", model.files[1].type)
		assert.equals("delete", model.files[2].type)
		assert.is_not_nil(results.render_tool(part, false))
	end)

	it("renders the recorded files[].patch and restores a read-only preview", function()
		local session_id = "native-edit-widget"
		local native = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/session-ops/turn-two.json"), "\n"))
		local projection = require("opencode.protocol.v2.messages")
		local sync = require("opencode.sync")
		local edits = require("opencode.edit.state")
		local results = require("opencode.ui.chat.file_edit_results")
		local previews = require("opencode.ui.chat.edit_previews")
		sync.clear_all(); edits.clear_all()
		local messages = projection.page(session_id, native.data)
		sync.handle_session_messages(session_id, messages)
		local edit_part, edit_message
		for _, message in ipairs(sync.get_messages(session_id)) do
			for _, part in ipairs(sync.get_message_tools(message.id)) do
				if part.tool == "edit" then edit_part, edit_message = part, message end
			end
		end
		assert.is_not_nil(edit_part)
		local model = results.normalize_model(edit_part)
		assert.is_not_nil(model)
		assert.equals("applied", model.status)
		assert.equals("counter.txt", model.files[1].filePath)
		assert.equals(1, model.files[1].additions)
		assert.equals(1, model.files[1].deletions)
		assert.matches("%+two", model.files[1].diff)
		assert.is_not_nil(results.render_tool(edit_part, false))
		assert.equals(1, previews.sync_session(session_id))
		local preview = edits.get_edit("tool-preview:" .. session_id .. ":" .. edit_message.id .. ":" .. edit_part.id)
		assert.is_not_nil(preview)
		assert.equals("readonly", preview.review_mode)
		assert.equals("accepted", preview.files[1].status)
		assert.matches("%+two", table.concat(preview.files[1].diff_lines, "\n"))
		sync.clear_all(); edits.clear_all()
	end)
end)
