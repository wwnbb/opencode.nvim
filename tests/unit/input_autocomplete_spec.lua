describe("opencode input autocomplete", function()
	it("confirms slash commands and mentions", function()
		local autocomplete = require("opencode.ui.input.autocomplete")
		local registry = require("opencode.command_registry")
		local mentions = require("opencode.ui.input.mentions")
		local slash_commands = require("opencode.ui.input.slash_commands")

		local bufnr = vim.api.nvim_get_current_buf()
		local winid = vim.api.nvim_get_current_win()
		local previous_virtualedit = vim.o.virtualedit
		vim.o.virtualedit = "onemore"
		local state = {
			visible = true,
			bufnr = bufnr,
			winid = winid,
			mentions = { parts = {} },
			autocomplete = {},
		}

		local function set_one_line(line, col)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
			vim.api.nvim_win_set_cursor(winid, { 1, col })
		end

		local function offer(line, item, col)
			col = col or #line
			set_one_line(line, col)
			local trigger = item.kind == "mention" and mentions.detect_trigger_in_line(line, col)
				or slash_commands.detect_trigger_in_line(line, col, 0)
			trigger.row, trigger.line = 0, line
			state.autocomplete = { visible = true, selected = 1, trigger = trigger, items = { item } }
		end

		offer("/", { kind = "slash", label = "/help", command = { name = "help" } })
		local current_trigger = slash_commands.detect_trigger(state)
		assert.is_truthy(current_trigger, "slash autocomplete trigger should be current")
		assert.equals(state.autocomplete.trigger.query, current_trigger.query, "slash autocomplete query")
		assert.is_truthy(autocomplete.confirm(state), "slash autocomplete confirm should insert command")
		assert.equals("/help ", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "slash autocomplete text")

		local runs, active = 0, true
		registry.register({
			id = "test.autocomplete_popup",
			title = "Autocomplete popup",
			category = "test",
			slash = { name = "ztest_popup" },
			enabled = function() return active end,
			run = function() runs = runs + 1 end,
			on_select = function(ctx) return ctx.run() end,
		})
		state.allow_chat_commands = true
		offer("/ztest_po", { kind = "slash", label = "/ztest_popup", command = { id = "test.autocomplete_popup", name = "ztest_popup" } })
		local consumed, selected = autocomplete.confirm(state)
		assert.is_truthy(consumed, "interactive slash completion should consume the token")
		assert.equals("test.autocomplete_popup", selected.id, "selection should identify the canonical command")
		assert.equals("", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "selected command should leave no prompt token")
		assert.is_truthy(registry.select(selected.id, { source = "slash_select" }), "selection should run through the registry")
		assert.equals(1, runs, "selected command should execute once")

		active = false
		offer("/ztest_po", { kind = "slash", label = "/ztest_popup", command = { id = "test.autocomplete_popup", name = "ztest_popup" } })
		consumed, selected = autocomplete.confirm(state)
		assert.equals(false, consumed, "disabled stale completion should not be confirmed")
		assert.equals(nil, selected, "disabled stale completion should not activate")
		assert.equals("/ztest_po", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "stale completion should preserve the draft")
		assert.equals(1, runs, "disabled stale completion should not execute")
		active = true

		local offered
		for _, entry in ipairs(registry.list_slash()) do
			if entry.id == "test.autocomplete_popup" then offered = entry; break end
		end
		assert.is_truthy(offered and offered.generation, "slash completion should identify its registration")
		registry.register({
			id = "test.autocomplete_popup",
			title = "Replacement popup",
			category = "test",
			slash = { name = "ztest_popup" },
			run = function() runs = runs + 100 end,
			on_select = function(ctx) return ctx.run() end,
		})
		offer("/ztest_po", { kind = "slash", label = "/ztest_popup", command = offered })
		consumed, selected = autocomplete.confirm(state)
		assert.equals(false, consumed, "replaced completion should not be confirmed")
		assert.equals(nil, selected, "replaced completion should not activate")
		assert.equals("/ztest_po", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "replaced completion should preserve draft")
		assert.equals(1, runs, "replaced completion should not execute either registration")

		state.allow_chat_commands = false
		offer("/ztest_po", { kind = "slash", label = "/ztest_popup", command = { id = "test.autocomplete_popup", name = "ztest_popup" } })
		consumed, selected = autocomplete.confirm(state)
		assert.is_truthy(consumed, "non-chat editors should complete the command as text")
		assert.equals(nil, selected, "non-chat completion should not activate the command")
		assert.equals("/ztest_popup ", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "non-chat completion text")
		assert.equals(1, runs, "non-chat completion should not execute the command")

		state.allow_chat_commands = true
		offer("/ztest_po then", { kind = "slash", label = "/ztest_popup", command = { id = "test.autocomplete_popup", name = "ztest_popup" } }, #"/ztest_po")
		consumed, selected = autocomplete.confirm(state)
		assert.is_truthy(consumed, "completion before existing text should insert the command")
		assert.equals(nil, selected, "completion before existing text should not activate")
		assert.equals("/ztest_popup then", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "completion should preserve following text")
		assert.equals(1, runs, "completion before text should not execute the command")

		local sync = require("opencode.sync")
		local previous_agents = sync.get_agents()
		sync.handle_agents({ { name = "coder_slave", mode = "subagent" } })
		offer("@cod", { kind = "mention", label = "@coder_slave", agent = { name = "coder_slave" } })
		assert.is_truthy(autocomplete.confirm(state), "mention autocomplete confirm should insert mention")
		assert.equals("@coder_slave ", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "mention autocomplete text")

		local parts = mentions.active_parts(state)
		assert.equals(1, #parts, "mention autocomplete should create one part")
		assert.equals("coder_slave", parts[1].name, "mention autocomplete part name")
		sync.handle_agents(previous_agents)

		set_one_line("/", #"/")
		state.autocomplete = {
			visible = true,
			selected = 1,
			trigger = slash_commands.detect_trigger_in_line("/", #"/", 0),
			items = {
				{ kind = "slash", label = "/first", command = { name = "first" } },
				{ kind = "slash", label = "/second", command = { name = "second" } },
			},
		}
		assert.is_truthy(autocomplete.select_next(state), "select_next should move selection")
		assert.equals(2, state.autocomplete.selected, "select_next selected index")
		assert.is_truthy(autocomplete.select_prev(state), "select_prev should move selection")
		assert.equals(1, state.autocomplete.selected, "select_prev selected index")

		local confirmed, sent = 0, 0
		require("opencode.ui.input.keymaps").setup(bufnr, { keymaps = { send = "<C-g>" } }, {
			autocomplete_visible = function() return true end,
			autocomplete_confirm = function() confirmed = confirmed + 1 end,
			send = function() sent = sent + 1 end,
		})
		for index, key in ipairs({ "<CR>", "<Tab>", "<C-g>" }) do
			local mapping = vim.fn.maparg(key, "i", false, true)
			mapping.callback()
			assert.is_true(vim.wait(100, function() return confirmed == index end, 5), key)
		end
		assert.equals(0, sent, "completion should not send the draft")

		autocomplete.clear(state)
		registry.unregister("test.autocomplete_popup")
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
		vim.o.virtualedit = previous_virtualedit
	end)
end)

describe("autocomplete item display", function()
	local autocomplete = require("opencode.ui.input.autocomplete")
	local state
	before_each(function()
		state = {
			visible = true,
			bufnr = vim.api.nvim_get_current_buf(),
			winid = vim.api.nvim_get_current_win(),
			layout = { row = 15, col = 0, current_height = 1, content_width = 60, is_float = true },
		}
	end)
	after_each(function()
		autocomplete.clear(state)
		if state.popup then state.popup:unmount() end
	end)
	it("displays supplied items with the existing popup and selection behavior", function()
		local items = {}
		for index = 1, 12 do
			items[index] = { kind = "history", label = "Prompt " .. index }
		end
		local trigger = { query = "", row = 0, start_col = 0 }
		assert.is_true(autocomplete.show_items(state, "history", trigger, items))
		assert.equals("history", state.autocomplete.kind)
		assert.equals(10, #state.autocomplete.items)
		assert.equals(10, vim.api.nvim_win_get_height(state.autocomplete.popup.winid))
		assert.equals("opencode_input_autocomplete", vim.bo[state.autocomplete.bufnr].filetype)
		assert.is_true(autocomplete.select_next(state))
		assert.equals(2, state.autocomplete.selected)
		assert.is_true(autocomplete.show_items(state, "history", trigger, items))
		assert.equals(2, state.autocomplete.selected)
		assert.is_true(autocomplete.show_items(state, "history", { query = "next", row = 0, start_col = 0 }, items))
		assert.equals(1, state.autocomplete.selected)
	end)
	it("closes the popup when supplied items are empty or missing", function()
		local trigger = { query = "", row = 0, start_col = 0 }
		assert.is_true(autocomplete.show_items(state, "history", trigger, { { label = "Prompt" } }))
		assert.is_false(autocomplete.show_items(state, "history", trigger, {}))
		assert.is_false(autocomplete.is_visible(state))
		assert.is_nil(state.autocomplete.popup)
		assert.is_false(autocomplete.show_items(state, "history", trigger))
		assert.is_false(autocomplete.show_items(nil, "history", trigger, { { label = "Prompt" } }))
	end)
	it("keeps every resize redraw above the actual input frame with matching content", function()
		state.popup = require("nui.popup")({
			enter = false,
			relative = "editor",
			position = { row = 15, col = 8 },
			size = { width = 60, height = 1 },
			border = { style = { "┃", "", "", "", "", "", "┃", "┃" }, padding = { top = 1, bottom = 1, left = 1, right = 0 } },
		})
		state.popup:mount()
		state.bufnr, state.winid = state.popup.bufnr, state.popup.winid
		state.popup:update_layout({ position = { row = 13, col = 11 } })
		local input_row = vim.api.nvim_win_get_position(state.popup.border.winid)[1]
		local input_col = vim.api.nvim_win_get_position(state.winid)[2]
		local items = {}
		for index = 1, 10 do items[index] = { kind = "history", label = "Prompt " .. index } end
		local trigger = { query = "", row = 0, start_col = 0 }
		assert.is_true(autocomplete.show_items(state, "history", trigger, items))
		local popup = state.autocomplete.popup
		assert.equals(input_row, vim.api.nvim_win_get_position(popup.winid)[1] + vim.api.nvim_win_get_height(popup.winid))
		assert.equals(input_col, vim.api.nvim_win_get_position(popup.winid)[2])

		local command, redraws, expected_height = vim.api.nvim_command, 0, 10
		vim.api.nvim_command = function(value)
			local result = command(value)
			if value == "redraw" then
				redraws = redraws + 1
				local position = vim.api.nvim_win_get_position(popup.winid)
				assert.equals(expected_height, vim.api.nvim_win_get_height(popup.winid))
				assert.equals(expected_height, vim.api.nvim_win_get_height(popup.border.winid))
				assert.equals(expected_height, vim.api.nvim_buf_line_count(popup.bufnr))
				assert.equals(input_row, position[1] + expected_height)
				assert.equals(vim.api.nvim_win_get_position(popup.border.winid)[1], position[1])
				assert.equals(input_col, position[2])
			end
			return result
		end
		local ok, err = xpcall(function()
			assert.is_true(autocomplete.show_items(state, "history", trigger, items))
			assert.equals(0, redraws)
			expected_height = 1
			assert.is_true(autocomplete.show_items(state, "history", trigger, { items[1] }))
			expected_height = 10
			assert.is_true(autocomplete.show_items(state, "history", trigger, items))
			assert.equals(2, redraws)
		end, debug.traceback)
		vim.api.nvim_command = command
		assert.is_true(ok, err)
	end)
end)

describe("context autocomplete", function()
	local autocomplete = require("opencode.ui.input.autocomplete")
	local mentions = require("opencode.ui.input.mentions")
	local sync = require("opencode.sync")
	local state, previous_buf, previous_mode, virtualedit, previous_agents
	local function refresh(text, col)
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { text })
		vim.api.nvim_win_set_cursor(state.winid, { 1, col or #text })
		return autocomplete.refresh(state)
	end
	before_each(function()
		previous_buf, virtualedit = vim.api.nvim_get_current_buf(), vim.o.virtualedit
		previous_agents, previous_mode = sync.get_agents(), vim.fn.mode
		sync.handle_agents({ { name = "this", mode = "subagent", description = "Context reviewer" } })
		vim.o.virtualedit = "onemore"
		vim.fn.mode = function() return "i" end
		state = { visible = true, allow_context = true, bufnr = vim.api.nvim_create_buf(false, true), winid = vim.api.nvim_get_current_win() }
		vim.api.nvim_set_current_buf(state.bufnr)
	end)
	after_each(function()
		autocomplete.clear(state)
		vim.fn.mode, vim.o.virtualedit = previous_mode, virtualedit
		vim.api.nvim_set_current_buf(previous_buf)
		vim.api.nvim_buf_delete(state.bufnr, { force = true })
		sync.handle_agents(previous_agents)
	end)
	it("offers contexts before agents and preserves a same-name agent", function()
		assert.is_true(refresh("@"))
		local items = state.autocomplete.items
		assert.equals(8, #items)
		for index = 1, 7 do
			assert.equals("context", items[index].kind)
			assert.is_truthy(items[index].description:match("^Context: "))
		end
		assert.equals("mention", items[8].kind)
		assert.equals("@this", items[8].label)
		assert.equals("Agent: Context reviewer", items[8].description)
		assert.is_true(refresh("@thi"))
		assert.equals(2, #state.autocomplete.items)
		state.autocomplete.selected = 2
		assert.is_true(autocomplete.confirm(state))
		assert.equals("this", mentions.active_parts(state)[1].name)
	end)
	it("inserts the literal context without an agent attachment", function()
		assert.is_true(refresh("@vis"))
		assert.equals("@visible", state.autocomplete.items[1].label)
		assert.is_true(autocomplete.confirm(state))
		assert.same({ "@visible " }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
		assert.same({}, mentions.active_parts(state))
		assert.is_true(refresh("@thi 中文", 4))
		assert.is_true(autocomplete.confirm(state))
		assert.same({ "@this 中文" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
		assert.same({}, mentions.active_parts(state))
	end)
	for _, options in ipairs({ { allow_context = false }, { mode = "shell" } }) do
		it("suppresses contexts and rejects stale selection for " .. (options.mode or "non-chat input"), function()
			assert.is_true(refresh("@thi"))
			for key, value in pairs(options) do state[key] = value end
			assert.is_false(autocomplete.confirm(state))
			assert.same({ "@thi" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
			assert.is_true(refresh("@thi"))
			assert.equals(1, #state.autocomplete.items)
			assert.equals("mention", state.autocomplete.items[1].kind)
		end)
	end
	it("keeps context completion available to session-bound prompt editors", function()
		state.session_bound = true
		assert.is_true(refresh("@vis"))
		assert.equals("context", state.autocomplete.items[1].kind)
	end)
	it("preserves a draft changed before context confirmation", function()
		assert.is_true(refresh("@thi"))
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "@buf" })
		assert.is_false(autocomplete.confirm(state))
		assert.same({ "@buf" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
	end)
end)

describe("autocomplete draft ownership", function()
	local autocomplete = require("opencode.ui.input.autocomplete")
	local mentions = require("opencode.ui.input.mentions")
	local sync = require("opencode.sync")
	local state, previous_buf, virtualedit, previous_agents
	before_each(function()
		previous_agents = sync.get_agents()
		sync.handle_agents({ { name = "grep", mode = "subagent" } })
		previous_buf, virtualedit = vim.api.nvim_get_current_buf(), vim.o.virtualedit
		vim.o.virtualedit = "onemore"
		state = { visible = true, bufnr = vim.api.nvim_create_buf(false, true), winid = vim.api.nvim_get_current_win() }
		vim.api.nvim_set_current_buf(state.bufnr)
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "@gr", "@gr" })
		vim.api.nvim_win_set_cursor(state.winid, { 1, 3 })
		state.autocomplete = {
			visible = true, selected = 1, trigger = mentions.detect_trigger(state),
			items = { { kind = "mention", agent = { name = "grep" } } },
		}
	end)
	after_each(function()
		autocomplete.clear(state)
		vim.api.nvim_set_current_buf(previous_buf)
		vim.api.nvim_buf_delete(state.bufnr, { force = true })
		vim.o.virtualedit = virtualedit
		sync.handle_agents(previous_agents)
	end)
	for _, replacement in ipairs({ "@xx", "@", "ask @gr" }) do
		it("preserves a draft changed to " .. replacement .. " before confirmation", function()
			vim.api.nvim_buf_set_lines(state.bufnr, 0, 1, false, { replacement })
			vim.api.nvim_win_set_cursor(state.winid, { 1, #replacement })
			assert.is_false(autocomplete.confirm(state))
			assert.same({ replacement, "@gr" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
			assert.same({}, mentions.active_parts(state))
			assert.is_false(autocomplete.is_visible(state))
		end)
	end
	it("preserves both lines when the cursor moves to another mention", function()
		vim.api.nvim_win_set_cursor(state.winid, { 2, 3 })
		assert.is_false(autocomplete.confirm(state))
		assert.same({ "@gr", "@gr" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
	end)
	it("does not edit a draft whose window displays another buffer", function()
		local other = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(other)
		vim.api.nvim_buf_set_lines(other, 0, -1, false, { "@gr" })
		vim.api.nvim_win_set_cursor(state.winid, { 1, 3 })
		local ok, result = pcall(autocomplete.confirm, state)
		local original = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
		vim.api.nvim_set_current_buf(state.bufnr)
		vim.api.nvim_buf_delete(other, { force = true })
		assert.is_true(ok, result)
		assert.is_false(result)
		assert.same({ "@gr", "@gr" }, original)
	end)
	for _, update in ipairs({
		{ name = "removed", agents = {} },
		{ name = "hidden", agents = { { name = "grep", hidden = true, mode = "subagent" } } },
		{ name = "primary", agents = { { name = "grep", mode = "primary" } } },
		{ name = "renamed", agents = { { id = "grep", name = "other", mode = "subagent" } } },
	}) do
		it("does not insert an agent that is now " .. update.name, function()
			sync.handle_agents(update.agents)
			assert.is_false(autocomplete.confirm(state))
			assert.same({ "@gr", "@gr" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
			assert.same({}, mentions.active_parts(state))
		end)
	end
	it("uses a still-mentionable entry from the updated catalog", function()
		sync.handle_agents({ { name = "grep", mode = "all", description = "Updated" } })
		assert.is_true(autocomplete.confirm(state))
		assert.same({ "@grep ", "@gr" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
		assert.equals("grep", mentions.active_parts(state)[1].name)
	end)
	it("completes the current mention before a Unicode suffix", function()
		vim.api.nvim_buf_set_lines(state.bufnr, 0, 1, false, { "@gr 中文" })
		assert.is_true(autocomplete.confirm(state))
		assert.same({ "@grep 中文", "@gr" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
		assert.equals("grep", mentions.active_parts(state)[1].name)
	end)
end)
