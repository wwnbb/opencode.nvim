-- Default (unbound) and session-bound views share one session-switch reset.

describe("chat session switch reset", function()
	require("opencode").setup({ server = { auto_start = false }, chat = { layout = "float", close_on_focus_lost = false }, lualine = { enabled = false } })
	local app = require("opencode.state")
	local sync = require("opencode.sync")
	local sessions = require("opencode.session")
	local actions = require("opencode.actions")
	local chat = require("opencode.ui.chat")
	local view = require("opencode.ui.chat.state").state

	local function settle() vim.wait(40, function() return false end, 5) end

	before_each(function()
		app.reset(); sync.clear_all()
		for _, id in ipairs({ "switch-root", "switch-mid", "switch-leaf" }) do
			sessions.remember({ id = id, title = id, location = { directory = vim.fn.getcwd() } }, { touch = false })
		end
		chat.create()
		sessions.set_active("switch-leaf", "switch-leaf", { preserve_cache = true })
		chat.open()
		settle()
	end)

	after_each(function()
		chat.close()
		view.session_stack = {}
		app.reset(); sync.clear_all()
	end)

	for _, case in ipairs({ { "family_navigation", true }, { "child_navigation", true }, { "session_switch", false } }) do
		it((case[2] and "keeps" or "clears") .. " the default view's stack for " .. case[1], function()
			local stack = { { id = "switch-root", name = "switch-root", runtime = true } }
			view.session_stack = vim.deepcopy(stack)
			actions.set_view_session(view, "switch-mid", "switch-mid", { reason = case[1], preserve_cache = case[2] })
			settle()
			assert.equals("switch-mid", app.get_session().id)
			assert.same(case[2] and stack or {}, view.session_stack)
		end)
	end
end)
