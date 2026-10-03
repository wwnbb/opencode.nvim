local surface_helper = require("tests.helpers.chat_surface")
local chat = require("opencode.ui.chat")
local state = require("opencode.ui.chat.state").state
local tasks = require("opencode.ui.chat.task_animation")
local messages = require("opencode.ui.chat.messages")
local app = require("opencode.state")

describe("chat animation timer ownership", function()
	local surface, callbacks, schedule_wrap, clock, now
	before_each(function()
		surface = surface_helper.setup()
		callbacks, now = {}, 0
		schedule_wrap, clock = vim.schedule_wrap, vim.uv.now
		vim.schedule_wrap = function(callback)
			callbacks[#callbacks + 1] = callback
			return function() end
		end
		vim.uv.now = function() return now end
	end)
	after_each(function()
		messages.stop_spinner_animation_timer()
		tasks.stop_task_animation_timer()
		vim.schedule_wrap, vim.uv.now = schedule_wrap, clock
		surface_helper.restore(surface)
	end)

	for _, restart in ipairs({ false, true }) do
		it("ignores an old task tick after " .. (restart and "restart" or "stop"), function()
			local part = { id = "bash", type = "tool", tool = "bash", state = { status = "running" } }
			state.tools = { bash = { start_line = 0, end_line = 0, tool_part = part } }
			vim.api.nvim_buf_set_lines(surface.bufnr, 0, -1, false, { "Bash |" })
			tasks.start_task_animation_timer()
			local old = callbacks[1]
			tasks.stop_task_animation_timer()
			if restart then tasks.start_task_animation_timer() end
			local timer, frame = state.task_anim_timer, state.task_anim_frame
			old()
			assert.equals(frame, state.task_anim_frame)
			assert.equals(timer, state.task_anim_timer)
			if restart then
				callbacks[2]()
				assert.equals(frame + 1, state.task_anim_frame)
			end
		end)

		it("ignores an old footer tick after " .. (restart and "restart" or "stop"), function()
			app.set_session("animation", "Animation")
			app.set_session_status("animation", { type = "busy" })
			chat.do_render()
			assert.is_not_nil(state.spinner_anim_timer)
			local old = callbacks[1]
			messages.stop_spinner_animation_timer()
			if restart then chat.do_render() end
			local timer = state.spinner_anim_timer
			local before = vim.api.nvim_buf_get_lines(surface.bufnr, 0, -1, false)
			now = 120
			old()
			assert.same(before, vim.api.nvim_buf_get_lines(surface.bufnr, 0, -1, false))
			assert.equals(timer, state.spinner_anim_timer)
			if restart then
				callbacks[2]()
				assert.is_not.equals(before[state.spinner_footer_line + 1],
					vim.api.nvim_buf_get_lines(surface.bufnr, state.spinner_footer_line, state.spinner_footer_line + 1, false)[1])
			end
		end)
	end
end)
