local app = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local state = require("opencode.ui.chat.state").state
local projection = require("opencode.protocol.v2.messages")
local render_state = require("opencode.ui.chat.render_state")
local local_state = require("opencode.local")
local edit_state = require("opencode.edit.state")
local chat_hl_ns = require("opencode.ui.chat.state").chat_hl_ns

describe("chat message boundaries", function()
	local session = "message-spacing"
	local original_buffer
	local preferences = require("opencode.preferences")
	local original_open, temporary_preferences

	local function update(messages)
		sync.handle_session_messages(session, projection.page(session, messages))
	end

	local function lines()
		return vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	end

	local function render()
		chat.do_render()
		return lines()
	end

	local function position(id)
		for _, pos in ipairs(state.message_positions) do
			if pos.id == id then return pos end
		end
		error("Message not rendered: " .. id)
	end

	local function assert_user_separator(id)
		local row = position(id).start_line + 1
		assert.equals("", lines()[row - 1], "user box needs an external blank separator")
		assert.is_truthy(lines()[row]:find("┃", 1, true), "message range must start at the box")
	end

	before_each(function()
		sync.clear_all()
		edit_state.clear_all()
		app.reset()
		app.set_config(vim.deepcopy(require("opencode.config").defaults))
		app.set_session(session, "Message spacing")
		app.set_session_status(session, { type = "idle" })
		render_state.reset_chat_surface({ reset_expansions = true })
		state.local_notices, state.session_stack = {}, {}
		chat.setup({ session_tabs = { enabled = true }, auto_scroll = false })
		original_buffer = vim.api.nvim_get_current_buf()
		state.bufnr = vim.api.nvim_create_buf(false, true)
		state.winid, state.visible = vim.api.nvim_get_current_win(), true
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)
	end)

	after_each(function()
		local bufnr, winid = state.bufnr, state.winid
		chat.close()
		if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_set_buf(winid, original_buffer) end
		if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		state.bufnr, state.winid, state.visible = nil, nil, false
		state.local_notices = {}
		render_state.reset_chat_surface({ reset_expansions = true })
		sync.clear_all()
		edit_state.clear_all()
		if original_open then
			local_state.message_agent.clear_session(session)
			preferences.open = original_open
			local_state.setup()
			vim.fn.delete(temporary_preferences)
			original_open, temporary_preferences = nil, nil
		end
		app.reset()
	end)

	it("keeps each user message's sent agent color after selection and history changes", function()
		original_open, temporary_preferences = preferences.open, vim.fn.tempname()
		preferences.open = function() return original_open(temporary_preferences) end
		local_state.setup()
		sync.handle_agents({
			{ id = "coder", name = "Coder", color = "#0098dd" },
			{ id = "planner", name = "Planner", color = "#cc8800" },
		})
		local function border_color(id)
			local row = position(id).start_line
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.bufnr, chat_hl_ns,
				{ row, 0 }, { row, -1 }, { details = true })) do
				local details = mark[4]
				if mark[3] == 0 and details.end_col == #"┃" then
					return vim.api.nvim_get_hl(0, { name = details.hl_group, link = false }).fg
				end
			end
		end
		local first = { id = "u1", type = "user", text = "First", time = { created = 1 } }
		local second = { id = "u2", type = "user", text = "Second", time = { created = 3 } }
		local older = { id = "u0", type = "user", text = "Older", time = { created = -1 } }
		local older_reply = { id = "a0", type = "assistant", parentID = "u0", agent = "coder",
			time = { created = 0, completed = 0 }, content = { { type = "text", text = "Reply" } } }
		local_state.message_agent.set(session, "u1", "coder")
		update({ older, older_reply, first })
		render()
		assert.equals(0x0098dd, border_color("u0"))
		assert.equals(0x0098dd, border_color("u1"))
		app.upsert_session({ id = session, agent = "planner" })
		local_state.message_agent.set(session, "u2", "planner")
		update({ older, older_reply, first, second }) -- server history contains no user agent
		render()
		assert.equals(0x0098dd, border_color("u0"))
		assert.equals(0x0098dd, border_color("u1"))
		assert.equals(0xcc8800, border_color("u2"))
		local_state.setup() -- persisted bindings survive a reload
		render()
		assert.equals(0x0098dd, border_color("u1"))
		assert.equals(0xcc8800, border_color("u2"))
	end)

	it("keeps the completed footer in place throughout the next response gap", function()
		update({
			{ id = "u1", type = "user", text = "First request", time = { created = 1000 } },
			{ id = "a1", type = "assistant", parentID = "u1", agent = "coder",
				model = { id = "test-model", providerID = "test-provider" }, finish = "stop",
				time = { created = 2000, completed = 5000 },
				content = { { type = "text", text = "Previous answer" } } },
			{ id = "u2", type = "user", text = "Next request", time = { created = 6000 } },
		})
		local baseline = render()
		local user_row = position("u2").start_line
		local prefix = vim.list_slice(baseline, 1, user_row)
		assert.is_truthy(table.concat(prefix, "\n"):find("Coder · test-model · 4.0s", 1, true))
		assert.equals(0, position("u1").start_line, "first message should not gain top padding")

		local function assert_stable_previous_turn()
			local current = render()
			assert.equals(user_row, position("u2").start_line, "next user box must not jump")
			assert.same(prefix, vim.list_slice(current, 1, user_row))
			assert_user_separator("u2")
			local footer_count = 0
			for _, line in ipairs(current) do
				if line:find("▣ Coder", 1, true) then footer_count = footer_count + 1 end
			end
			assert.equals(1, footer_count, "only the historical footer should be static")
			assert.is_not_nil(state.spinner_footer_line)
			assert.is_true(state.spinner_footer_line > user_row)
			assert.same(current, (chat.render()), "incremental render must match a full render")
		end

		app.set_session_status(session, { type = "busy" })
		assert_stable_previous_turn()
		local next_answer = { id = "a2", type = "assistant", parentID = "u2", agent = "coder",
			model = { id = "test-model", providerID = "test-provider" }, time = { created = 7000 }, content = {} }
		update({ next_answer })
		assert_stable_previous_turn()
		next_answer.content = { { type = "text", text = "New answer" } }
		update({ next_answer })
		assert_stable_previous_turn()
	end)

	it("separates user boxes when the previous answer has no metadata", function()
		for _, suffix in ipairs({ "", "\n", "\n\n" }) do
			update({
				{ id = "a", type = "assistant", time = { created = 1, completed = 2 },
					content = { { type = "text", text = "Answer without metadata" .. suffix } } },
				{ id = "u", type = "user", text = "Follow up", time = { created = 3 } },
			})
			render()
			assert.equals(3, position("u").start_line, "exactly one blank should separate the messages")
			assert_user_separator("u")
		end
	end)

	it("separates assistant text from neovim edit and patch widgets", function()
		for _, tool in ipairs({ "neovim_edit", "neovim_patch" }) do
			for _, suffix in ipairs({ "", "\n", "\n\n" }) do
				sync.clear_all()
				edit_state.clear_all()
				update({ {
					id = "assistant", type = "assistant", time = { created = 1, completed = 2 },
					content = {
						{ type = "text", text = "Before widget" .. suffix },
						{ type = "tool", id = "edit-call", name = tool, state = { status = "pending" } },
					},
				} })
				edit_state.add_edit("review", session, { { filePath = "example.txt", before = "before", after = "after" } }, {
					message_id = "assistant", call_id = "edit-call", review_mode = "readonly",
				})
				local rendered = render()
				local widget = state.edits.review
				assert.is_not_nil(widget, tool .. " widget should render")
				assert.equals("", rendered[widget.start_line], "one blank row should precede " .. tool)
				assert.equals("   Before widget", rendered[widget.start_line - 1], "extra rows should be collapsed")
			end
		end
	end)

	it("preserves the user separator through streamed appends and line replacements", function()
		app.set_session_status(session, { type = "busy" })
		update({
			{ id = "a", type = "assistant", time = { created = 1 },
				content = { { type = "text", text = "Streaming answer" } } },
			{ id = "u", type = "user", text = "Follow up", time = { created = 3 } },
		})
		render()
		assert_user_separator("u")
		local part = sync.get_parts("a")[1]
		for seq, delta in ipairs({ " continues", "\nAnother line", "\n", "\n", "Last line" }) do
			sync.handle_v2_event({ id = "evt_spacing_" .. seq, created = seq + 3,
				type = "session.text.delta", data = { sessionID = session, assistantMessageID = "a", ordinal = 0, delta = delta } })
			assert.is_true(chat.update_stream_part_block(session, "a", part.id, { field = "text", delta = delta }))
			assert_user_separator("u")
			local streamed = lines()
			state.force_full_render = true
			assert.same(streamed, render(), "streamed separator must match a full render")
		end
	end)

	it("keeps Markdown stream rows, highlights and following message ranges equal to history", function()
		app.set_session_status(session, { type = "busy" })
		update({
			{ id = "a", type = "assistant", time = { created = 1 }, content = { { type = "text", text = "#" } } },
			{ id = "u", type = "user", text = "Follow up", time = { created = 3 } },
		})
		render()
		local part = sync.get_parts("a")[1]
		local function snapshot()
			local marks = {}
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.bufnr, chat_hl_ns, 0, -1, { details = true })) do
				local d = mark[4]
				if d.hl_group and (d.hl_group:find("OpenCodeMarkdown", 1, true) or d.hl_group:sub(1, 1) == "@") then
					marks[#marks + 1] = { mark[2], mark[3], d.end_row, d.end_col, d.hl_group, d.priority }
				end
			end
			table.sort(marks, function(a, b) return vim.inspect(a) < vim.inspect(b) end)
			return { lines = lines(), marks = marks, following = vim.deepcopy(position("u")) }
		end
		for seq, delta in ipairs({ "# Heading", "\n\nA **bold", " value** with `code", "`", "\n\n```lu", "a\nreturn 1", "\n```",
			"\n\n- one\n  - nested", "\n\n| A | B |\n|---|---|", "\n| x | **y** |", "\n\n> quote\n> continued", "\n\n---" }) do
			sync.handle_v2_event({ id = "evt_markdown_" .. seq, created = seq + 3, type = "session.text.delta",
				data = { sessionID = session, assistantMessageID = "a", ordinal = 0, delta = delta } })
			assert.is_true(chat.update_stream_part_block(session, "a", part.id, { field = "text", delta = delta }))
			assert_user_separator("u")
			local live = snapshot()
			state.force_full_render = true
			render()
			local cold = snapshot()
			-- Generation identifiers intentionally advance on full renders.
			live.following.render_generation, cold.following.render_generation = nil, nil
			assert.same(live, cold, "Markdown diverged after delta: " .. delta)
		end
	end)

	it("separates local user notices from assistant text without a footer", function()
		update({ { id = "a", type = "assistant", time = { created = 1, completed = 2 },
			content = { { type = "text", text = "Answer without metadata" } } } })
		state.local_notices = { { id = "local-user", role = "user", session_id = session,
			content = "Local follow up", timestamp = 3 } }
		render()
		assert_user_separator("local-user")
		assert.equals(3, position("local-user").start_line)
	end)
end)
