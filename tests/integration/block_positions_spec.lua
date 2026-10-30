local chat_surface = require("tests.helpers.chat_surface")
local sync = require("opencode.sync")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local positions = require("opencode.ui.chat.positions")
local projection = require("opencode.protocol.messages")
local permissions = require("opencode.permission.state")
local questions = require("opencode.question.state")
local chat_tasks = require("opencode.ui.chat.tasks")
local nav = require("opencode.ui.chat.nav")

local SESSION = "block-positions"
local MAPS = { "questions", "permissions", "edits", "tasks", "tools", "pending_inputs", "stream_blocks" }

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

local function shell(id, command)
	return { type = "tool", id = id, name = "shell", time = { created = 1, completed = 2 }, state = {
		status = "completed", input = { command = command, description = "Run " .. command },
		content = { { type = "text", text = table.concat(vim.fn.range(1, 40), "\n") } },
	} }
end

local function part_id(message_id, index)
	return sync.get_parts(message_id)[index].id
end

local function ranges(nodes)
	local result = {}
	for id, node in pairs(nodes or {}) do
		local first, last = positions.range(node)
		result[id] = { first, last, children = node.children and ranges(node.children) or nil }
	end
	return result
end

-- Every tracked row as the accessor resolves it.
local function snapshot()
	local result = { spinner = positions.spinner_line(), messages = {} }
	for _, name in ipairs(MAPS) do result[name] = ranges(state[name]) end
	for index, pos in ipairs(state.message_positions) do
		result.messages[index] = { pos.id, positions.range(pos) }
	end
	return result
end

local function find_row(text)
	for row, line in ipairs(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)) do
		if line:find(text, 1, true) then return row - 1 end
	end
end

describe("block-anchored chat positions", function()
	local surface
	before_each(function()
		surface = chat_surface.setup()
		permissions.clear_all()
		questions.clear_all()
		app.set_session(SESSION, "Positions")
		app.set_session_status(SESSION, { type = "idle" })
	end)
	after_each(function()
		permissions.clear_all()
		questions.clear_all()
		chat_surface.restore(surface)
	end)

	it("follows an in-place update above them without rewriting the positions", function()
		update({
			user("u1", "First request", 1),
			assistant("a1", "u1", { { type = "text", text = "Intro" }, shell("s1", "ls"), { type = "text", text = "After" } }),
			user("u2", "Second request", 30),
			assistant("a2", "u2", { { type = "text", text = "Closing answer" } }, { time = { created = 31, completed = 40 } }),
		})
		questions.add_form({
			id = "question-late", sessionID = SESSION,
			fields = { { key = "choice", type = "select", title = "Pick one", options = { { label = "Yes", value = "yes" },
				{ label = "No", value = "no" } } } },
		})
		chat.do_render()
		local question = state.questions["question-late"]
		local message = state.message_positions[#state.message_positions]
		local anchors = { question.block, question.first, question.last, message.block, message.first }
		local question_start = positions.range(question)

		local shell_id = part_id("a1", 2)
		state.expanded_tools[shell_id] = true
		local before_lines = vim.api.nvim_buf_line_count(state.bufnr)
		assert.is_true(chat_tasks.rerender_tool(shell_id))
		local delta = vim.api.nvim_buf_line_count(state.bufnr) - before_lines
		assert.is_true(delta > 0, "expanding the shell panel adds rows")

		-- The rows moved; the anchors did not.
		assert.same(anchors, { question.block, question.first, question.last, message.block, message.first })
		assert.equals(question_start + delta, positions.range(question))
		local shifted = snapshot()
		chat.render()
		assert.same(snapshot(), shifted, "in-place rows equal a fresh frame's rows")

		local function jump_rows()
			local rows = {}
			for _, id in ipairs({ "u1", "a1", "u2", "a2" }) do
				assert.is_true(nav.jump_to_message(id))
				rows[id] = vim.api.nvim_win_get_cursor(state.winid)[1] - 1
			end
			return rows
		end
		local jumped = jump_rows()
		assert.is_true(jumped.u2 <= find_row("Second request") and jumped.u2 > find_row("After"))
		assert.equals(find_row("Closing answer"), jumped.a2)
		state.force_full_render = true
		chat.do_render()
		assert.same(jump_rows(), jumped, "jumps land where they do after a full render")
	end)

	it("keeps the spinner, stream range and message range on a growing streamed block", function()
		app.set_session_status(SESSION, { type = "busy" })
		update({
			user("u1", "Stream please", 1),
			assistant("a1", "u1", { { type = "text", text = "Line one\n" } }, { time = { created = 2 }, finish = nil }),
		})
		chat.do_render()
		local text = part_id("a1", 1)
		local stream = state.stream_blocks[require("opencode.ui.chat.render_state").stream_block_key(SESSION, "a1", text, "text")]
		assert.is_true(stream.separator, "the text block owns its trailing separator")
		for index, delta in ipairs({ "\n\nLine two", "\nLine three\n" }) do
			sync.handle_server_event({ id = "positions-delta-" .. index, created = index + 2, type = "session.text.delta",
				data = { sessionID = SESSION, assistantMessageID = "a1", ordinal = 0, delta = delta } })
			assert.is_true(chat.update_stream_part_block(SESSION, "a1", text))
			local shifted = snapshot()
			local spinner = positions.spinner_line()
			assert.is_truthy(vim.api.nvim_buf_get_lines(state.bufnr, spinner, spinner + 1, false)[1]:find("Build", 1, true))
			chat.render()
			assert.same(snapshot(), shifted, "delta " .. index)
		end
	end)
end)
