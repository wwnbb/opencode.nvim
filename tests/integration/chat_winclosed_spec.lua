-- Headless regression coverage for direct chat window closes (WinClosed).
-- Split layouts previously registered no WinClosed handler at all, leaving
-- state.visible true and animation timers mutating a buffer with no window.
-- Run with: ./tests/run.sh integration

describe("opencode chat window close", function()
	it("tears down and reopens split chat windows closed directly", function()
		local function assert_eq(actual, expected, message)
			assert(
				actual == expected,
				string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual))
			)
		end

		local function assert_true(value, message)
			assert(value ~= false and value ~= nil, message)
		end

		local function wait_for(predicate, message)
			assert_true(vim.wait(500, predicate, 10), message)
		end

		vim.o.columns = 120
		vim.o.lines = 36

		local opencode = require("opencode")
		opencode.setup({
			server = {
				auto_start = false,
				lazy = true,
			},
			chat = {
				layout = "vertical",
				position = "right",
				width = 40,
			},
			lualine = {
				enabled = false,
			},
		})

		local app_state = require("opencode.state")
		local session_actions = require("opencode.session")
		local sync = require("opencode.sync")
		local local_state = require("opencode.local")
		local chat = require("opencode.ui.chat")
		local chat_state_mod = require("opencode.ui.chat.state")
		local chat_state = chat_state_mod.state

		sync.clear_all()
		app_state.reset()
		chat.create()
		sync.handle_providers({
			{
				id = "openai",
				name = "OpenAI",
				models = {
					["gpt-5.5"] = { name = "GPT-5.5" },
				},
			},
		})
		sync.handle_agents({
			{ id = "coder_v2", name = "coder_v2" },
		})
		local_state.agent.set("coder_v2")
		local_state.model.set({ providerID = "openai", modelID = "gpt-5.5" })
		session_actions.set_active("winclosed-session", "WinClosed Session", { preserve_cache = true })

		chat.open()
		assert_true(chat_state.visible, "chat should be visible after open")
		local winid = chat_state.winid
		assert_true(winid and vim.api.nvim_win_is_valid(winid), "split chat window should exist")

		-- Direct window close (user :q / :close) must tear chat state down.
		vim.api.nvim_win_close(winid, true)
		wait_for(function()
			return chat_state.visible == false
		end, "WinClosed should clear chat visibility for split layouts")
		assert_eq(chat_state.winid, nil, "WinClosed should clear the chat window id")

		-- Reopening after a direct close must work.
		chat.open()
		wait_for(function()
			return chat_state.visible == true
		end, "chat should reopen after a direct window close")
		assert_true(
			chat_state.winid and vim.api.nvim_win_is_valid(chat_state.winid),
			"reopened chat window should be valid"
		)

		-- Explicit close with the autocmd registered must stay idempotent.
		chat.close()
		assert_eq(chat_state.visible, false, "explicit close should hide the chat")
		assert_eq(chat_state.winid, nil, "explicit close should clear the window id")

		chat.open()
		chat.close()
		assert_eq(chat_state.visible, false, "second close cycle should remain clean")
		assert_eq(chat_state.winid, nil, "second close cycle should clear the window id")
	end)
end)
