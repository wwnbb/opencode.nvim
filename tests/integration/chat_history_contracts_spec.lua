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

	it("hides pending widgets after closing the last tab and restores them on reopen", function()
		local sessions = require("opencode.session")
		local widget_index = require("opencode.ui.chat.widget_index")
		sessions.set_active("closing_session", "Closing Session")
		for _, id in ipairs({ "pending_question", "confirming_question" }) do
			question_state.add_form({ id = id, sessionID = "closing_session",
				fields = { { key = "choice", type = "string", title = "Saved question",
					options = { { label = "Saved answer", value = "saved" } } } },
			})
			question_state.select_option(id, 1)
		end
		question_state.set_confirming("confirming_question")
		permission_state.add_permission("closing_permission", "closing_session", "bash", {
			tool_input = { command = "echo pending" },
		})
		edit_state.add_edit("closing_edit", "closing_session", {
			{ filePath = "pending.txt", before = "a", after = "b" },
		}, { review_mode = "readonly" })

		local function assert_widgets_visible()
			chat.do_render()
			assert.is_not_nil(chat_state.questions.pending_question)
			assert.is_not_nil(chat_state.questions.confirming_question)
			assert.is_not_nil(chat_state.permissions.closing_permission)
			assert.is_not_nil(chat_state.edits.closing_edit)
		end
		assert_widgets_visible()
		assert.is_true(sessions.close("closing_session", { silent = true }))
		assert.is_nil(app_state.get_session().id)
		assert.same({}, app_state.get_active_sessions())
		chat.do_render()
		assert.same({}, chat_state.questions)
		assert.same({}, chat_state.permissions)
		assert.same({}, chat_state.edits)
		assert.is_false(widget_index.new({ current_session = app_state.get_session() }):has_pending_interaction())
		local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
		assert.is_nil(text:find("Saved question", 1, true))
		assert.is_nil(text:find("echo pending", 1, true))
		assert.is_nil(text:find("pending.txt", 1, true))

		sessions.set_active("closing_session", "Closing Session")
		assert_widgets_visible()
		assert.equals("pending", question_state.get_question("pending_question").status)
		assert.equals("confirming", question_state.get_question("confirming_question").status)
		assert.same({ choice = "saved" }, question_state.get_answers("pending_question"))
		assert.same({ choice = "saved" }, question_state.get_answers("confirming_question"))
	end)

	it("shows only pending or confirming orphan interactions", function()
		app_state.set_session("orphan_session", "Orphans")
		for index, id in ipairs({ "edit_resolved", "edit_pending" }) do
			edit_state.add_edit(id, "orphan_session", { { filePath = id .. ".txt", before = "a", after = "b" } },
				{ timestamp = index, review_mode = "readonly", file_statuses = index == 1 and { "accepted" } or nil })
		end
		for index, id in ipairs({ "perm_resolved", "perm_pending" }) do
			permission_state.add_permission(id, "orphan_session", "bash",
				{ timestamp = index + 2, tool_input = { command = "echo " .. id } })
		end
		permission_state.mark_approved("perm_resolved", "once")
		for index, id in ipairs({ "q_pending", "q_confirming", "q_answered", "q_rejected" }) do
			question_state.add_form({ id = id, sessionID = "orphan_session",
				fields = { { key = "choice", type = "string", title = "Pick",
					options = { { label = id, value = id } } } },
				metadata = { tool = { messageID = "msg_orphan" } },
			}, { timestamp = index + 4 })
		end
		question_state.set_confirming("q_confirming")
		question_state.mark_answered("q_answered")
		question_state.mark_rejected("q_rejected")
		chat.render()
		assert.is_nil(chat_state.edits.edit_resolved)
		assert.is_not_nil(chat_state.edits.edit_pending)
		assert.is_nil(chat_state.permissions.perm_resolved)
		assert.is_not_nil(chat_state.permissions.perm_pending)
		assert.is_not_nil(chat_state.questions.q_pending)
		assert.is_not_nil(chat_state.questions.q_confirming)
		assert.is_nil(chat_state.questions.q_answered)
		assert.is_nil(chat_state.questions.q_rejected)
	end)
end)
