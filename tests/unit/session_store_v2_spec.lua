describe("v2 session store cleanup", function()
	local bus = require("opencode.events.bus")
	local sync = require("opencode.sync")
	local permissions = require("opencode.permission.state")
	local forms = require("opencode.question.state")
	local edits = require("opencode.edit.state")

	before_each(function()
		bus.clear(); sync.clear_all(); permissions.clear_all(); forms.clear_all(); edits.clear_all()
		require("opencode.events.handlers.session_store").setup(bus)
	end)

	after_each(function()
		bus.clear(); sync.clear_all(); permissions.clear_all(); forms.clear_all(); edits.clear_all()
	end)

	local function seed()
		permissions.add_permission("permission", "root", "read", {})
		forms.add_form({ id = "form", sessionID = "root", title = "Continue?", fields = {
			{ key = "ok", title = "Continue?", type = "boolean", required = true },
		} })
		edits.add_edit("review", "root", { { filePath = "file.lua", before = "a", after = "b" } }, {
			transport = "review_rpc", review_id = "review",
		})
		sync.handle_session_messages("root", { require("opencode.protocol.v2.messages").project("root", {
			id = "message", type = "assistant", content = { { type = "text", text = "cached" } },
		}) })
	end

	it("preserves permission, form, review and message cache for navigation", function()
		seed()
		bus.emit("session_change", { previous_id = "root", id = "child", reason = "child_navigation", preserve_cache = true })
		assert.is_truthy(permissions.get_permission("permission"))
		assert.is_truthy(forms.get_question("form"))
		assert.is_truthy(edits.get_edit("review"))
		assert.is_truthy(sync.get_message("root", "message"))
	end)

	it("clears interactions and sync only on explicit reset", function()
		seed()
		bus.emit("session_change", { previous_id = "root", id = "next", reason = "clear" })
		assert.is_nil(permissions.get_permission("permission"))
		assert.is_nil(forms.get_question("form"))
		assert.is_nil(edits.get_edit("review"))
		assert.is_nil(sync.get_message("root", "message"))
	end)
end)
