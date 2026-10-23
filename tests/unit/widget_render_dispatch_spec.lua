describe("widget render dispatch", function()
	local permission_widget = require("opencode.ui.permission_widget")
	local question_widget = require("opencode.ui.question_widget")
	local edit_widget = require("opencode.ui.edit_widget")
	local widget_base = require("opencode.ui.widget_base")
	local opts = { width = 60 }

	it("renders permissions by status and always returns meta", function()
		local base = { permission_id = "p", permission_type = "bash", tool_input = { command = "pwd" }, always = { "*" } }
		local pending = vim.tbl_extend("force", base, { status = "pending", selected_option = 2 })
		assert.same({ permission_widget.get_lines_for_permission("p", pending, opts) }, { permission_widget.render(pending, opts) })
		local approved = vim.tbl_extend("force", base, { status = "approved", reply = "always" })
		local lines, highlights = permission_widget.get_approved_lines("p", approved, opts)
		assert.same({ lines, highlights, widget_base.make_meta() }, { permission_widget.render(approved, opts) })
		local rejected = vim.tbl_extend("force", base, { status = "rejected" })
		lines, highlights = permission_widget.get_rejected_lines("p", rejected, opts)
		assert.same({ lines, highlights, widget_base.make_meta() }, { permission_widget.render(rejected, opts) })
	end)

	it("renders questions through the status-dispatching entrypoint", function()
		local qstate = { request_id = "q", status = "pending", current_tab = 1, timestamp = 1, selections = { {} },
			questions = { { question = "Pick", options = { { label = "A" }, { label = "B" } } } } }
		assert.same({ question_widget.get_lines_for_question("q", { questions = qstate.questions, timestamp = 1 }, qstate,
			"pending", opts) }, { question_widget.render(qstate, opts) })
	end)

	it("renders sent edits as resolved and pending edits as interactive", function()
		local files = { { filepath = "a.lua", status = "accepted", diff_lines = { "@@ -1 +1 @@", "-a", "+b" } } }
		local sent = { permission_id = "e", status = "sent", files = files, expanded_files = {} }
		assert.same({ edit_widget.get_resolved_lines("e", sent, opts) }, { edit_widget.render(sent, opts) })
		local pending = { permission_id = "e", status = "pending", files = { { filepath = "a.lua", status = "pending" } },
			expanded_files = {}, selected_file = 1 }
		assert.same({ edit_widget.get_lines_for_edit("e", pending, opts) }, { edit_widget.render(pending, opts) })
	end)

	-- Divergence pinned for UI-01: the resolved label comes from the record passed
	-- in, not from the edit store (previously an unstored record read "pending").
	it("labels resolved edits from the passed record even when it is not stored", function()
		local edit_state = require("opencode.edit.state")
		local estate = { permission_id = "not-stored", status = "sent", expanded_files = {},
			files = { { filepath = "a.lua", status = "rejected" } } }
		assert.is_nil(edit_state.get_edit("not-stored"))
		assert.equals("all_rejected", edit_state.resolution_of(estate))
		assert.equals("pending", edit_state.get_resolution("not-stored"))
		local text = table.concat(edit_widget.get_resolved_lines("not-stored", estate, opts), "\n")
		assert.is_truthy(text:find("(rejected)", 1, true))
		assert.is_nil(text:find("(partial)", 1, true))
	end)
end)
