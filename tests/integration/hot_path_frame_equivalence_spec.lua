local oracle = require("tests.helpers.render_equivalence")

describe("hot-path frame equivalence", function()
	it("matches cold full computation after every streamed Markdown change", function()
		local app = require("opencode.state")
		local sync = require("opencode.sync")
		local chat = require("opencode.ui.chat")
		local cs = require("opencode.ui.chat.state").state
		local projection = require("opencode.protocol.v2.messages")
		local spinner = require("opencode.ui.spinner")
		local animation = require("opencode.ui.chat.task_animation")
		local original_frame, original_task_frame = spinner.get_frame, animation.get_task_anim_frame
		local original_config = app.get_config()
		local original_columns, original_lines = vim.o.columns, vim.o.lines
		local config = vim.deepcopy(require("opencode.config").defaults)
		config.server.auto_start, config.lualine.enabled = false, false
		config.chat.layout, config.chat.close_on_focus_lost = "vertical", false
		config.chat.auto_scroll = false
		app.set_config(config)
		vim.o.columns, vim.o.lines = 120, 40
		spinner.get_frame, animation.get_task_anim_frame = function() return "*" end, function() return "*" end
		local ok, err = xpcall(function()
			sync.clear_all()
			app.set_session("frame-trace", "Frame trace")
			app.set_session_status("frame-trace", { type = "idle" })
			local message = projection.project("frame-trace", {
				id = "frame-assistant", type = "assistant", time = { created = 1 },
				content = { { type = "text", text = "Intro" }, {
					type = "tool", id = "frame-tool", name = "shell", time = { created = 1, completed = 2 },
					state = { status = "completed", input = { command = "echo footer" }, content = { { type = "text", text = "footer" } } },
				} },
			})
			sync.handle_session_messages("frame-trace", { message })
			chat.open()
			chat.do_render()
			cs.auto_scroll = false
			local part_id = message.parts[1].id
			local function check(label)
				local live = oracle.snapshot()
				local cold = oracle.cold_snapshot()
				cold.rendered = nil
				assert.same(cold, live, label)
				-- Pure values cover preserved blank flags as well as byte highlights.
				local raw, nui, highlights = chat.render()
				local warm = oracle.rendered(raw, nui, highlights)
				assert.same(oracle.cold_snapshot().rendered, warm, label .. " pure render")
			end
			local trace = {
				" **bold", "**\n\n9. item", "\n10. next", "\n   - nested 世界 é 😀\tword",
				"\n\n| Heading | Link |\n|---|---|\n| cell | [late] |",
				"\n\n[late]: https://example.test/path", "\n\n```lu", "a\n",
				"local value = 'Привет'", "\n\nreturn value", "\n``", "`", "changed", "\n```\nAfter",
			}
			for index, delta in ipairs(trace) do
				sync.handle_v2_event({ id = "frame-event-" .. index, created = index + 2, type = "session.text.delta",
					data = { sessionID = "frame-trace", assistantMessageID = "frame-assistant", ordinal = 0, delta = delta } })
				assert.is_true(chat.update_stream_part_block("frame-trace", "frame-assistant", part_id))
				check("delta " .. index)
			end
			sync.handle_v2_event({ id = "frame-ended", created = 100, type = "session.text.ended",
				data = { sessionID = "frame-trace", assistantMessageID = "frame-assistant", ordinal = 0,
					text = "Replacement\n\n```lua\nreturn 9" } })
			assert.is_true(chat.update_stream_part_block("frame-trace", "frame-assistant", part_id))
			check("authoritative replacement")
		end, debug.traceback)
		chat.close()
		sync.clear_all()
		app.reset()
		app.set_config(original_config)
		spinner.get_frame, animation.get_task_anim_frame = original_frame, original_task_frame
		vim.o.columns, vim.o.lines = original_columns, original_lines
		assert.is_true(ok, err)
	end)
end)
