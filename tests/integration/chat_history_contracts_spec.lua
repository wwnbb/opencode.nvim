local chat_surface = require("tests.helpers.chat_surface")
local chat = require("opencode.ui.chat")
local chat_state_mod = require("opencode.ui.chat.state")
local chat_state = chat_state_mod.state
local render_state = require("opencode.ui.chat.render_state")
local sync = require("opencode.sync")
local app_state = require("opencode.state")
local question_state = require("opencode.question.state")
local permission_state = require("opencode.permission.state")
local edit_state = require("opencode.edit.state")

describe("chat history rendering contracts", function()
	local bufnr, surface
	before_each(function()
		surface = chat_surface.setup()
		bufnr = surface.bufnr
	end)
	after_each(function()
		chat_surface.restore(surface)
	end)
	local function clear_interactions()
		question_state.clear_all(); permission_state.clear_all(); edit_state.clear_all()
		require("opencode.artifact.changes").clear()
	end
	before_each(clear_interactions)
	after_each(clear_interactions)

	it("preserves footer text and highlights when streamed text grows and shrinks", function()
		app_state.set_session("stream_session", "Stream Session")
		sync.clear_all()
		local projection = require("opencode.protocol.v2.messages")
		local stream_part_id = projection.part_id("stream_session", "stream_message", "text", 0)
		sync.handle_session_messages("stream_session", { projection.project("stream_session", {
			id = "stream_message", type = "assistant", content = { { type = "text", text = "hello" } },
			time = { created = 1 },
		}) })
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello", "\\ Coder_v2 · GPT-5.5" })
		vim.bo[bufnr].modifiable = false
		vim.api.nvim_buf_set_extmark(bufnr, require("opencode.ui.chat.state").chat_hl_ns, 1, 2, {
			end_col = 10,
			hl_group = "OpenCodeAgent_coder_v2",
		})
		chat_state.spinner_footer_line = 1

		local block_key = render_state.stream_block_key("stream_session", "stream_message", stream_part_id, "text")
		chat_state.stream_blocks[block_key] = {
			start_line = 0,
			end_line = 0,
			session_id = "stream_session",
			message_id = "stream_message",
			part_id = stream_part_id,
			kind = "text",
		}
		sync.handle_v2_event({ id = "evt_stream_world", created = 2, type = "session.text.delta",
			data = { sessionID = "stream_session", assistantMessageID = "stream_message", ordinal = 0, delta = " world" } })
		assert(
			chat.update_stream_part_block("stream_session", "stream_message", stream_part_id),
			"same-line stream delta should update in place"
		)
		assert(
			vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "hello world",
			"same-line stream delta did not append visibly"
		)
		assert(chat_state.stream_blocks[block_key].end_line == 0, "same-line stream delta should not grow block")

		sync.handle_v2_event({ id = "evt_stream_next", created = 3, type = "session.text.delta",
			data = { sessionID = "stream_session", assistantMessageID = "stream_message", ordinal = 0, delta = "\nnext" } })
		assert(
			chat.update_stream_part_block("stream_session", "stream_message", stream_part_id),
			"newline stream delta should replace the rendered block"
		)
		local updated_stream_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		assert(#updated_stream_lines == 3, "newline stream delta should grow rendered block without losing footer")
		assert(updated_stream_lines[1] == "hello world", "newline fallback should preserve first line")
		assert(updated_stream_lines[2] == "next", "newline fallback should render next line")
		assert(updated_stream_lines[3]:find("Coder_v2", 1, true), "stream growth should preserve footer text")
		assert(chat_state.spinner_footer_line == 2, "stream growth should shift tracked footer line")
		local footer_marks = vim.api.nvim_buf_get_extmarks(
			bufnr,
			require("opencode.ui.chat.state").chat_hl_ns,
			{ 2, 0 },
			{ 2, -1 },
			{ details = true }
		)
		assert(#footer_marks == 1, "stream growth should preserve footer agent highlight")
		assert(footer_marks[1][4].hl_group == "OpenCodeAgent_coder_v2", "wrong footer highlight after stream growth")

		sync.handle_v2_event({ id = "evt_stream_end", created = 4, type = "session.text.ended",
			data = { sessionID = "stream_session", assistantMessageID = "stream_message", ordinal = 0, text = "short" } })
		assert(
			chat.update_stream_part_block("stream_session", "stream_message", stream_part_id),
			"stream replacement should shrink rendered block"
		)
		updated_stream_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		assert(
			#updated_stream_lines == 2,
			"stream shrink should keep footer immediately after content: " .. vim.inspect(updated_stream_lines)
		)
		assert(updated_stream_lines[1] == "short", "stream shrink should render replacement text")
		assert(updated_stream_lines[2]:find("Coder_v2", 1, true), "stream shrink should preserve footer text")
		assert(chat_state.spinner_footer_line == 1, "stream shrink should shift tracked footer line back")
		footer_marks = vim.api.nvim_buf_get_extmarks(
			bufnr,
			require("opencode.ui.chat.state").chat_hl_ns,
			{ 1, 0 },
			{ 1, -1 },
			{ details = true }
		)
		assert(#footer_marks == 1, "stream shrink should preserve footer agent highlight")
	end)

	it("anchors pending widgets before history cutoff and suppresses duplicate tool rows", function()
		chat_state.config.max_rendered_messages = 2
		chat_state.config.max_user_message_lines = 120
		chat_state.local_notices = {
			{
				role = "user",
				content = "recent echoed local",
				timestamp = 4,
				session_id = "render_contract_session",
				id = "local_echo",
			},
		}
		app_state.set_session("render_contract_session", "Render Contract")
		app_state.set_session_status("render_contract_session", { type = "streaming" })

		sync.handle_message_updated({
			id = "m1",
			sessionID = "render_contract_session",
			role = "user",
			time = { created = 1000 },
		})
		sync.handle_part_updated({
			id = "m1_text",
			messageID = "m1",
			sessionID = "render_contract_session",
			type = "text",
			text = "older user anchored",
		})
		sync.handle_message_updated({
			id = "m2",
			sessionID = "render_contract_session",
			role = "assistant",
			time = { created = 2000, completed = 2500 },
		})
		sync.handle_part_updated({
			id = "m2_text",
			messageID = "m2",
			sessionID = "render_contract_session",
			type = "text",
			text = "older assistant",
		})
		sync.handle_message_updated({
			id = "m3",
			sessionID = "render_contract_session",
			role = "user",
			time = { created = 4000 },
		})
		sync.handle_part_updated({
			id = "m3_text",
			messageID = "m3",
			sessionID = "render_contract_session",
			type = "text",
			text = "recent echoed local",
		})
		sync.handle_message_updated({
			id = "m4",
			sessionID = "render_contract_session",
			role = "assistant",
			time = { created = 5000 },
		})
		sync.handle_part_updated({
			id = "m4_text",
			messageID = "m4",
			sessionID = "render_contract_session",
			type = "text",
			text = "streaming answer",
		})
		sync.handle_part_updated({
			id = "m4_question_tool",
			messageID = "m4",
			sessionID = "render_contract_session",
			type = "tool",
			tool = "question",
			callID = "call_question",
			state = { status = "pending", input = {} },
		})
		sync.handle_part_updated({
			id = "m4_edit_tool",
			messageID = "m4",
			sessionID = "render_contract_session",
			type = "tool",
			tool = "edit",
			callID = "call_edit",
			state = { status = "pending", input = {} },
		})
		sync.handle_part_updated({
			id = "m4_patch_tool",
			messageID = "m4",
			sessionID = "render_contract_session",
			type = "tool",
			tool = "apply_patch",
			callID = "call_patch",
			state = {
				status = "completed",
				metadata = {
					status = "success",
					files = {
						{
							filePath = "render-patch.txt",
							type = "update",
							diff = table.concat({
								"--- a/render-patch.txt",
								"+++ b/render-patch.txt",
								"@@ -1 +1 @@",
								"-old line",
								"+new line",
							}, "\n"),
						},
					},
				},
			},
		})
		sync.handle_part_updated({
			id = "m4_neovim_edit_tool",
			messageID = "m4",
			sessionID = "render_contract_session",
			type = "tool",
			tool = "neovim_edit",
			callID = "call_neovim_edit",
			state = {
				status = "completed",
				metadata = {
					status = "success",
					filediff = {
						file = "render-neovim-edit.txt",
						status = "applied",
						diff = table.concat({
							"--- a/render-neovim-edit.txt",
							"+++ b/render-neovim-edit.txt",
							"@@ -1 +1 @@",
							"-old neovim edit",
							"+new neovim edit",
						}, "\n"),
					},
				},
			},
		})
		sync.handle_part_updated({
			id = "m4_neovim_patch_tool",
			messageID = "m4",
			sessionID = "render_contract_session",
			type = "tool",
			tool = "neovim_patch",
			callID = "call_neovim_patch",
			state = {
				status = "completed",
				metadata = {
					status = "success",
					files = {
						{
							filePath = "render-neovim-patch.txt",
							type = "update",
							status = "applied",
							diff = table.concat({
								"--- a/render-neovim-patch.txt",
								"+++ b/render-neovim-patch.txt",
								"@@ -1 +1 @@",
								"-old neovim patch",
								"+new neovim patch",
							}, "\n"),
						},
					},
				},
			},
		})

		question_state.add_form({ id = "q_anchor", sessionID = "render_contract_session",
			fields = { { key = "anchor", type = "string", title = "Anchor?", options = { { label = "Yes", value = "yes" } } } },
			metadata = { tool = { messageID = "m1" } },
		}, { timestamp = 1 })
		question_state.add_form({ id = "q_tool", sessionID = "render_contract_session",
			fields = { { key = "tool", type = "string", title = "Tool question?", options = { { label = "Yes", value = "yes" } } } },
			metadata = { tool = { messageID = "m4", id = "call_question" } },
		}, { timestamp = 5 })
		permission_state.add_permission("perm_orphan", "render_contract_session", "bash", {
			timestamp = 6,
			tool_input = { command = "pwd" },
		})
		edit_state.add_edit("edit_tool", "render_contract_session", {
			{ filePath = "render-contract.txt", before = "a", after = "b" },
		}, {
			message_id = "m4",
			call_id = "call_edit",
			timestamp = 7,
			review_mode = "readonly",
		})

		local raw_lines = chat.render()
		local rendered = table.concat(raw_lines, "\n")
		local echo_count = 0
		for _ in rendered:gmatch("recent echoed local") do
			echo_count = echo_count + 1
		end

		assert(rendered:find("older user anchored", 1, true), "pending widget should anchor a message before cutoff")
		assert(echo_count == 1, "local user notice should not duplicate a server echo")
		assert(chat_state.questions.q_tool, "tool-call question should be tracked")
		assert(chat_state.permissions.perm_orphan, "orphan permission should be tracked")
		assert(chat_state.edits.edit_tool, "tool-call edit should be tracked")
		local preview_edit_id = "tool-preview:render_contract_session:m4:m4_patch_tool"
		local preview_edit = edit_state.get_edit(preview_edit_id)
		assert(preview_edit and preview_edit.preview == true, "completed apply_patch should create preview edit state")
		assert(preview_edit.status == "sent", "completed apply_patch preview should not be pending")
		assert(chat_state.edits[preview_edit_id], "completed apply_patch preview should be tracked")
		local neovim_edit_preview_id = "tool-preview:render_contract_session:m4:m4_neovim_edit_tool"
		local neovim_edit_preview = edit_state.get_edit(neovim_edit_preview_id)
		assert(neovim_edit_preview and neovim_edit_preview.preview == true, "approved neovim_edit should create preview edit state")
		assert(chat_state.edits[neovim_edit_preview_id], "approved neovim_edit preview should be tracked")
		local neovim_patch_preview_id = "tool-preview:render_contract_session:m4:m4_neovim_patch_tool"
		local neovim_patch_preview = edit_state.get_edit(neovim_patch_preview_id)
		assert(
			neovim_patch_preview and neovim_patch_preview.preview == true,
			"approved neovim_patch should create preview edit state"
		)
		assert(chat_state.edits[neovim_patch_preview_id], "approved neovim_patch preview should be tracked")
		assert(chat_state.tools.m4_question_tool == nil, "question tool row should be suppressed by widget")
		assert(chat_state.tools.m4_edit_tool == nil, "edit tool row should be suppressed by widget")
		assert(chat_state.tools.m4_patch_tool == nil, "apply_patch tool row should be suppressed by preview widget")
		assert(chat_state.tools.m4_neovim_edit_tool == nil, "neovim_edit tool row should be suppressed by preview widget")
		assert(chat_state.tools.m4_neovim_patch_tool == nil, "neovim_patch tool row should be suppressed by preview widget")

		edit_state.toggle_inline_diff(preview_edit_id, 1)
		local preview_lines = require("opencode.ui.edit_widget").get_resolved_lines(preview_edit_id, preview_edit)
		local preview_text = table.concat(preview_lines, "\n")
		assert(preview_text:find("old line", 1, true), "apply_patch preview should expand removed diff text")
		assert(preview_text:find("new line", 1, true), "apply_patch preview should expand added diff text")
		edit_state.toggle_inline_diff(neovim_edit_preview_id, 1)
		local neovim_edit_lines =
			require("opencode.ui.edit_widget").get_resolved_lines(neovim_edit_preview_id, neovim_edit_preview)
		local neovim_edit_text = table.concat(neovim_edit_lines, "\n")
		assert(neovim_edit_text:find("old neovim edit", 1, true), "neovim_edit preview should expand removed diff text")
		assert(neovim_edit_text:find("new neovim edit", 1, true), "neovim_edit preview should expand added diff text")
		edit_state.toggle_inline_diff(neovim_patch_preview_id, 1)
		local neovim_patch_lines =
			require("opencode.ui.edit_widget").get_resolved_lines(neovim_patch_preview_id, neovim_patch_preview)
		local neovim_patch_text = table.concat(neovim_patch_lines, "\n")
		assert(
			neovim_patch_text:find("old neovim patch", 1, true),
			"neovim_patch preview should expand removed diff text"
		)
		assert(
			neovim_patch_text:find("new neovim patch", 1, true),
			"neovim_patch preview should expand added diff text"
		)

		local block_key = render_state.stream_block_key("render_contract_session", "m4", "m4_text", "text")
		assert(chat_state.stream_blocks[block_key], "full render should register streaming text block")
		assert(chat_state.spinner_footer_line == nil, "pending interaction should not register an animated footer line")
		assert(rendered:find("▣ ", 1, true), "pending interaction should retain a static processing footer")
	end)

	it("computes an added-file preview from an explicitly empty before snapshot", function()
		local edit_widget = require("opencode.ui.edit_widget")
		local edit_previews = require("opencode.ui.chat.edit_previews")

		sync.clear_all()
		edit_state.clear_all()

		-- Empty-string compute: a `write` with before="" / after="content" and
		-- no diff should compute a non-empty vim.diff so add/delete previews work.
		local compute_session = "compute_session"
		sync.handle_message_updated({
			id = "m_compute",
			sessionID = compute_session,
			role = "assistant",
			time = { created = 1000, completed = 1500 },
		})
		sync.handle_part_updated({
			id = "m_write_compute",
			messageID = "m_compute",
			sessionID = compute_session,
			type = "tool",
			tool = "write",
			callID = "call_write_compute",
			state = {
				status = "completed",
				metadata = {
					status = "success",
					filepath = "compute-write.txt",
					filediff = {
						file = "compute-write.txt",
						before = "",
						after = "content line",
					},
				},
			},
		})

		local created = edit_previews.sync_session(compute_session)
		assert(created == 1, "empty-string before/after should create a preview edit via computed diff")
		local compute_id = "tool-preview:" .. compute_session .. ":m_compute:m_write_compute"
		local compute_estate = edit_state.get_edit(compute_id)
		assert(compute_estate, "empty-string compute path should create an edit estate")
		assert(#compute_estate.files == 1, "compute estate should have one file")
		local cfile = compute_estate.files[1]
		assert(#cfile.diff_lines > 0, "empty-string before/after should compute a non-empty diff")
		assert(cfile.stats.added > 0, "computed diff should report non-zero additions")
		assert(cfile.before == "", "compute estate should preserve empty before content")
		assert(cfile.after == "content line", "compute estate should preserve after content")

		edit_state.toggle_inline_diff(compute_id, 1)
		local compute_lines = edit_widget.get_resolved_lines(compute_id, compute_estate)
		local compute_text = table.concat(compute_lines, "\n")
		assert(compute_text:find("content line", 1, true), "computed diff widget should expand added content")
	end)

	it("shows only pending orphan edits and permissions", function()
		sync.clear_all()
		edit_state.clear_all()
		permission_state.clear_all()
		app_state.set_session("orphan_resolved_session", "Orphan Resolved")

		edit_state.add_edit("edit_orphan_resolved", "orphan_resolved_session", {
			{ filePath = "orphan-resolved.txt", before = "a", after = "b" },
		}, {
			timestamp = 1,
			review_mode = "readonly",
			file_statuses = { "accepted" },
		})
		edit_state.add_edit("edit_orphan_pending", "orphan_resolved_session", {
			{ filePath = "orphan-pending.txt", before = "a", after = "b" },
		}, {
			timestamp = 2,
			review_mode = "readonly",
		})

		permission_state.add_permission("perm_orphan_resolved", "orphan_resolved_session", "bash", {
			timestamp = 3,
			tool_input = { command = "echo resolved" },
		})
		permission_state.mark_approved("perm_orphan_resolved", "once")
		permission_state.add_permission("perm_orphan_pending", "orphan_resolved_session", "bash", {
			timestamp = 4,
			tool_input = { command = "echo pending" },
		})

		chat.render()
		assert(
			chat_state.edits.edit_orphan_resolved == nil,
			"resolved orphan edit owned by current session should not render at the orphan tail"
		)
		assert(
			chat_state.edits.edit_orphan_pending,
			"pending orphan edit owned by current session should render at the orphan tail"
		)
		assert(
			chat_state.permissions.perm_orphan_resolved == nil,
			"resolved orphan permission owned by current session should not render at the orphan tail"
		)
		assert(
			chat_state.permissions.perm_orphan_pending,
			"pending orphan permission owned by current session should render at the orphan tail"
		)
	end)

	it("shows pending and confirming orphan questions but hides resolved ones", function()
		app_state.set_session("orphan_question_session", "Orphan Question")

		local function add_orphan_form(id, label, timestamp)
			question_state.add_form({ id = id, sessionID = "orphan_question_session",
				fields = { { key = "choice", type = "string", title = "Pick", description = "Choose one",
					options = { { label = label, value = label:lower() } } } },
				metadata = { tool = { messageID = "msg_orphan_question" } },
			}, { timestamp = timestamp })
		end
		add_orphan_form("q_orphan_pending", "A", 1)
		add_orphan_form("q_orphan_confirming", "B", 2)
		question_state.set_confirming("q_orphan_confirming")
		add_orphan_form("q_orphan_answered", "C", 3)
		question_state.mark_answered("q_orphan_answered")
		add_orphan_form("q_orphan_rejected", "D", 4)
		question_state.mark_rejected("q_orphan_rejected")

		chat.render()
		assert(
			chat_state.questions.q_orphan_pending,
			"pending orphan question owned by current session should render at the orphan tail"
		)
		assert(
			chat_state.questions.q_orphan_confirming,
			"confirming orphan question owned by current session should render at the orphan tail"
		)
		assert(
			chat_state.questions.q_orphan_answered == nil,
			"answered orphan question owned by current session should not render at the orphan tail"
		)
		assert(
			chat_state.questions.q_orphan_rejected == nil,
			"rejected orphan question owned by current session should not render at the orphan tail"
		)
	end)

end)
