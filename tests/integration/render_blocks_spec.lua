local chat_surface = require("tests.helpers.chat_surface")
local sync = require("opencode.sync")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local state = require("opencode.ui.chat.state").state
local projection = require("opencode.protocol.messages")
local render_blocks = require("opencode.ui.chat.render_blocks")
local permissions = require("opencode.permission.state")
local questions = require("opencode.question.state")
local edits = require("opencode.edit.state")

local SESSION = "render-blocks"

local function update(messages)
	sync.handle_session_messages(SESSION, projection.page(SESSION, messages))
end

local function user(id, text, created)
	return { id = id, type = "user", text = text, time = { created = created } }
end

local function assistant(id, parent, content, opts)
	opts = opts or {}
	return vim.tbl_extend("force", {
		id = id, type = "assistant", parentID = parent, agent = "build",
		model = { id = "test-model", providerID = "test-provider" }, finish = "stop",
		time = { created = 10, completed = 20 }, content = content,
	}, opts)
end

local function shell(id, command, status)
	return { type = "tool", id = id, name = "shell", time = { created = 1, completed = 2 }, state = {
		status = status or "completed", input = { command = command, description = "Run " .. command },
		content = { { type = "text", text = "out\nput" } },
	} }
end

local function read(id, path)
	return { type = "tool", id = id, name = "read", time = { created = 1, completed = 2 },
		state = { status = "completed", input = { path = path }, output = "" } }
end

local function subagent(id, description)
	return { type = "tool", id = id, name = "subagent", state = {
		status = "running", input = { agent = "build", description = description }, metadata = { toolCallCount = 1 },
	} }
end

local function part_id(message_id, index)
	return sync.get_parts(message_id)[index].id
end

-- Block lines and relative highlights, concatenated in order, are the flat frame.
local function assert_reassembles(frame, label)
	local lines, nui_lines, highlights = {}, {}, {}
	for _, block in ipairs(frame.blocks) do
		local content = render_blocks.content(frame, block)
		assert.equals(block.finish - block.start, #content.lines, label .. " " .. block.key)
		for row, text in ipairs(content.lines) do
			lines[#lines + 1] = text
			nui_lines[#nui_lines + 1] = content.nui_lines[row]
		end
		for _, hl in ipairs(content.highlights) do
			assert.is_true(hl.line >= 0 and (hl.end_line or hl.line) < #content.lines, label .. " relative " .. block.key)
			local absolute = vim.tbl_extend("force", {}, hl)
			absolute.line = hl.line + block.start
			if hl.end_line then absolute.end_line = hl.end_line + block.start end
			highlights[#highlights + 1] = absolute
		end
	end
	assert.same(frame.lines, lines, label .. " lines")
	assert.equals(#frame.nui_lines, #nui_lines, label .. " nui lines")
	for row, line in ipairs(frame.nui_lines) do
		assert.equals(line, nui_lines[row], label .. " nui line " .. row)
	end
	local flat = {}
	for index, hl in ipairs(frame.highlights) do flat[index] = hl end
	assert.same(flat, highlights, label .. " highlights")
end

local function check(label, expected_keys)
	chat.do_render()
	local before = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	local raw, nui, highlights, blocks = chat.render()
	assert.same(before, raw, label .. ": render must reproduce the applied buffer")
	local frame = { lines = raw, nui_lines = nui, highlights = highlights, blocks = blocks,
		positions = render_blocks.positions(state) }
	assert.same({}, render_blocks.verify(frame), label)
	assert_reassembles(frame, label)
	local keys = {}
	for _, block in ipairs(blocks) do keys[block.key] = true end
	for _, key in ipairs(expected_keys or {}) do
		assert.is_true(keys[key] == true, label .. ": missing block " .. key .. " in " .. vim.inspect(vim.tbl_keys(keys)))
	end
	return frame
end

describe("render blocks", function()
	local surface
	before_each(function()
		surface = chat_surface.setup()
		permissions.clear_all()
		questions.clear_all()
		edits.clear_all()
		app.set_session(SESSION, "Blocks")
		app.set_session_status(SESSION, { type = "idle" })
	end)
	after_each(function()
		permissions.clear_all()
		questions.clear_all()
		edits.clear_all()
		chat_surface.restore(surface)
	end)

	it("partitions the empty state with and without session chrome", function()
		check("titled empty state", { "head", "empty" })
		state.config.session_tabs = { enabled = true }
		check("untitled empty state", { "empty" })
	end)

	it("partitions completed turns, footers and separators", function()
		for _, suffix in ipairs({ "", "\n", "\n\n" }) do
			sync.clear_all()
			update({
				user("u1", "First request", 1),
				assistant("a1", "u1", { { type = "text", text = "Answer" .. suffix }, { type = "text", text = "Second part" } }),
				user("u2", "Follow up\nwith two lines", 30),
				assistant("a2", "u2", { { type = "text", text = "Done" .. suffix } }, { time = { created = 31, completed = 40 } }),
			})
			local frame = check("turns " .. vim.inspect(suffix), { "head", "user:u1", "user:u2", "footer:a2",
				"text:" .. part_id("a1", 1), "text:" .. part_id("a1", 2) })
			for _, block in ipairs(frame.blocks) do
				if block.kind == "user" or block.kind == "text" then
					assert.is_string(block.signature, block.key .. " should carry its render-cache key")
				end
			end
		end
	end)

	it("partitions a streaming answer with its processing footer", function()
		app.set_session_status(SESSION, { type = "busy" })
		update({
			user("u1", "Stream please", 1),
			assistant("a1", "u1", { { type = "text", text = "Streaming\n\n- item" } }, { time = { created = 2 }, finish = nil }),
		})
		local frame = check("streaming", { "user:u1", "text:" .. part_id("a1", 1), "processing" })
		local text = part_id("a1", 1)
		local stream = state.stream_blocks[require("opencode.ui.chat.render_state").stream_block_key(SESSION, "a1", text, "text")]
		assert.is_not_nil(stream)
		local block = render_blocks.block_at(frame.blocks, stream.start_line)
		assert.equals("text:" .. text, block.key)
		assert.equals(block.start, stream.start_line, "the text block starts where the stream range does")
		assert.equals(block.finish - 1, stream.end_line, "the text block ends with its absorbed separator")
	end)

	it("partitions tools, tasks and activity groups, collapsed and expanded", function()
		update({
			user("u1", "Work", 1),
			assistant("a1", "u1", {
				{ type = "reasoning", text = "Thinking about it", time = { created = 1, completed = 2 } },
				read("r1", "/srv/one"), read("r2", "/srv/two"),
				{ type = "text", text = "Running" },
				shell("s1", "git status"), shell("s2", "ls"),
				{ type = "text", text = "After shells" },
				shell("s3", "echo hi"), subagent("t1", "First task"), subagent("t2", "Second task"),
				{ type = "text", text = "Final" },
			}),
		})
		local tool_ids = {}
		for _, part in ipairs(sync.get_parts("a1")) do
			if part.type == "tool" or part.type == "reasoning" then tool_ids[#tool_ids + 1] = part.id end
		end
		for _, expanded in ipairs({ false, true }) do
			for _, id in ipairs(tool_ids) do
				state.expanded_tools[id], state.expanded_tasks[id] = expanded, expanded
			end
			for id in pairs(state.tools) do state.expanded_tools[id] = expanded end
			check("tools expanded=" .. tostring(expanded), { "task:" .. part_id("a1", 9), "tool:" .. part_id("a1", 5) })
		end
	end)

	it("partitions attached and standalone permissions, questions and edits", function()
		update({
			user("u1", "Edit things", 1),
			assistant("a1", "u1", {
				shell("bash-call", "ssh host 'mkdir -p x'", "running"),
				read("read-call", "/srv/data"),
				{ type = "text", text = "Before widgets\n\n" },
				{ type = "tool", id = "question-call", name = "question", state = { status = "pending" } },
				{ type = "tool", id = "edit-call", name = "neovim_edit", state = { status = "pending" } },
				{ type = "tool", id = "other-call", name = "webfetch", state = { status = "pending", input = { url = "https://x.test" } } },
			}, { time = { created = 2 }, finish = nil }),
		})
		permissions.add_permission("perm_shell", SESSION, "shell", { message_id = "a1", call_id = "bash-call",
			tool_name = "bash", patterns = { "ssh host *" }, always = { "ssh *" }, tool_input = { command = "ssh host 'mkdir -p x'" },
			timestamp = 1 })
		permissions.add_permission("perm_dir", SESSION, "external_directory", { message_id = "a1", call_id = "read-call",
			tool_name = "read", patterns = { "/srv/data/*" }, always = { "/srv/data/*" }, tool_input = {}, timestamp = 2 })
		permissions.mark_approved("perm_dir", "always")
		permissions.add_permission("perm_fetch", SESSION, "webfetch", { message_id = "a1", call_id = "other-call",
			tool_name = "webfetch", patterns = { "https://x.test" }, always = { "*" }, tool_input = {}, timestamp = 3 })
		permissions.add_permission("perm_orphan", SESSION, "bash", { timestamp = 4 })
		questions.add_form({
			id = "question-request", sessionID = SESSION,
			fields = { { key = "choice", type = "select", title = "Pick one", options = { { label = "Yes", value = "yes" } } } },
			metadata = { tool = { messageID = "a1", id = "question-call" } },
		})
		edits.add_edit("review", SESSION, { { filePath = "example.txt", before = "before", after = "after" } }, {
			message_id = "a1", call_id = "edit-call", review_mode = "readonly",
		})
		local frame = check("widgets", { "permission:perm_shell", "permission:perm_dir", "permission:perm_fetch",
			"permission:perm_orphan", "question:question-request", "edit:review" })
		local row = render_blocks.block_at(frame.blocks, state.tools[part_id("a1", 2)].start_line)
		local attached = render_blocks.block_at(frame.blocks, state.permissions.perm_dir.start_line)
		assert.equals(row.finish, attached.start, "an attached decision directly follows its row's block")
	end)

	it("partitions chrome, notices, system messages and hidden history", function()
		state.session_stack = { { name = "Parent" } }
		state.config.max_rendered_messages = 3
		update({
			user("u0", "Hidden", -2),
			assistant("a0", "u0", { { type = "text", text = "Hidden answer" } }, { time = { created = -1, completed = 0 } }),
			{ id = "sys", type = "system", description = "Instructions updated", time = { created = 1 } },
			user("u1", "Visible", 2),
			assistant("a1", "u1", { { type = "text", text = "Partial" } }, { error = { message = "Provider failed" },
				time = { created = 3, completed = 4 } }),
		})
		state.local_notices = {
			{ id = "local-user", role = "user", session_id = SESSION, content = "Local follow up", timestamp = 50 },
			{ id = "local-error", kind = "session_error", session_id = SESSION, content = "Something broke" },
			{ session_id = SESSION, content = "Anonymous **notice**" },
		}
		check("notices", { "head", "hidden_history", "system:sys", "user:u1", "error:a1",
			"notice:local-user", "notice:local-error", "notice:#3" })
	end)

	it("partitions Markdown, code and tables with content highlights", function()
		update({
			user("u1", "Show code:\n```lua\nlocal x = 1\n```", 1),
			assistant("a1", "u1", { { type = "text", text = "# Title\n\n**bold** `code` [link](https://x.test)\n\n"
				.. "```lua\nlocal value = 'Привет'\nreturn value\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n> quote\n\n" } }),
		})
		local frame = check("markdown", { "user:u1", "text:" .. part_id("a1", 1) })
		assert.is_true(#frame.highlights > 0, "the transcript should exercise content highlights")
	end)

	it("keeps earlier blocks byte-identical when a turn is appended", function()
		local first = {
			user("u1", "First", 1),
			assistant("a1", "u1", { { type = "text", text = "Answer\n\n" }, shell("s1", "ls") }),
		}
		update(first)
		local function snapshot()
			local frame = check("stable")
			local by_key = {}
			for _, block in ipairs(frame.blocks) do
				local content = render_blocks.content(frame, block)
				by_key[block.key] = { lines = content.lines, highlights = content.highlights, signature = block.signature }
			end
			return by_key
		end
		local before = snapshot()
		first[#first + 1] = user("u2", "Second", 30)
		first[#first + 1] = assistant("a2", "u2", { { type = "text", text = "More" } }, { time = { created = 31, completed = 40 } })
		update(first)
		local after = snapshot()
		for key, block in pairs(before) do
			assert.same(block, after[key], key .. " should not change when later blocks are added")
		end
		assert.is_not_nil(after["user:u2"])
	end)

	it("partitions a staged revert notice", function()
		update({
			user("u1", "Keep", 1),
			assistant("a1", "u1", { { type = "text", text = "Kept" } }),
			user("u2", "Undo me", 30),
		})
		app.upsert_session({ id = SESSION, title = "Blocks", revert = { messageID = "u2" } })
		check("revert", { "revert", "user:u1" })
	end)
end)
