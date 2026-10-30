local chat_surface = require("tests.helpers.chat_surface")
local sync, app = require("opencode.sync"), require("opencode.state")
local chat, cs = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local state, tasks = cs.state, require("opencode.ui.chat.tasks")
local projection = require("opencode.protocol.messages")

local reminder = "<system-reminder>\nYou are in Plan mode. Discuss the plan with the user directly in the conversation."
	.. "\n\nDo not modify any other files.\n</system-reminder>"

local function text() return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n") end
local function key(value) vim.fn.maparg(value, "n", false, true).callback() end
local function seed(body)
	sync.clear_session_messages("reminder")
	sync.handle_session_messages("reminder", projection.page("reminder", {
		{ id = "user", type = "user", text = "Plan it", time = { created = 1 } },
		{ id = "notice", type = "synthetic", text = body, time = { created = 2 } },
		{ id = "answer", type = "assistant", time = { created = 3 }, content = { { type = "text", text = "Following answer" } } },
	}))
	chat.do_render()
end

describe("system reminder widget", function()
	local surface
	before_each(function()
		surface = chat_surface.setup()
		state.auto_scroll = surface.saved_view.auto_scroll
		app.set_session("reminder", "Reminder")
		chat.setup({ session_tabs = { enabled = true } })
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr, {})
	end)
	after_each(function() chat_surface.restore(surface) end)

	it("folds to one row and shows the literal reminder when expanded", function()
		seed(reminder)
		local id, pos = next(state.tools)
		assert.equals(1, vim.tbl_count(state.tools)); assert.equals("tool", pos.kind)
		assert.is_false(tasks.is_animating_tool_part(pos))
		assert.is_truthy(text():find("▸ System reminder · You are in Plan mode.", 1, true))
		assert.is_nil(text():find("<system-reminder>", 1, true))
		assert.is_nil(text():find("Do not modify", 1, true))
		vim.api.nvim_win_set_cursor(state.winid, { pos.start_line + 1, 0 }); key("O")
		assert.is_true(state.expanded_tools[id])
		assert.is_truthy(text():find("▾ System reminder", 1, true))
		assert.is_truthy(text():find("Do not modify any other files.", 1, true))
		assert.is_nil(text():find("system-reminder>", 1, true))
		key("O"); assert.is_nil(state.expanded_tools[id])
		assert.is_nil(text():find("Do not modify", 1, true))
		assert.is_truthy(text():find("Following answer", 1, true))
	end)

	it("leaves other synthetic text as ordinary content", function()
		seed("Plain synthetic note")
		assert.equals(0, vim.tbl_count(state.tools))
		assert.is_truthy(text():find("Plain synthetic note", 1, true))
	end)
end)
