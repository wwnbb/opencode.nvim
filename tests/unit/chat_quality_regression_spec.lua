local surface = require("tests.helpers.chat_surface")
local state = require("opencode.ui.chat.state").state
local app = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local questions = require("opencode.question.state")
local permissions = require("opencode.permission.state")
local edits = require("opencode.edit.state")
local support = require("opencode.ui.chat.widget_support")

describe("chat quality work and compatibility contracts", function()
	local current, restored
	local function replace(target, key, value)
		local original = target[key]
		restored[#restored + 1] = function() target[key] = original end
		target[key] = value
	end
	before_each(function()
		current, restored = surface.setup(), {}
		questions.clear_all(); permissions.clear_all(); edits.clear_all()
		app.set_session("quality", "Quality")
	end)
	after_each(function()
		for index = #restored, 1, -1 do restored[index]() end
		questions.clear_all(); permissions.clear_all(); edits.clear_all()
		surface.restore(current)
	end)

	it("indexes reviews once and deduplicates newly created previews during the same pass", function()
		edits.add_edit("live-message", "quality", {}, { message_id = "m1" })
		edits.add_edit("live-call", "other", {}, { call_id = "existing" })
		local messages, parts = {}, {}
		for index, call in ipairs({ "new", "existing", "shared", "shared", false }) do
			local id = "m" .. index
			messages[index] = { id = id }
			parts[id] = { tool_parts = { { id = "p" .. index, type = "tool", tool = "write", callID = call or nil,
				state = { status = "completed", input = { path = "preview.txt", content = "text" },
					metadata = { operation = "write", target = "preview.txt", resource = "preview.txt", existed = false } } } } }
		end
		parts.m5.tool_parts[2] = vim.deepcopy(parts.m5.tool_parts[1]); parts.m5.tool_parts[2].id = "p5-copy"
		replace(sync, "get_messages", function() return messages end)
		replace(sync, "get_message_render_parts", function(id) return parts[id] end)
		local calls, get_all = 0, edits.get_all
		replace(edits, "get_all", function() calls = calls + 1; return get_all() end)
		assert.equals(2, require("opencode.ui.chat.edit_previews").sync_session("quality"))
		assert.equals(1, calls)
		assert.is_not_nil(edits.get_edit("tool-preview:quality:m3:p3"))
		assert.is_not_nil(edits.get_edit("tool-preview:quality:m5:p5"))
		assert.is_nil(edits.get_edit("tool-preview:quality:m4:p4"))
		assert.is_nil(edits.get_edit("tool-preview:quality:m5:p5-copy"))
	end)

	it("uses rendered question and permission metadata on stable cursor moves and rejects stale layouts", function()
		local item = questions.add_form({ id = "form", sessionID = "quality", title = "Choice", fields = {
			{ key = "first", type = "boolean", default = false },
			{ key = "second", type = "boolean", default = false },
		} })
		permissions.add_permission("permission", "quality", "bash", { tool_input = { command = "pwd" } })
		chat.do_render()
		local qpos, ppos = state.questions.form, state.permissions.permission
		assert.is_not_nil(qpos.meta); assert.is_not_nil(ppos.meta)
		local qwidget, pwidget = require("opencode.ui.question_widget"), require("opencode.ui.permission_widget")
		local calls, oldq, oldp = 0, qwidget.get_lines_for_question, pwidget.get_lines_for_permission
		replace(qwidget, "get_lines_for_question", function(...) calls = calls + 1; return oldq(...) end)
		replace(pwidget, "get_lines_for_permission", function(...) calls = calls + 1; return oldp(...) end)
		local selection = questions.get_current_selection("form")[1]
		vim.api.nvim_win_set_cursor(state.winid, { qpos.start_line + qpos.meta.option_lines[selection] + 1, 0 })
		for _ = 1, 10 do require("opencode.ui.chat.questions").sync_selected_option_from_cursor() end
		vim.api.nvim_win_set_cursor(state.winid, { ppos.start_line + ppos.meta.first_interactive_line + 1, 0 })
		for _ = 1, 10 do require("opencode.ui.chat.permissions").sync_selected_option_from_cursor() end
		assert.equals(0, calls)
		questions.set_tab("form", 2)
		assert.is_nil(support.get_interactive_meta(qpos, item, "question"))
		require("opencode.ui.chat.questions").rerender_question("form")
		assert.is_not_nil(support.get_interactive_meta(qpos, item, "question"))
		local generation = qpos.render_generation
		qpos.render_generation = generation - 1
		assert.is_nil(support.get_interactive_meta(qpos, item, "question"))
	end)

	it("reads only visible summary rows in one animation batch", function()
		local lines = { "⠋ Header" }
		for index = 2, 501 do lines[index] = "  ↳ ⠋ task " .. index end
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
		state.tasks = { task = { start_line = 0, end_line = 500,
			tool_part = { id = "task", tool = "task", state = { status = "running", input = {} } } } }
		state.tools = {}
		replace(support, "get_visible_line_range", function() return 100, 102 end)
		local ranges, read = {}, vim.api.nvim_buf_get_lines
		replace(vim.api, "nvim_buf_get_lines", function(buf, first, last, strict)
			ranges[#ranges + 1] = { first, last }
			return read(buf, first, last, strict)
		end)
		assert.is_true(require("opencode.ui.chat.task_animation").update_animation_frames_in_place())
		assert.same({ { 0, 1 }, { 100, 103 } }, ranges)
	end)

	it("computes each session title once during auto fitting", function()
		local selectors = require("opencode.selectors")
		local sessions, title_calls = {}, 0
		for index = 1, 40 do
			local id = "s" .. index
			sessions[index] = { id = id,
				title = function() title_calls = title_calls + 1; return "Session " .. index end,
				is_current_session = function() return index == 20 end,
				is_current_root = function() return false end,
				is_busy = function() return false end, is_waiting = function() return false end,
				is_error = function() return false end, is_unread = function() return false end,
			}
		end
		replace(selectors, "get_active_session_views", function() return sessions end)
		replace(selectors, "get_current_session_view", function() return nil end)
		replace(selectors, "get_current_runtime_root_id", function() return "s20" end)
		state.config = { session_tabs = { enabled = true, auto_fit = true } }
		require("opencode.ui.chat.session_tabs").update_winbar()
		assert.equals(40, title_calls)
		assert.is_truthy(vim.wo[state.winid].winbar:find("Session 20", 1, true))
	end)

	it("retains the inspector document contract without computing the compact projection", function()
		local output = require("opencode.ui.chat.execute_output")
		for _, raw in ipairs({ false, "null", "", "# Heading\n\ntext\n", '{"ok":false,"missing":null,"body":"界\\nnext"}',
			'Prefix\n```json\n{"first":1}\n```\n```json\n{"second":2}\n```\nLogs',
			'```json\n{"broken":', string.rep("🌍", 100) }) do
			for _, opts in ipairs({ {}, { max_lines = 3, max_chars = 61, max_depth = 2 } }) do
				local full, document = output.describe(raw, opts), output.document(raw, opts)
				for _, field in ipairs({ "raw", "filetype", "document_lines", "document_headings", "document_truncated",
					"fields", "field_count", "prefix_lines", "suffix_lines" }) do
					assert.same(full[field], document[field], field)
				end
			end
		end
	end)
end)
