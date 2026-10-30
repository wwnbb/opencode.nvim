local chat_surface = require("tests.helpers.chat_surface")
local equivalence = require("tests.helpers.render_equivalence")
local sync = require("opencode.sync")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local projection = require("opencode.protocol.messages")
local permissions = require("opencode.permission.state")
local questions = require("opencode.question.state")
local spinner = require("opencode.ui.spinner")
local animation = require("opencode.ui.chat.task_animation")
local chat_tasks = require("opencode.ui.chat.tasks")

local SESSION = "block-apply"

local function update(messages)
	sync.handle_session_messages(SESSION, projection.page(SESSION, messages))
end

local function user(id, text, created)
	return { id = id, type = "user", text = text, time = { created = created } }
end

local function assistant(id, parent, content, opts)
	return vim.tbl_extend("force", {
		id = id, type = "assistant", parentID = parent, agent = "build",
		model = { id = "test-model", providerID = "test-provider" }, finish = "stop",
		time = { created = 10, completed = 20 }, content = content,
	}, opts or {})
end

local function shell(id, command, status)
	return { type = "tool", id = id, name = "shell", time = { created = 1, completed = 2 }, state = {
		status = status or "completed", input = { command = command, description = "Run " .. command },
		content = { { type = "text", text = "out\nput" } },
	} }
end

local function read(id, path, status)
	return { type = "tool", id = id, name = "read", time = { created = 1, completed = 2 },
		state = { status = status or "completed", input = { path = path }, output = "" } }
end

local function part_id(message_id, index)
	return sync.get_parts(message_id)[index].id
end

local logger = require("opencode.logger")
local full_clears = 0

-- Every frame after the first must take the block path without warnings.
local function render(label)
	local before = full_clears
	chat.do_render()
	assert.is_not_nil(state.applied_frame, label .. ": applied frame recorded")
	if label ~= "initial" and label ~= "running tools" then
		assert.equals(before, full_clears, label .. ": block path")
	end
	equivalence.assert_matches_full_render(label)
end

local function block_warnings()
	local result = {}
	local logs, first = logger.get_logs()
	for index = first, #logs do
		if logs[index].message:find("Chat render blocks", 1, true) then result[#result + 1] = logs[index].message end
	end
	return result
end

local function block(key)
	for _, item in ipairs(state.applied_frame.blocks) do
		if item.key == key then return item end
	end
	error("no block " .. key)
end

-- Ids of the chat marks on rows at or after row, keyed by id with their row.
local function marks_from(row)
	local result = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.bufnr, cs.chat_hl_ns, { row, 0 }, -1, {})) do
		result[mark[1]] = mark[2]
	end
	return result
end

describe("block-applied chat frames", function()
	local surface, original_frame, original_task_frame, original_columns, glyph, clear_namespace
	before_each(function()
		logger.clear()
		clear_namespace = vim.api.nvim_buf_clear_namespace
		vim.api.nvim_buf_clear_namespace = function(bufnr, ns, start, finish)
			if bufnr == state.bufnr and ns == cs.chat_hl_ns and start == 0 and finish == -1 then full_clears = full_clears + 1 end
			return clear_namespace(bufnr, ns, start, finish)
		end
		original_frame, original_task_frame = spinner.get_frame, animation.get_task_anim_frame
		original_columns = vim.o.columns
		glyph = "⠋"
		spinner.get_frame = function() return glyph end
		animation.get_task_anim_frame = function() return "*" end
		surface = chat_surface.setup()
		permissions.clear_all()
		questions.clear_all()
		app.set_session(SESSION, "Blocks")
		app.set_session_status(SESSION, { type = "idle" })
		assert.is_truthy(vim.g.opencode_debug_render_blocks, "the test init enables block verification")
	end)
	after_each(function()
		vim.api.nvim_buf_clear_namespace = clear_namespace
		assert.same({}, block_warnings())
		permissions.clear_all()
		questions.clear_all()
		chat_surface.restore(surface)
		spinner.get_frame, animation.get_task_anim_frame = original_frame, original_task_frame
		vim.o.columns = original_columns
	end)

	it("matches a full render while streaming, ticking the spinner and updating in place", function()
		app.set_session_status(SESSION, { type = "busy" })
		update({
			user("u1", "Stream please", 1),
			assistant("a1", "u1", { { type = "text", text = "Intro" }, shell("s1", "ls"),
				{ type = "reasoning", text = "Thinking", time = { created = 1, completed = 2 } } },
				{ time = { created = 2 }, finish = nil }),
		})
		render("initial")
		local text = part_id("a1", 1)
		local deltas = { " **bold", "**\n\n- item", "\n- next", "\n\n```lua\nlocal x", " = 1\n```\n", "After" }
		for index, delta in ipairs(deltas) do
			sync.handle_server_event({ id = "apply-delta-" .. index, created = index + 2, type = "session.text.delta",
				data = { sessionID = SESSION, assistantMessageID = "a1", ordinal = 0, delta = delta } })
			assert.is_true(chat.update_stream_part_block(SESSION, "a1", text))
			equivalence.assert_matches_full_render("in-place delta " .. index)
			assert.is_not_nil(require("opencode.ui.chat.render_state").applied_frame(),
				"a stream update keeps the applied frame")
			if index % 2 == 0 then render("render after delta " .. index) end
		end
		for index, next_glyph in ipairs({ "⠙", "⠹" }) do
			glyph = next_glyph
			chat.update_spinner_only()
			equivalence.assert_matches_full_render("spinner tick " .. index)
			render("render after spinner tick " .. index)
		end
		local shell_id = part_id("a1", 2)
		state.expanded_tools[shell_id] = true
		assert.is_true(chat_tasks.rerender_tool(shell_id))
		render("render after an in-place expand")
		state.expanded_tools[shell_id] = false
		assert.is_true(chat_tasks.rerender_tool(shell_id))
		equivalence.assert_matches_full_render("in-place collapse")
		render("render after an in-place collapse")
	end)

	it("matches a full render across tool, widget, turn, revert and width changes", function()
		local first = {
			user("u1", "Work", 1),
			assistant("a1", "u1", {
				read("r1", "/srv/one", "running"), { type = "text", text = "Middle **text**" },
				shell("s1", "git status", "running"), shell("s2", "ls"),
				{ type = "text", text = "Done" },
			}),
		}
		update(first)
		render("running tools")
		first[2].content[1].state.status = "completed"
		first[2].content[3].state.status = "completed"
		update(first)
		render("completed tools")

		local read_id, shell_id = part_id("a1", 1), part_id("a1", 3)
		state.expanded_tools[shell_id] = true
		render("expanded shell")
		state.expanded_tools[read_id] = true
		render("expanded read")
		state.expanded_tools[shell_id], state.expanded_tools[read_id] = false, false
		render("collapsed")

		-- A decision attached to the first row, near the top, appears and goes.
		permissions.add_permission("perm_read", SESSION, "external_directory", { message_id = "a1", call_id = "r1",
			tool_name = "read", patterns = { "/srv/one/*" }, always = { "/srv/one/*" }, tool_input = {}, timestamp = 1 })
		render("permission attached to the first row")
		permissions.move_selection("perm_read", 1)
		render("permission selection moved")
		permissions.mark_approved("perm_read", "once")
		render("permission approved")
		permissions.remove_permission("perm_read")
		render("permission removed")
		permissions.add_permission("perm_shell", SESSION, "shell", { message_id = "a1", call_id = "s1",
			tool_name = "bash", patterns = { "git status" }, always = { "git *" }, tool_input = { command = "git status" },
			timestamp = 2 })
		render("permission attached to a shell panel")
		permissions.remove_permission("perm_shell")
		render("shell permission removed")
		questions.add_form({
			id = "question-top", sessionID = SESSION,
			fields = { { key = "choice", type = "select", title = "Pick one", options = { { label = "Yes", value = "yes" },
				{ label = "No", value = "no" } } } },
		})
		render("orphan question")
		questions.remove_question("question-top")
		render("question removed")

		first[#first + 1] = user("u2", "Follow up", 30)
		first[#first + 1] = assistant("u2-answer", "u2", { { type = "text", text = "More" }, shell("s3", "pwd") },
			{ time = { created = 31, completed = 40 } })
		update(first)
		render("appended turn")
		app.upsert_session({ id = SESSION, title = "Blocks", revert = { messageID = "u2" } })
		render("staged revert")
		app.upsert_session({ id = SESSION, title = "Blocks" })
		render("revert cleared")

		vim.o.columns = math.max(60, original_columns - 30)
		render("narrower window")
		vim.o.columns = original_columns
		render("restored width")
	end)

	it("rewrites only the changed block and keeps the marks of later blocks", function()
		local messages = {
			user("u1", "Work", 1),
			assistant("a1", "u1", { { type = "text", text = "Alpha" }, shell("s1", "ls"), { type = "text", text = "**Omega**" } }),
		}
		update(messages)
		render("initial")
		local text_key = "text:" .. part_id("a1", 1)
		local calls = {}
		local set_lines = vim.api.nvim_buf_set_lines
		vim.api.nvim_buf_set_lines = function(bufnr, start, finish, strict, lines)
			if bufnr == state.bufnr then calls[#calls + 1] = { start, finish, #lines } end
			return set_lines(bufnr, start, finish, strict, lines)
		end
		local ok, err = xpcall(function()
			for _, case in ipairs({ { text = "Alpha beta", delta = 0 }, { text = "Alpha\n\nbeta", delta = 2 } }) do
				local changed = block(text_key)
				local later = marks_from(changed.finish)
				assert.is_true(next(later) ~= nil, "later blocks carry marks")
				calls = {}
				messages[2].content[1].text = case.text
				update(messages)
				chat.do_render()
				local count = changed.finish - changed.start
				assert.same({ { changed.start, changed.finish, count + case.delta } }, calls, case.text)
				local after = marks_from(changed.finish + case.delta)
				for id, row in pairs(later) do
					assert.equals(row + case.delta, after[id], "mark " .. id .. " keeps its id and moves with its text")
				end
				equivalence.assert_matches_full_render(case.text)
			end
			calls = {}
			chat.do_render()
			assert.same({}, calls, "an unchanged frame writes nothing")
		end, debug.traceback)
		vim.api.nvim_buf_set_lines = set_lines
		assert.is_true(ok, err)
	end)
end)
