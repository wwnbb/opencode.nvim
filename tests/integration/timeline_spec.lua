local actions = require("opencode.actions")
local app_state = require("opencode.state")
local chat = require("opencode.ui.chat")
local chat_state = require("opencode.ui.chat.state").state
local chat_surface = require("tests.helpers.chat_surface")
local history = require("opencode.ui.input.history")
local input = require("opencode.ui.input")
local menu = require("opencode.ui.menu")
local projection = require("opencode.protocol.messages")
local sync = require("opencode.sync")

describe("timeline actions on a selected user turn", function()
	local surface, originals, menu_calls, load_calls, notices
	local source = "timeline-source"
	local native = {
		{ id = "u1", type = "user", text = "First prompt", time = { created = 1 } },
		{ id = "a1", type = "assistant", content = { { type = "text", text = "First answer" } }, time = { created = 2 } },
		{ id = "u2", type = "user", text = "Review [File 1] @explore @review", time = { created = 3 },
			files = { { uri = "file:///tmp/context.txt", name = "context.txt", mime = "text/plain" } },
			agents = { { name = "explore" } },
			skills = { { id = "review" } } },
		{ id = "a2", type = "assistant", content = { { type = "text", text = "Second answer" } }, time = { created = 4 } },
		{ id = "u3", type = "user", text = "Third prompt", time = { created = 5 } },
		{ id = "a3", type = "assistant", content = { { type = "text", text = "Third answer" } }, time = { created = 6 } },
	}

	local function seed(messages, session_id)
		sync.handle_session_messages(session_id or source, projection.page(session_id or source, messages))
	end

	local function timeline()
		return require("opencode.ui.timeline")
	end

	local function wait_for(predicate)
		assert.is_true(vim.wait(1000, predicate, 10), "timeline callback did not finish")
	end

	local function menu_item(options, label)
		for _, item in ipairs(options.items or {}) do
			if tostring(item.label or item.title or item.value or ""):find(label, 1, true) then return item end
		end
		error("Missing menu item " .. label .. ": " .. vim.inspect(options.items))
	end

	before_each(function()
		input.close(false)
		history.clear_pending()
		surface = chat_surface.setup()
		app_state.set_session(source, "Original")
		originals = {
			menu_open = menu.open,
			load = actions.load_session_messages,
			fork = actions.fork_session,
			switch = actions.switch_session,
			undo = actions.undo_message,
			focus_input = chat.focus_input,
			notify = vim.notify,
		}
		menu_calls, load_calls, notices = {}, {}, {}
		menu.open = function(options)
			menu_calls[#menu_calls + 1] = options
			return { close = function() end }
		end
		vim.notify = function(message) notices[#notices + 1] = tostring(message) end
	end)

	after_each(function()
		menu.open, actions.load_session_messages = originals.menu_open, originals.load
		actions.fork_session, actions.switch_session = originals.fork, originals.switch
		actions.undo_message, vim.notify = originals.undo, originals.notify
		chat.focus_input = originals.focus_input
		input.close(false)
		history.clear_pending()
		chat_surface.restore(surface)
	end)

	it("loads every page before offering searchable user turns and their actions", function()
		local complete_history = {}
		for index = 1, 103 do
			complete_history[#complete_history + 1] = {
				id = string.format("u%03d", index), type = "user", text = "Prompt " .. index,
				time = { created = index * 2 - 1 },
			}
			complete_history[#complete_history + 1] = {
				id = string.format("a%03d", index), type = "assistant", time = { created = index * 2 },
				content = { { type = "text", text = "Answer " .. index } },
			}
		end
		seed(vim.list_slice(complete_history, #complete_history - 9))
		actions.load_session_messages = function(session_id, options, callback)
			load_calls[#load_calls + 1] = { session_id = session_id, options = options }
			seed(complete_history)
			callback(nil, projection.page(source, complete_history), { complete = true })
		end

		timeline().show()
		wait_for(function() return #menu_calls == 1 end)
		assert.same({ session_id = source, options = { all = true } }, load_calls[1])
		assert.is_true(menu_calls[1].searchable)
		assert.equals(103, #menu_calls[1].items)
		local old_turn
		for _, item in ipairs(menu_calls[1].items) do
			if item.value == "u001" then old_turn = item; break end
		end
		assert.is_not_nil(old_turn)
		assert.is_truthy(old_turn.label:find("Prompt 1", 1, true))
		menu_calls[1].on_select(old_turn)
		wait_for(function() return #menu_calls == 2 end)
		for _, action in ipairs({ "Jump", "Copy", "Fork", "Revert" }) do
			menu_item(menu_calls[2], action)
		end
	end)

	it("retains staged turns for copy and fork while explaining why Jump cannot show them", function()
		seed(native)
		app_state.upsert_session({ id = source, revert = { messageID = "u2" } })
		actions.load_session_messages = function(_, _, callback)
			callback(nil, projection.page(source, native), { complete = true })
		end

		timeline().show()
		wait_for(function() return #menu_calls == 1 end)
		assert.same({ "u3", "u2", "u1" }, vim.tbl_map(function(item) return item.value end, menu_calls[1].items))
		assert.is_false(timeline().run("jump", source, "u2"))
		assert.is_truthy(table.concat(notices, " "):find("hidden by staged revert", 1, true))
	end)

	it("previews a highlighted timeline turn without closing the picker", function()
		seed(native)
		actions.load_session_messages = function(_, _, callback)
			callback(nil, projection.page(source, native), { complete = true })
		end
		chat.do_render()
		timeline().show()
		wait_for(function() return #menu_calls == 1 end)
		assert.is_function(menu_calls[1].on_move)
		menu_calls[1].on_move({ value = "u2" })
		local line = vim.api.nvim_win_get_cursor(surface.winid)[1] - 1
		local target
		for _, position in ipairs(chat_state.message_positions) do
			if position.id == "u2" then target = position; break end
		end
		assert.is_not_nil(target)
		assert.is_true(line >= target.start_line and line <= target.end_line)
		assert.equals(1, #menu_calls)
	end)

	it("offers /fork with full-session and before-turn choices", function()
		seed(native)
		actions.load_session_messages = function(_, _, callback)
			callback(nil, projection.page(source, native), { complete = true })
		end
		local calls = {}
		actions.fork_session = function(session_id, options, callback)
			calls[#calls + 1] = { session_id = session_id, options = options }
			callback(nil, { id = "full-fork", title = "Full fork" })
		end
		actions.switch_session = function(session) app_state.set_session(session.id, session.title) end
		require("opencode.slash").register_defaults()
		assert.equals("session.fork", require("opencode.command_registry").get_slash("fork").id)
		timeline().show_fork_picker()
		wait_for(function() return #menu_calls == 1 end)
		assert.equals("Full session", menu_calls[1].items[1].label)
		assert.equals(4, #menu_calls[1].items)
		menu_calls[1].on_select(menu_calls[1].items[1])
		assert.same({ { session_id = source, options = {} } }, calls)
		assert.equals("full-fork", app_state.get_session().id)
	end)

	for _, invalidation in ipairs({ "connection", "session" }) do
		for _, kind in ipairs({ "timeline", "fork", "actions" }) do
			it("ignores the " .. kind .. " menu after its " .. invalidation .. " is cancelled", function()
				seed(native)
				actions.load_session_messages = function(_, _, callback) callback(nil) end
				local forks = 0
				actions.fork_session = function() forks = forks + 1 end
				if kind == "timeline" then timeline().show()
				elseif kind == "fork" then timeline().show_fork_picker()
				else timeline().show_actions(source, "u2") end
				local pending = require("opencode.session.pending")
				if invalidation == "connection" then pending.invalidate() else pending.clear_session(source) end
				local options = menu_calls[1]
				options.on_select(kind == "actions" and menu_item(options, "Fork") or options.items[1])
				assert.equals(0, forks)
				assert.equals(1, #menu_calls)
			end)
		end
	end

	it("does not preview from a timeline menu after connection loss", function()
		seed(native)
		actions.load_session_messages = function(_, _, callback) callback(nil) end
		chat.do_render()
		timeline().show()
		local cursor = vim.api.nvim_win_get_cursor(surface.winid)
		require("opencode.session.pending").invalidate()
		menu_calls[1].on_move({ value = "u2" })
		assert.same(cursor, vim.api.nvim_win_get_cursor(surface.winid))
	end)

	for _, kind in ipairs({ "timeline", "fork" }) do
		it("does not open a late " .. kind .. " picker in another Neovim tab", function()
			seed(native)
			local callback, other_tab
			actions.load_session_messages = function(_, _, done) callback = done end
			if kind == "timeline" then timeline().show() else timeline().show_fork_picker() end
			local ok, err = xpcall(function()
				vim.cmd("tabnew")
				other_tab = vim.api.nvim_get_current_tabpage()
				callback(nil)
				assert.equals(0, #menu_calls)
				assert.equals(other_tab, vim.api.nvim_get_current_tabpage())
			end, debug.traceback)
			if other_tab and vim.api.nvim_tabpage_is_valid(other_tab) then vim.cmd("tabclose") end
			assert.is_true(ok, err)
		end)
	end

	for _, action in ipairs({ "fork", "revert" }) do
		it("saves the late " .. action .. " prompt without activating UI in another Neovim tab", function()
			seed(native)
			local callback, other_tab, focused = nil, nil, 0
			local target = action == "fork" and "late-timeline-fork" or source
			actions.fork_session = function(_, _, done) callback = done end
			actions.undo_message = function(_, _, done) callback = done end
			actions.switch_session = function(session) app_state.set_session(session.id, session.title) end
			chat.focus_input = function() focused = focused + 1 end
			timeline().run(action, source, "u2")
			local ok, err = xpcall(function()
				vim.cmd("tabnew")
				other_tab = vim.api.nvim_get_current_tabpage()
				local winid = vim.api.nvim_get_current_win()
				callback(nil, action == "fork" and { id = target, title = "Fork" } or {})
				assert.equals(0, focused)
				assert.equals(other_tab, vim.api.nvim_get_current_tabpage())
				assert.equals(winid, vim.api.nvim_get_current_win())
				assert.equals(source, app_state.get_session().id)
				assert.equals(native[3].text, history.get_pending(target))
				assert.equals(3, #history.get_pending_parts(target))
				if action == "fork" then assert.equals(target, app_state.get_session_record(target).id) end
			end, debug.traceback)
			history.clear_pending(target)
			if other_tab and vim.api.nvim_tabpage_is_valid(other_tab) then vim.cmd("tabclose") end
			assert.is_true(ok, err)
		end)
	end

	it("forks before the chosen prompt, leaves the source intact, and restores all prompt attachments", function()
		seed(native)
		local before = vim.deepcopy(sync.get_messages(source))
		local calls, switches = {}, {}
		actions.fork_session = function(session_id, options, callback)
			calls[#calls + 1] = { session_id = session_id, options = options }
			-- Native forks remap message IDs while copying the prefix before u2.
			seed({
				vim.tbl_extend("force", {}, native[1], { id = "fork-u1" }),
				vim.tbl_extend("force", {}, native[2], { id = "fork-a1" }),
			}, "timeline-fork")
			callback(nil, { id = "timeline-fork", title = "Fork" })
		end
		actions.switch_session = function(session, opts)
			switches[#switches + 1] = { session = vim.deepcopy(session), opts = vim.deepcopy(opts) }
			app_state.set_session(session.id, session.title)
		end

		timeline().run("fork", source, "u2")
		wait_for(function() return app_state.get_session().id == "timeline-fork" end)
		assert.same({ session_id = source, options = { before = "u2" } }, calls[1])
		assert.same({ { session = { id = "timeline-fork", title = "Fork" }, opts = { reason = "session_fork" } } }, switches)
		assert.same(before, sync.get_messages(source))
		assert.same({ "First prompt", "First answer" }, vim.tbl_map(function(message)
			return message.role == "user" and message.text or sync.get_parts(message.id)[1].text
		end, sync.get_messages("timeline-fork")))
		assert.equals(native[3].text, input.get_pending_text())
		local parts = input.get_pending_parts()
		assert.equals(3, #parts)
		assert.equals("file:///tmp/context.txt", parts[1].uri or parts[1].url)
		assert.equals("explore", parts[2].name)
		assert.equals("review", parts[3].skillID or parts[3].id)
	end)

	it("stages revert at the chosen message and restores its prompt in the composer", function()
		seed(native)
		input.set_pending_draft("Unsent draft", { { type = "file", uri = "file:///tmp/draft.txt" } })
		local calls = {}
		actions.undo_message = function(session_id, message_id, callback)
			calls[#calls + 1] = { session_id = session_id, message_id = message_id }
			app_state.upsert_session({ id = session_id, revert = { messageID = message_id } })
			callback(nil, { messageID = message_id })
		end

		timeline().run("revert", source, "u2")
		wait_for(function() return input.get_pending_text() == native[3].text end)
		assert.same({ { session_id = source, message_id = "u2" } }, calls)
		assert.equals("u2", app_state.get_session_record(source).revert.messageID)
		local parts = input.get_pending_parts()
		assert.equals(3, #parts)
		assert.equals("file:///tmp/context.txt", parts[1].uri or parts[1].url)
		assert.equals("explore", parts[2].name)
		assert.equals("review", parts[3].skillID or parts[3].id)
	end)

	it("copies the chosen prompt and jumps to its rendered chat row", function()
		seed(native)
		chat.do_render()
		local target
		for _, position in ipairs(chat_state.message_positions) do
			if position.id == "u2" then target = position; break end
		end
		assert.is_not_nil(target)
		vim.api.nvim_win_set_cursor(surface.winid, { 1, 0 })

		timeline().run("copy", source, "u2")
		assert.equals(native[3].text, vim.fn.getreg('"'))
		timeline().run("jump", source, "u2")
		local line = vim.api.nvim_win_get_cursor(surface.winid)[1] - 1
		assert.is_true(line >= target.start_line and line <= target.end_line)
	end)
end)
