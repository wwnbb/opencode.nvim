describe("live fenced code highlights", function()
	it("keeps open-block extmarks equal to a full render through v2 deltas and replacement", function()
		assert.is_true(pcall(vim.treesitter.language.add, "lua"), "Lua parser required")
		assert.is_not_nil(vim.treesitter.query.get("lua", "highlights"))
		vim.o.columns, vim.o.lines = 140, 40
		local app = require("opencode")
		app.setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "float", close_on_focus_lost = false } })
		local state, sync = require("opencode.state"), require("opencode.sync")
		local chat, cs = require("opencode.ui.chat"), require("opencode.ui.chat.state")
		local render_state = require("opencode.ui.chat.render_state")
		local client = require("opencode.client")
		local original_get = client.get_messages
		client.get_messages = function(_, _, cb) cb(nil, {}) end
		local original_config = vim.deepcopy(state.get_config())
		local ok, failure = xpcall(function()
			local event_seq = 0
			local function event(kind, data)
				event_seq = event_seq + 1
				return sync.handle_v2_event({ id = "evt_code_" .. event_seq, created = event_seq + 2,
					type = "session." .. kind, data = vim.tbl_extend("force", {
						sessionID = "code-session", assistantMessageID = "assistant", ordinal = 0,
					}, data or {}) })
			end
			sync.clear_all()
			state.set_session("code-session", "Code stream")
			state.set_session_status("code-session", { type = "busy" })
			sync.handle_message_updated({ id = "user", sessionID = "code-session", role = "user", time = { created = 1 } })
			sync.handle_part_updated({ id = "user-code", sessionID = "code-session", messageID = "user", type = "text",
				text = "@example.lua\n```lua\nlocal user_value = 42\n```" })
			event("step.started", { started = 2, agent = "build", model = { providerID = "test", id = "test" } })
			event("text.started")
			event("text.delta", { delta = "`" })
			event("tool.input.started", { id = "bash", name = "bash" })
			event("tool.called", { id = "bash", input = { command = "echo footer" } })
			event("tool.success", { id = "bash", content = { { type = "text", text = "footer" } } })
			local text_id, tool_id = sync.get_parts("assistant")[1].id, sync.get_parts("assistant")[2].id
			cs.state.local_notices = { { id = "local-code", role = "user", session_id = "code-session",
				content = "```lua\nreturn 7\n```", timestamp = 3 } }
			chat.open()
			chat.do_render()
			cs.state.auto_scroll = false
			local key = render_state.stream_block_key("code-session", "assistant", text_id, "text")
			assert.is_not_nil(cs.state.stream_blocks[key])
			local function snapshot()
				local marks = {}
				local lines = vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false)
				for index, line in ipairs(lines) do
					if line:sub(2) == " Build · test" then lines[index] = "* Build · test" end
				end
				for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.get_bufnr(), cs.chat_hl_ns, 0, -1, { details = true })) do
					local d = mark[4]
					if d.hl_group and (d.hl_group:sub(1, 1) == "@" or d.hl_group:find("OpenCodeSyntax", 1, true)) then
						marks[#marks + 1] = { mark[2], mark[3], d.end_row, d.end_col, d.hl_group, d.priority }
					end
				end
				table.sort(marks, function(a, b) return vim.inspect(a) < vim.inspect(b) end)
				return { lines = lines, marks = marks }
			end
			local function assert_cold_equal()
				local live = snapshot()
				cs.state.force_full_render = true
				chat.do_render()
				assert.same(live, snapshot(), "streamed and full-rendered snapshots differ")
			end
			local local_position
			for _, position in ipairs(cs.state.message_positions) do
				if position.id == "local-code" then local_position = position end
			end
			assert.is_not_nil(local_position)
			assert.is_true(vim.iter(snapshot().marks):any(function(mark)
				return mark[1] >= local_position.start_line and mark[1] <= local_position.end_line
			end), "local user notices lost their highlights")
			local function assistant_marks()
				local block = cs.state.stream_blocks[key]
				local count = 0
				for _, mark in ipairs(snapshot().marks) do
					if mark[1] >= block.start_line and mark[1] <= block.end_line then count = count + 1 end
				end
				return count
			end
			local function delta(text)
				local before_tool = cs.state.tools[tool_id] and cs.state.tools[tool_id].start_line
				event("text.delta", { delta = text })
				assert.is_true(chat.update_stream_part_block("code-session", "assistant", text_id))
				if before_tool then assert.is_true(cs.state.tools[tool_id].start_line > cs.state.stream_blocks[key].end_line) end
				assert_cold_equal()
			end
			for _, text in ipairs({ "`", "`", "lu", "a", "\n", "local value = 1", "2", "\n--[[", "\nПривет 😀", "\n]]",
				"\nlocal s = \"partial", " string\"", "\nreturn value" }) do
				delta(text)
			end
			assert.is_true(assistant_marks() > 0, "open block must be highlighted while the session is busy")
			assert.equals("busy", state.get_session_status("code-session").type)
			-- A closing fence may be split or invalidated by the next same-line delta.
			for _, text in ipairs({ "\n`", "`", "`", "x", "\n```", "\nafter", " more prose" }) do delta(text) end
			local block = cs.state.stream_blocks[key]
			for _, mark in ipairs(snapshot().marks) do assert.is_true(mark[1] ~= block.end_line) end
			assert.is_true(assistant_marks() > 0)
			-- Authoritative replacement removes all stale ranges, even with unchanged line count.
			event("text.ended", { text = "```lua\nreturn 9" })
			assert.is_true(chat.update_stream_part_block("code-session", "assistant", text_id))
			assert_cold_equal()
			local cfg = vim.deepcopy(original_config)
			cfg.syntax.max_bytes = 3
			state.set_config(cfg); chat.do_render()
			assert.equals(0, assistant_marks(), "old code colors survive a size limit")
			state.set_config(original_config); chat.do_render()
			assert.is_true(assistant_marks() > 0)
			cfg = vim.deepcopy(original_config); cfg.syntax.assistant_markdown = false
			state.set_config(cfg)
			vim.wait(60, function() return false end)
			chat.do_render(); assert.equals(0, assistant_marks())
			state.set_config(original_config)
			vim.wait(60, function() return false end)
			chat.do_render()
			vim.cmd("colorscheme default")
			vim.wait(60, function() return false end)
			assert_cold_equal()
			assert.is_true(assistant_marks() > 0)
			local before = snapshot()
			assert.is_false(chat.update_stream_part_block("foreign-session", "assistant", text_id))
			assert.same(before, snapshot())
			state.set_session("foreign-session", "Other chat"); chat.do_render()
			local foreign = snapshot()
			event("text.delta", { delta = "9" })
			assert.is_false(chat.update_stream_part_block("code-session", "assistant", text_id))
			assert.same(foreign, snapshot())
			state.set_session("code-session", "Code stream"); chat.do_render()
			assert.is_true(assistant_marks() > 0)
			assert_cold_equal()
			state.set_session_status("code-session", { type = "idle" })
			chat.do_render()
			assert.is_true(assistant_marks() > 0, "abort/idle must preserve open code highlights")
			chat.close(); chat.open(); chat.do_render()
			assert.is_true(assistant_marks() > 0, "reopen lost open block highlights")
			assert_cold_equal()
			local open_marks = snapshot().marks
			event("step.ended", { finish = "stop" })
			chat.do_render()
			assert.is_nil(cs.state.stream_blocks[key])
			assert.same(open_marks, snapshot().marks, "completion discarded an unclosed fence")
		end, debug.traceback)
		chat.close(); sync.clear_all(); state.set_config(original_config)
		client.get_messages = original_get
		assert.is_true(ok, failure)
	end)
end)
