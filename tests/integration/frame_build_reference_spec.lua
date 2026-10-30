-- Frames built with warm caches and shared rows (plain lines, shifted
-- highlight copies, live config reads, one width per frame) must equal a
-- cold full render of the same stores, frame by frame.
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
local logger = require("opencode.logger")

local SESSION, OTHER = "frame-reference", "frame-reference-other"
local TURNS = 8

local function tool(id, name, input, status)
	return { type = "tool", id = id, name = name, time = { created = 1, completed = 2 }, state = {
		status = status or "completed", input = input,
		content = { { type = "text", text = "line 1\nline 2\nline 3" } }, output = "",
	} }
end

-- The benchmark transcript, smaller.
local function transcript(prefix, turns)
	local messages = {}
	for turn = 1, turns do
		local created = turn * 10
		messages[#messages + 1] = { id = prefix .. "u" .. turn, type = "user",
			text = "Request " .. turn .. "\nwith **detail**", time = { created = created } }
		local last = turn == turns
		messages[#messages + 1] = {
			id = prefix .. "a" .. turn, type = "assistant", parentID = prefix .. "u" .. turn, agent = "build",
			model = { id = "test-model", providerID = "test-provider" }, finish = (not last) and "stop" or nil,
			time = { created = created + 1, completed = (not last) and (created + 5) or nil },
			tokens = { input = 10 * turn, output = turn, reasoning = 0, cache = { read = 0, write = 0 } },
			content = {
				{ type = "text", text = "Answer " .. turn .. "\n\n- point `one`\n- point **two**\n\n```lua\nlocal x = "
					.. turn .. "\n```" },
				tool(prefix .. "s" .. turn, "shell", { command = "ls " .. turn, description = "List " .. turn }),
				tool(prefix .. "r" .. turn, "read", { path = "/srv/file" .. turn .. ".lua" }),
				{ type = "text", text = "Done with " .. turn },
			},
		}
	end
	return messages
end

local messages
local function update(session, list)
	sync.handle_session_messages(session, projection.page(session, list or messages))
end

local function warnings()
	local result = {}
	local logs, first = logger.get_logs()
	for index = first, #logs do
		local entry = logs[index]
		if entry.message:find("Chat render", 1, true) then result[#result + 1] = entry.message end
	end
	return result
end

-- The warm frame: its pure output and applied state.
local function warm_snapshot()
	local instance = chat.for_view(state)
	local original_render, rendered = instance.render, nil
	instance.render = function(...)
		local raw, nui, highlights, blocks = original_render(...)
		rendered = equivalence.rendered(raw, nui, highlights)
		rendered.blocks = {}
		for index, block in ipairs(blocks) do
			rendered.blocks[index] = { block.key, block.start, block.finish, block.highlight_start, block.highlight_finish }
		end
		return raw, nui, highlights, blocks
	end
	local ok, err = pcall(instance.do_render)
	instance.render = original_render
	assert(ok, err)
	return equivalence.snapshot({ rendered = rendered })
end

local function assert_frame(label)
	local warm = warm_snapshot()
	equivalence.assert_matches_full_render(label)
	local cold = equivalence.cold_snapshot()
	cold.rendered.blocks = nil
	local blocks = warm.rendered.blocks
	warm.rendered.blocks = nil
	assert.same(cold.rendered, warm.rendered, label .. ": built frame")
	assert.same(cold.lines, warm.lines, label .. ": buffer lines")
	assert.same(cold.highlights, warm.highlights, label .. ": marks")
	assert.same(cold.ranges, warm.ranges, label .. ": tracked positions")
	-- The cold frame becomes the applied one; the next warm frame diffs against it.
	local again = {}
	for index, block in ipairs(state.applied_frame.blocks) do
		again[index] = { block.key, block.start, block.finish, block.highlight_start, block.highlight_finish }
	end
	assert.same(again, blocks, label .. ": block list")
	assert.same({}, warnings(), label .. ": no render warnings")
end


local function part_id(message_id, index)
	return sync.get_parts(message_id)[index].id
end

describe("frame build reference", function()
	local surface, original_frame, original_task_frame, original_columns, original_title
	before_each(function()
		logger.clear()
		original_frame, original_task_frame = spinner.get_frame, animation.get_task_anim_frame
		spinner.get_frame = function() return "⠋" end
		animation.get_task_anim_frame = function() return "*" end
		original_columns = vim.o.columns
		original_title = vim.api.nvim_get_hl(0, { name = "Title" })
		surface = chat_surface.setup()
		state.config.session_tabs = { enabled = false }
		permissions.clear_all()
		questions.clear_all()
		messages = transcript("", TURNS)
		app.set_session(SESSION, "Reference")
		app.set_session_status(SESSION, { type = "busy" })
		state.full_history_sessions[SESSION] = true
		questions.add_form({ id = "reference-question", sessionID = SESSION, fields = { { key = "choice",
			type = "select", title = "Pick one", options = { { label = "Yes", value = "yes" },
				{ label = "No", value = "no" } } } } })
		update(SESSION)
	end)
	after_each(function()
		permissions.clear_all()
		questions.clear_all()
		chat_surface.restore(surface)
		spinner.get_frame, animation.get_task_anim_frame = original_frame, original_task_frame
		vim.o.columns = original_columns
		vim.api.nvim_set_hl(0, "Title", original_title)
	end)

	it("matches a cold render for each benchmark scenario", function()
		assert_frame("initial")
		assert_frame("no-op")
		local last = messages[#messages]
		for run = 1, 3 do
			sync.handle_server_event({ id = "reference-delta-" .. run, created = 1e6 + run, type = "session.text.delta",
				data = { sessionID = SESSION, assistantMessageID = last.id, ordinal = 3, delta = " word" .. run } })
			assert_frame("stream delta " .. run)
		end
		local middle = messages[TURNS + (TURNS % 2)].content[2]
		for _, status in ipairs({ "error", "completed" }) do
			middle.state.status = status
			update(SESSION)
			assert_frame("tool status " .. status)
		end
		-- A decision attaches to an otherwise unchanged shell row near the top.
		permissions.add_permission("reference-perm", SESSION, "shell", { message_id = "a2", call_id = "s2",
			tool_name = "bash", patterns = { "ls 2" }, always = { "ls *" }, tool_input = { command = "ls 2" }, timestamp = 1 })
		assert_frame("permission near the top")
		permissions.remove_permission("reference-perm")
		assert_frame("permission removed")
	end)

	it("matches a cold render when separators, width, highlights and config change", function()
		assert_frame("initial")
		-- A text block after the second turn's read row appears, then goes: the
		-- row above gains and loses its separator.
		table.insert(messages[4].content, 4, { type = "text", text = "Inserted between" })
		update(SESSION)
		assert_frame("following text appears")
		table.remove(messages[4].content, 4)
		update(SESSION)
		assert_frame("following text removed")
		-- Bash after bash: the earlier panel owns a closing blank.
		table.insert(messages[6].content, 3, tool("extra-shell", "shell", { command = "pwd", description = "Where" }))
		update(SESSION)
		assert_frame("bash after bash")
		table.remove(messages[6].content, 3)
		update(SESSION)
		assert_frame("bash after bash removed")

		vim.o.columns = math.max(60, original_columns - 30)
		assert_frame("narrower window")
		vim.o.columns = original_columns
		assert_frame("restored width")

		vim.api.nvim_set_hl(0, "Title", { fg = 0x123456, italic = true })
		assert_frame("Title changed")
		assert.equals(0x123456, vim.api.nvim_get_hl(0, { name = "OpenCodeSessionTitle" }).fg)
		vim.api.nvim_set_hl(0, "OpenCodeSessionTitle", {})
		assert_frame("title group cleared")
		assert.is_true(vim.api.nvim_get_hl(0, { name = "OpenCodeSessionTitle" }).bold)

		local config = app.get_config()
		config.syntax.min_bytes = (config.syntax.min_bytes or 0) + 1
		app.set_config(config)
		assert_frame("syntax generation changed")
		config = app.get_config()
		-- No cache refresh: the footer key carries verbosity and every cached
		-- row the config generation, so set_config alone must suffice.
		config.session.verbosity = "high"
		app.set_config(config)
		assert_frame("verbosity high")
		assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n"):find(" · step ", 1, true))
		assert_frame("verbosity high, warm")
		config.session.verbosity, config.session.thinking = "low", "show"
		app.set_config(config)
		assert_frame("verbosity low")
		assert.is_nil(table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n"):find(" · step ", 1, true))
		assert_frame("verbosity low, warm")
	end)

	it("matches a cold render across expansion, revert and session switches", function()
		assert_frame("initial")
		local shell = part_id("a3", 2)
		state.expanded_tools[shell] = true
		assert_frame("expanded shell")
		state.expanded_tools[shell] = false
		assert_frame("collapsed shell")

		app.upsert_session({ id = SESSION, title = "Reference", revert = { messageID = "u6" } })
		assert_frame("revert removes the tail")
		app.upsert_session({ id = SESSION, title = "Reference" })
		assert_frame("revert cleared")

		update(OTHER, transcript("o", 3))
		app.set_session(OTHER, "Other")
		assert_frame("switched session")
		app.set_session(SESSION, "Reference")
		assert_frame("switched back")
	end)
end)

describe("frame width", function()
	it("holds one width for a build and releases it after an error", function()
		local render = cs.module(state, require("opencode.ui.chat.render"))
		local surface = chat_surface.setup()
		local ok, err = pcall(function()
			local before = render.get_chat_text_width()
			local inner
			assert.has_error(function()
				render.with_frame_width(function()
					inner = render.get_chat_text_width()
					vim.o.columns = math.max(40, vim.o.columns - 20)
					assert.equals(inner, render.get_chat_text_width(), "fixed during the build")
					error("build failed")
				end)
			end)
			assert.equals(before, inner)
			assert.are_not.equal(before, render.get_chat_text_width(), "read live after the build")
		end)
		chat_surface.restore(surface)
		assert(ok, err)
	end)
end)

describe("buffer line sanitizing", function()
	it("matches the substitution for every control mix", function()
		local text_width = require("opencode.ui.chat.text_width")
		local function reference(text)
			return (text:gsub("\r\n", " ↵ "):gsub("\n", " ↵ "):gsub("\r", " ↵ "):gsub("%z", "<NUL>"))
		end
		for _, text in ipairs({ "", "plain", "é ✓", "a\nb", "a\r\nb", "a\rb", "a\0b", "\n\r\0", "tab\tx" }) do
			assert.equals(reference(text), text_width.sanitize_buffer_line(text), vim.inspect(text))
		end
		assert.equals("12", text_width.sanitize_buffer_line(12))
	end)
end)
