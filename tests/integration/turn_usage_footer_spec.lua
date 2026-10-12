describe("derived turn usage in the actual chat footer", function()
	it("includes hidden steps, refreshes earlier-step metrics, and follows idle and staged revert boundaries", function()
		vim.o.columns, vim.o.lines = 140, 40
		require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
			session = { verbosity = "high" }, chat = { layout = "float", close_on_focus_lost = false, max_rendered_messages = 2 } })
		local state, sync, chat = require("opencode.state"), require("opencode.sync"), require("opencode.ui.chat")
		local projection, client = require("opencode.protocol.messages"), require("opencode.client")
		local original_get = client.get_messages
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		local ok, err = xpcall(function()
			local sid = "turn-ui"
			sync.clear_all(); state.set_session(sid, "Turns")
			local function put(message) sync.handle_session_messages(sid, { projection.project(sid, message) }) end
			local function step(id, created, finish)
				return { id = id, type = "assistant", agent = "build", model = { id = "test", providerID = "test" },
					time = { created = created, completed = created + 1 }, finish = finish,
					tokens = { input = 10, output = 2, reasoning = 1, cache = { read = 20, write = 3 } }, content = { { type = "text", text = id } } }
			end
			put({ id = "u", type = "user", time = { created = 0 }, text = "Prompt" })
			local earlier, final = step("a", 1, "tool-calls"), step("b", 3, "stop")
			put(earlier); put({ id = "steer", type = "user", time = { created = 2 }, text = "Steer" }); put(final)
			put({ id = "idle", type = "idle", time = { created = 5 } })
			chat.open()
			local function text() chat.do_render(); return table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n") end
			assert.truthy(text():find("turn 2 steps: 32 new + 40 cached = 72 tok", 1, true))
			assert.truthy(text():find("Step · input 10 · output 2 · reasoning 1 · cache read 20 · cache write 3", 1, true))
			assert.truthy(text():find("Turn · input 20 · output 4 · reasoning 2 · cache read 40 · cache write 6", 1, true))
			earlier.tokens.input = 20; put(earlier)
			assert.truthy(text():find("turn 2 steps: 42 new + 40 cached = 82 tok", 1, true))
			assert.truthy(text():find("Turn · input 30 · output 4 · reasoning 2 · cache read 40 · cache write 6", 1, true))
			state.upsert_session({ id = sid, revert = { messageID = "steer" } }, { touch = false })
			assert.is_nil(text():find("turn 2 steps", 1, true))
		end, debug.traceback)
		chat.close(); sync.clear_all(); client.get_messages = original_get
		assert.is_true(ok, err)
	end)
end)
