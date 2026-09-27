local app = require("opencode.state")
local sync = require("opencode.sync")
local pending = require("opencode.session.pending")
local chat = require("opencode.ui.chat")
local state = require("opencode.ui.chat.state").state
local input = require("opencode.ui.input")
local history = require("opencode.ui.input.history")
local actions = require("opencode.actions")
local send = require("opencode.send")
local menu = require("opencode.ui.menu")
local slash = require("opencode.slash")
local slash_commands = require("opencode.ui.input.slash_commands")
local requests = require("opencode.protocol.v2.requests")
local render_state = require("opencode.ui.chat.render_state")

local catalog = {
	{ id = "review-id", name = "review", description = "Review the implementation" },
	{ id = "testing-id", name = "testing", description = "Check behavior" },
}

local function other_parts()
	return {
		{ type = "file", uri = "file:///tmp/notes.md", name = "notes.md" },
		{ type = "agent", name = "explore" },
	}
end

local function input_buffer()
	return vim.api.nvim_win_get_buf(input.get_winids()[1])
end

local function submit()
	vim.api.nvim_set_current_win(input.get_winids()[1])
	local mapping = vim.fn.maparg("<C-g>", "n", false, true)
	assert.is_function(mapping.callback)
	mapping.callback()
	vim.wait(30, function() return false end, 5)
end

local function input_ui_state()
	for index = 1, 20 do
		local name, value = debug.getupvalue(input.get_winids, index)
		if name == "state" then return value end
	end
	error("Input UI state unavailable")
end

local function select_skills_autocomplete()
	-- Headless Plenary tests cannot keep insert mode active between Lua calls.
	-- Set the selected popup item, then use the actual input keymap callback.
	local trigger = slash_commands.detect_trigger_in_line("/skills", #"/skills", 0)
	trigger.row, trigger.line = 0, "/skills"
	input_ui_state().autocomplete = {
		visible = true,
		selected = 1,
		trigger = trigger,
		items = { { kind = "slash", label = "/skills", command = { name = "skills" } } },
	}
end

local function press_input_key(key)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(input_buffer(), "i")) do
		if mapping.lhs == key then return mapping.callback() end
	end
	error("Input keymap unavailable: " .. key)
end

local function occurrences(text, needle)
	local count, offset = 0, 1
	while true do
		local found = text:find(needle, offset, true)
		if not found then return count end
		count, offset = count + 1, found + #needle
	end
end

describe("skill selection in the input composer", function()
	local original_buffer, old_columns, old_lines, history_file, saved
	local sent, picker, real_picker, catalog_callback, catalog_requests, delay_catalog, notices, commands

	local function record_send(text, opts)
		local body, err = requests.prompt(text, opts, "prompt-" .. tostring(#sent + 1))
		assert.is_nil(err)
		sent[#sent + 1] = { text = text, options = vim.deepcopy(opts), body = body,
			session_id = opts.session_id or app.get_session().id }
		return true
	end

	local function stage(names)
		actions.stage_skills(names, { session_id = "composer-test" })
		vim.wait(30, function() return false end, 5)
	end

	before_each(function()
		input.close(false)
		sync.clear_all(); pending.clear_all(); app.reset(); history.clear_pending()
		old_columns, old_lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 120, 40
		local config = vim.deepcopy(require("opencode.config").defaults)
		history_file = vim.fn.tempname()
		config.input.history_file = history_file
		app.set_config(config)
		app.set_connection("connected")
		app.set_session("composer-test", "Composer")
		app.upsert_session({ id = "composer-test", directory = "/composer-project" })
		sync.handle_skills(vim.deepcopy(catalog))
		render_state.reset_chat_surface({ reset_expansions = true })
		state.render_scheduled, state.session_stack = false, {}
		chat.setup({ session_tabs = { enabled = true } })
		original_buffer = vim.api.nvim_get_current_buf()
		state.bufnr = vim.api.nvim_create_buf(false, true)
		state.winid, state.visible = vim.api.nvim_get_current_win(), true
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)
		saved = { list = actions.list_skills, send = actions.send, raw_send = send.send, menu = menu.open,
			focus = actions.focus_input, notify = vim.notify }
		sent, notices, commands = {}, {}, {}
		picker, real_picker, catalog_callback, delay_catalog = nil, nil, nil, false
		catalog_requests = 0
		actions.list_skills = function(callback)
			catalog_requests = catalog_requests + 1
			if delay_catalog then catalog_callback = callback else callback(nil, vim.deepcopy(catalog)) end
		end
		actions.send, send.send = record_send, record_send
		actions.focus_input = function() return chat.focus_input() end
		menu.open = function(opts) picker = opts end
		vim.notify = function(message) notices[#notices + 1] = message end
		slash.register_defaults()
		require("opencode.ui.palette.prompt").register({ register = function(command)
			commands[command.id] = command
			require("opencode.ui.palette").register(command)
		end })
	end)

	after_each(function()
		if real_picker then real_picker.close() end
		input.close(false)
		require("opencode.ui.chat.tasks").stop_task_animation_timer()
		actions.list_skills, actions.send, send.send = saved.list, saved.send, saved.raw_send
		actions.focus_input, menu.open, vim.notify = saved.focus, saved.menu, saved.notify
		vim.api.nvim_win_set_buf(state.winid, original_buffer)
		vim.api.nvim_buf_delete(state.bufnr, { force = true })
		state.bufnr, state.winid, state.visible = nil, nil, false
		render_state.reset_chat_surface({ reset_expansions = true })
		history.configure({ history_file = history_file }); history.clear()
		sync.clear_all(); pending.clear_all(); app.reset()
		vim.o.columns, vim.o.lines = old_columns, old_lines
		vim.wait(20, function() return false end, 5)
	end)

	it("offers /skills without the singular /skill command", function()
		local available = {}
		for _, command in ipairs(slash.get_commands()) do available[command.name] = true end
		assert.is_true(available.skills)
		assert.is_nil(available.skill)
	end)

	it("merges into a closed draft, deduplicates skills and sends native IDs only on explicit submit", function()
		history.set_pending("Existing draft", other_parts())
		stage({ "review", "review", "testing" })
		assert.equals(0, #sent)
		assert.is_true(input.is_visible())
		local draft = input.get_pending_text()
		assert.is_truthy(draft:find("Existing draft", 1, true))
		assert.equals(1, occurrences(draft, "@review-id"))
		assert.equals(1, occurrences(draft, "@testing-id"))
		input.close()
		assert.equals(draft, history.get_pending())
		assert.equals(4, #history.get_pending_parts())
		chat.focus_input()
		submit()
		assert.equals(1, #sent)
		assert.equals(draft, sent[1].body.text)
		assert.equals("composer-test", sent[1].session_id)
		assert.equals("review-id", sent[1].body.skills[1].id)
		assert.equals("testing-id", sent[1].body.skills[2].id)
		assert.equals("@review-id", sent[1].body.skills[1].mention.text)
		assert.equals("@testing-id", sent[1].body.skills[2].mention.text)
		assert.equals("file:///tmp/notes.md", sent[1].body.files[1].uri)
		assert.equals("explore", sent[1].body.agents[1].name)
		assert.is_nil(sent[1].body.parts)
		assert.is_nil(sent[1].body.text:find("Use these skills", 1, true))
	end)

	it("inserts a visible mention into the live draft without losing text, focus or existing parts", function()
		history.set_pending("Before after", other_parts())
		chat.focus_input()
		local win, buf = input.get_winids()[1], input_buffer()
		vim.api.nvim_win_set_cursor(win, { 1, #"Before " })
		stage({ "review" })
		assert.equals(0, #sent)
		assert.equals(win, input.get_winids()[1])
		assert.equals(buf, input_buffer())
		assert.equals(win, vim.api.nvim_get_current_win())
		local draft = input.get_pending_text()
		assert.is_truthy(draft:find("Before", 1, true))
		assert.is_truthy(draft:find("after", 1, true))
		assert.is_true(draft:find("Before", 1, true) < draft:find("@review-id", 1, true))
		assert.is_true(draft:find("@review-id", 1, true) < draft:find("after", 1, true))
		submit()
		assert.equals(1, #sent)
		assert.equals("review-id", sent[1].body.skills[1].id)
		assert.equals("file:///tmp/notes.md", sent[1].body.files[1].uri)
		assert.equals("explore", sent[1].body.agents[1].name)
	end)

	it("keeps the current draft while the skill picker opens and confirms its choices", function()
		history.set_pending("Draft through picker", other_parts())
		chat.focus_input()
		vim.api.nvim_win_set_cursor(input.get_winids()[1], { 1, 0 })
		commands["action.skills"].run()
		assert.is_not_nil(picker)
		assert.is_true(picker.multi_select)
		assert.equals("Draft through picker", input.get_pending_text())
		assert.equals(0, #sent)
		picker.on_select({ picker.items[1], picker.items[2] })
		vim.wait(30, function() return false end, 5)
		assert.equals(1, catalog_requests)
		assert.equals(0, #sent)
		assert.equals("@review-id @testing-id Draft through picker", input.get_pending_text())
		assert.equals("composer-test", app.get_session().id)
		input.close()
		local parts = history.get_pending_parts()
		assert.equals(4, #parts)
		assert.equals("file:///tmp/notes.md", parts[1].uri)
		assert.equals("explore", parts[2].name)
	end)

	it("opens the skill picker when Enter confirms /skills in autocomplete", function()
		history.set_pending("/skills", other_parts())
		chat.focus_input()
		assert.equals("/skills", input.get_pending_text())
		select_skills_autocomplete()
		assert.equals("", press_input_key("<CR>"))
		assert.is_true(vim.wait(500, function() return picker ~= nil end, 5))
		assert.equals(0, #sent)
		assert.is_true(picker.multi_select)
		assert.equals(" Select Skills ", picker.title)
		assert.is_nil(input.get_pending_text():find("/skills", 1, true))
		picker.on_select({ picker.items[1] })
		assert.is_true(vim.wait(500, function()
			return input.get_pending_text():find("@review-id", 1, true) ~= nil
		end, 5))
		assert.equals(0, #sent)
		input.append_pending_text("Review the implementation")
		submit()
		assert.equals(1, #sent)
		assert.is_truthy(sent[1].body.text:find("Review the implementation", 1, true))
		assert.equals("review-id", sent[1].body.skills[1].id)
		assert.equals("file:///tmp/notes.md", sent[1].body.files[1].uri)
		assert.equals("explore", sent[1].body.agents[1].name)
	end)

	it("opens the picker when Tab selects /skills", function()
		history.set_pending("/skills", other_parts())
		chat.focus_input()
		select_skills_autocomplete()
		assert.equals("", press_input_key("<Tab>"))
		assert.is_true(vim.wait(500, function() return picker ~= nil end, 5))
		assert.equals("", input.get_pending_text())
		assert.is_true(picker.multi_select)
		assert.equals(0, #sent)
	end)

	it("opens the picker on Enter for an exact /skills command after completion closes", function()
		history.set_pending("/skills", other_parts())
		chat.focus_input()
		require("opencode.ui.input.autocomplete").close(input_ui_state())
		assert.equals("", press_input_key("<CR>"))
		assert.is_true(vim.wait(500, function() return picker ~= nil end, 5))
		assert.equals("", input.get_pending_text())
		assert.equals(0, #sent)
		picker.on_select({ picker.items[2] })
		assert.is_true(vim.wait(500, function()
			return input.get_pending_text():find("@testing-id", 1, true) ~= nil
		end, 5))
		assert.equals(0, #sent)
	end)

	it("treats the skills picker slash command as local even when the composer has attachments", function()
		history.set_pending("/skills", other_parts())
		chat.focus_input()
		submit()
		assert.equals(0, #sent)
		assert.is_not_nil(picker)
		picker.on_select({ picker.items[2] })
		vim.wait(30, function() return false end, 5)
		assert.is_true(input.is_visible())
		assert.is_truthy(input.get_pending_text():find("@testing-id", 1, true))
		assert.is_nil(input.get_pending_text():find("/skills", 1, true))
		assert.equals(0, #sent)
		input.append_pending_text("Check this change")
		submit()
		assert.equals(1, #sent)
		assert.equals("testing-id", sent[1].body.skills[1].id)
	end)

	it("ignores a late catalog response after the user switches sessions", function()
		delay_catalog = true
		history.set_pending("Original draft", other_parts())
		stage({ "review" })
		assert.is_function(catalog_callback)
		app.set_session("other-session", "Other")
		history.set_pending("Other session draft", other_parts())
		catalog_callback(nil, vim.deepcopy(catalog))
		vim.wait(30, function() return false end, 5)
		assert.equals(0, #sent)
		assert.equals("other-session", app.get_session().id)
		assert.equals("Other session draft", input.get_pending_text())
		assert.equals(2, #history.get_pending_parts())
		assert.is_false(input.is_visible())
	end)

	it("does not open a stale picker after its initial catalog request outlives the active session", function()
		delay_catalog = true
		history.set_pending("Original draft", other_parts())
		commands["action.skills"].run()
		assert.is_function(catalog_callback)
		assert.is_nil(picker)
		app.set_session("other-session", "Other")
		history.set_pending("New session draft", other_parts())
		catalog_callback(nil, vim.deepcopy(catalog))
		vim.wait(30, function() return false end, 5)
		assert.is_nil(picker)
		assert.equals(0, #sent)
		assert.is_false(input.is_visible())
		assert.equals("other-session", app.get_session().id)
		assert.equals("New session draft", history.get_pending())
		assert.same(other_parts(), history.get_pending_parts())
	end)

	it("does not run a scheduled skills slash command in a session selected after submit", function()
		history.set_pending("/skills", other_parts())
		chat.focus_input()
		local mapping = vim.fn.maparg("<C-g>", "n", false, true)
		assert.is_function(mapping.callback)
		mapping.callback()
		app.set_session("other-session", "Other")
		history.set_pending("New session draft", other_parts())
		vim.wait(30, function() return false end, 5)
		assert.equals(0, #sent)
		assert.is_nil(picker)
		assert.is_false(input.is_visible())
		assert.equals("New session draft", history.get_pending())
		assert.same(other_parts(), history.get_pending_parts())
	end)

	it("does not revive an already submitted draft when its skill catalog lookup finishes late", function()
		history.set_pending("Send while lookup is pending", other_parts())
		chat.focus_input()
		delay_catalog = true
		stage({ "review" })
		assert.is_function(catalog_callback)
		submit()
		assert.equals(1, #sent)
		assert.equals("Send while lookup is pending", sent[1].body.text)
		assert.is_nil(sent[1].body.skills)
		catalog_callback(nil, vim.deepcopy(catalog))
		vim.wait(30, function() return false end, 5)
		assert.equals(1, #sent)
		assert.is_false(input.is_visible())
		assert.equals("", history.get_pending())
		assert.same({}, history.get_pending_parts())
	end)

	it("restores the draft cursor after a real picker closes the composer and confirms a skill", function()
		menu.open = function(opts)
			real_picker = saved.menu(opts)
			return real_picker
		end
		history.set_pending("Before after\nLast line", other_parts())
		chat.focus_input()
		vim.api.nvim_win_set_cursor(input.get_winids()[1], { 1, #"Before " })
		commands["action.skills"].run()
		assert.is_true(vim.wait(500, function() return not input.is_visible() end, 5))
		assert.is_not_nil(real_picker)
		assert.is_true(vim.api.nvim_win_is_valid(real_picker.input.winid))
		assert.equals("Before after\nLast line", history.get_pending())
		assert.equals(0, #sent)
		local confirmed = false
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(real_picker.input.bufnr, "n")) do
			if mapping.lhs == "<CR>" then mapping.callback(); confirmed = true; break end
		end
		assert.is_true(confirmed)
		assert.is_true(vim.wait(500, function() return input.is_visible() end, 5))
		assert.equals(0, #sent)
		assert.equals("Before @review-id after\nLast line", input.get_pending_text())
		assert.same({ 1, #"Before @review-id " }, vim.api.nvim_win_get_cursor(input.get_winids()[1]))
		assert.equals(input.get_winids()[1], vim.api.nvim_get_current_win())
		submit()
		assert.equals(1, #sent)
		assert.equals("review-id", sent[1].body.skills[1].id)
		assert.equals("file:///tmp/notes.md", sent[1].body.files[1].uri)
		assert.equals("explore", sent[1].body.agents[1].name)
	end)

	it("restores native skill attachments when recalling a sent draft with the real history mapping", function()
		history.set_pending("Replay this draft", other_parts())
		stage({ "review" })
		local original = input.get_pending_text()
		submit()
		assert.equals(1, #sent)
		assert.equals("review-id", sent[1].body.skills[1].id)
		chat.focus_input()
		local mapping = vim.fn.maparg("<Up>", "i", false, true)
		assert.is_function(mapping.callback)
		mapping.callback()
		assert.is_true(vim.wait(500, function() return input.get_pending_text() == original end, 5))
		submit()
		assert.equals(2, #sent)
		assert.equals(original, sent[2].body.text)
		assert.is_not_nil(sent[2].body.skills)
		assert.equals("review-id", sent[2].body.skills[1].id)
		assert.equals("@review-id", sent[2].body.skills[1].mention.text)
	end)

	it("stages an empty draft and sends the mention only on explicit submit in its owning session", function()
		stage({ "review" })
		assert.equals(0, #sent)
		assert.is_true(input.is_visible())
		local draft = input.get_pending_text()
		assert.equals("@review-id", vim.trim(draft))
		assert.is_nil(draft:find("Use these skills", 1, true))
		app.set_session("other-session", "Other")
		submit()
		assert.equals(0, #sent)
		assert.is_true(input.is_visible())
		assert.equals(draft, input.get_pending_text())
		app.set_session("composer-test", "Composer")
		submit()
		assert.equals(1, #sent)
		assert.equals(draft, sent[1].body.text)
		assert.equals("review-id", sent[1].body.skills[1].id)
	end)
end)
