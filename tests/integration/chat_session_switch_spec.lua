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

	it("keeps the stack prepared by family navigation on the default view", function()
		view.session_stack = { { id = "switch-root", name = "switch-root", runtime = true } }
		actions.set_view_session(view, "switch-mid", "switch-mid", { reason = "family_navigation", preserve_cache = true })
		settle()
		assert.equals("switch-mid", app.get_session().id)
		assert.same({ { id = "switch-root", name = "switch-root", runtime = true } }, view.session_stack)
	end)

	it("keeps the stack prepared by child navigation on the default view", function()
		view.session_stack = { { id = "switch-root", name = "switch-root", runtime = true } }
		actions.set_view_session(view, "switch-mid", "switch-mid", { reason = "child_navigation", preserve_cache = true })
		settle()
		assert.same({ { id = "switch-root", name = "switch-root", runtime = true } }, view.session_stack)
	end)

	it("clears the stack for an ordinary switch on the default view", function()
		view.session_stack = { { id = "switch-root", name = "switch-root", runtime = true } }
		actions.set_view_session(view, "switch-mid", "switch-mid", { reason = "session_switch" })
		settle()
		assert.same({}, view.session_stack)
	end)
end)
