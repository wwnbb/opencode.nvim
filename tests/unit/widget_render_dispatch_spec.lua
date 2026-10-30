describe("edit widget resolution labels", function()
	it("labels resolved edits from the passed record even when it is not stored", function()
		local edit_state = require("opencode.edit.state")
		local estate = { permission_id = "not-stored", status = "sent", expanded_files = {},
			files = { { filepath = "a.lua", status = "rejected" } } }
		assert.is_nil(edit_state.get_edit("not-stored"))
		local text = table.concat(require("opencode.ui.edit_widget").get_resolved_lines("not-stored", estate, { width = 60 }), "\n")
		assert.is_truthy(text:find("(rejected)", 1, true))
		assert.is_nil(text:find("(partial)", 1, true))
	end)
end)
