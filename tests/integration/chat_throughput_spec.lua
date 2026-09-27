describe("chat throughput footer", function()
	it("renders turn TPS through streaming, cached updates, configuration and history reload", function()
		vim.o.columns, vim.o.lines = 140, 40
		local app = require("opencode")
		app.setup({
			server = { auto_start = false },
			lualine = { enabled = false },
			chat = { layout = "float", close_on_focus_lost = false, max_rendered_messages = 1 },
		})
		local state, sync = require("opencode.state"), require("opencode.sync")
		local chat = require("opencode.ui.chat")
		local projection = require("opencode.protocol.v2.messages")
		local client = require("opencode.client")
		local original_get, original_config = client.get_messages, vim.deepcopy(state.get_config())
		client.get_messages = function(_, _, cb) cb(nil, {}) end
		local ok, err = xpcall(function()
			local sid = "tps-session"
			sync.clear_all()
			state.set_session(sid, "TPS")
			state.set_session_status(sid, { type = "busy" })
			local first = {
				id = "a", type = "assistant", agent = "build", model = { id = "test", providerID = "test" },
				time = { created = 1000, streamed = 2000, completed = 62000 },
				tokens = { output = 60, reasoning = 40 }, finish = "tool-calls",
				content = { { type = "text", text = "Earlier step" } },
			}
			local final = {
				id = "b", type = "assistant", agent = "build", model = { id = "test", providerID = "test" },
				time = { created = 62000 }, content = { { type = "text", text = "Final answer" } },
			}
			local function update(message)
				sync.handle_session_messages(sid, { projection.project(sid, message) })
			end
			update({ id = "user", type = "user", time = { created = 0 }, text = "Hello" })
			update(first)
			update(final)
			chat.open()
			local function text()
				chat.do_render()
				return table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n")
			end
			assert.is_nil(text():find("tok/s", 1, true), "unfinished model request must not show stale TPS")
			final.time.streamed, final.time.completed, final.finish = 66000, 66001, "stop"
			final.tokens = { output = 80, reasoning = 20 }
			update(final)
			state.set_session_status(sid, { type = "idle" })
			assert.is_not_nil(text():find("40.0 tok/s", 1, true), "hidden earlier steps still contribute")
			-- The last message revision stays unchanged; the footer cache must
			-- account for updated metrics on an earlier step of the same turn.
			first.tokens.output = 110
			update(first)
			assert.is_not_nil(text():find("50.0 tok/s", 1, true))
			local config = vim.deepcopy(original_config)
			config.chat.tps = false
			state.set_config(config)
			assert.is_true(vim.wait(500, function()
				return require("opencode.ui.chat.state").state.config.tps == false
			end, 10))
			assert.is_nil(text():find("tok/s", 1, true))
			state.set_config(original_config)
			assert.is_true(vim.wait(500, function()
				return require("opencode.ui.chat.state").state.config.tps == true
			end, 10))
			assert.is_not_nil(text():find("50.0 tok/s", 1, true))
			chat.close()
			chat.open()
			assert.is_not_nil(text():find("50.0 tok/s", 1, true))
			-- Native tool completion can follow the stream end by a long time.
			-- The processing footer should also use the authoritative stream time.
			sync.handle_message_removed(sid, final.id)
			state.set_session_status(sid, { type = "busy" })
			assert.is_not_nil(text():find("150.0 tok/s", 1, true))
		end, debug.traceback)
		chat.close()
		sync.clear_all()
		state.set_config(original_config)
		client.get_messages = original_get
		assert.is_true(ok, err)
	end)
end)
