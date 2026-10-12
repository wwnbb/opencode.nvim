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
		local projection = require("opencode.protocol.messages")
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
		for index, case in ipairs({
			{ name = "append", event = "session.text.delta", data = { delta = " world" }, lines = { "hello world" } },
			{ name = "grow", event = "session.text.delta", data = { delta = "\nnext" }, lines = { "hello world", "next" } },
			{ name = "shrink", event = "session.text.ended", data = { text = "short" }, lines = { "short" } },
		}) do
			sync.handle_server_event({ id = "evt_stream_" .. case.name, created = index + 1, type = case.event,
				data = vim.tbl_extend("force", case.data, {
					sessionID = "stream_session", assistantMessageID = "stream_message", ordinal = 0,
				}) })
			assert.is_true(chat.update_stream_part_block("stream_session", "stream_message", stream_part_id), case.name)
			local expected = vim.list_extend(vim.deepcopy(case.lines), { "\\ Coder_v2 · GPT-5.5" })
			assert.same(expected, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), case.name)
			assert.equals(#case.lines - 1, chat_state.stream_blocks[block_key].end_line, case.name)
			assert.equals(#case.lines, chat_state.spinner_footer_line, case.name)
			local footer_marks = vim.api.nvim_buf_get_extmarks(bufnr, chat_state_mod.chat_hl_ns,
				{ #case.lines, 0 }, { #case.lines, -1 }, { details = true })
			assert.equals(1, #footer_marks, case.name)
			assert.equals("OpenCodeAgent_coder_v2", footer_marks[1][4].hl_group, case.name)
		end
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

		for _, message in ipairs({
			{ id = "m1", role = "user", time = { created = 1000 }, text = "older user anchored" },
			{ id = "m2", role = "assistant", time = { created = 2000, completed = 2500 }, text = "older assistant" },
			{ id = "m3", role = "user", time = { created = 4000 }, text = "recent echoed local" },
			{ id = "m4", role = "assistant", time = { created = 5000 }, text = "streaming answer" },
		}) do
			sync.handle_message_updated({ id = message.id, sessionID = "render_contract_session",
				role = message.role, time = message.time })
			sync.handle_part_updated({ id = message.id .. "_text", messageID = message.id,
				sessionID = "render_contract_session", type = "text", text = message.text })
		end
		for _, tool in ipairs({ "question", "edit" }) do
			sync.handle_part_updated({ id = "m4_" .. tool .. "_tool", messageID = "m4",
				sessionID = "render_contract_session", type = "tool", tool = tool,
				callID = "call_" .. tool, state = { status = "pending", input = {} } })
		end
		local function diff(path, before, after)
			return table.concat({ "--- a/" .. path, "+++ b/" .. path, "@@ -1 +1 @@", "-" .. before, "+" .. after }, "\n")
		end
		local previews = {
			{ id = "m4_patch_tool", tool = "apply_patch", call_id = "call_patch", before = "old line", after = "new line",
				metadata = { status = "success", files = { { filePath = "render-patch.txt", type = "update",
					diff = diff("render-patch.txt", "old line", "new line") } } } },
			{ id = "m4_neovim_edit_tool", tool = "neovim_edit", call_id = "call_neovim_edit",
				before = "old neovim edit", after = "new neovim edit",
				metadata = { status = "success", filediff = { file = "render-neovim-edit.txt", status = "applied",
					diff = diff("render-neovim-edit.txt", "old neovim edit", "new neovim edit") } } },
			{ id = "m4_neovim_patch_tool", tool = "neovim_patch", call_id = "call_neovim_patch",
				before = "old neovim patch", after = "new neovim patch",
				metadata = { status = "success", files = { { filePath = "render-neovim-patch.txt", type = "update", status = "applied",
					diff = diff("render-neovim-patch.txt", "old neovim patch", "new neovim patch") } } } },
		}
		for _, preview in ipairs(previews) do
			sync.handle_part_updated({ id = preview.id, messageID = "m4", sessionID = "render_contract_session",
				type = "tool", tool = preview.tool, callID = preview.call_id,
				state = { status = "completed", metadata = preview.metadata } })
		end

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
		assert.is_nil(chat_state.tools.m4_question_tool, "question tool row should be suppressed by widget")
		assert.is_nil(chat_state.tools.m4_edit_tool, "edit tool row should be suppressed by widget")
		for _, preview in ipairs(previews) do
			local preview_id = "tool-preview:render_contract_session:m4:" .. preview.id
			local edit = edit_state.get_edit(preview_id)
			assert.is_not_nil(edit, preview.tool)
			assert.equals("readonly", edit.review_mode, preview.tool)
			assert.equals("sent", edit.status, preview.tool)
			assert.is_not_nil(chat_state.edits[preview_id], preview.tool .. " preview should be tracked")
			assert.is_nil(chat_state.tools[preview.id], preview.tool .. " tool row should be suppressed")
			edit_state.toggle_inline_diff(preview_id, 1)
			local text = table.concat(require("opencode.ui.edit_widget").get_resolved_lines(preview_id, edit), "\n")
			assert(text:find(preview.before, 1, true), preview.tool .. " should expand removed diff text")
			assert(text:find(preview.after, 1, true), preview.tool .. " should expand added diff text")
		end

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
