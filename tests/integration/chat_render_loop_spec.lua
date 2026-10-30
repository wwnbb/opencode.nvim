local surface_helper = require("tests.helpers.chat_surface")
local equivalence = require("tests.helpers.render_equivalence")
local cs = require("opencode.ui.chat.state")
local chat = require("opencode.ui.chat").for_view(cs.state)
local render_state = require("opencode.ui.chat.render_state")
local state = cs.state
local app_state = require("opencode.state")
local sync = require("opencode.sync")
local events = require("opencode.events")

describe("chat render loop", function()
	local surface

	local function message(id, created)
		sync.handle_message_updated({ id = id, sessionID = "loop", role = "assistant",
			time = { created = created, completed = created + 1 } })
	end

	local function part(id, message_id, text)
		sync.handle_part_updated({ id = id, messageID = message_id, sessionID = "loop", type = "text", text = text })
	end

	local function marks_from(row)
		local result = {}
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.bufnr, cs.chat_hl_ns, { row, 0 }, -1, { details = true })) do
			result[#result + 1] = { id = mark[1], row = mark[2], col = mark[3], hl = mark[4].hl_group }
		end
		return result
	end

	local function find_line(pattern)
		for index, line in ipairs(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)) do
			if line:find(pattern, 1, true) then return index - 1 end
		end
	end

	local function assert_cold_equal()
		local live = equivalence.snapshot()
		local cold = equivalence.cold_snapshot()
		cold.rendered, live.rendered = nil, nil
		assert.same(cold, live)
	end

	before_each(function()
		events.clear()
		surface = surface_helper.setup()
		app_state.set_session("loop", "Loop")
		message("m1", 1)
		part("p1", "m1", "First **bold** line")
		message("m2", 10)
		part("p2", "m2", "Tail text with `code`\n\n```lua\nlocal tail = 1\nreturn tail\n```\n\nEnd *here*")
		chat.create()
		chat.do_render()
	end)

	after_each(function()
		events.clear()
		surface_helper.restore(surface)
	end)

	it("replaces only the changed middle and keeps the tail's extmarks", function()
		local tail_row = find_line("Tail text")
		local before = marks_from(tail_row)
		assert.is_true(#before > 0, "the tail should carry highlights")
		part("p1", "m1", "First **bold** line\n\nadded *one*\n\nadded two")
		chat.do_render()
		local shift = find_line("Tail text") - tail_row
		assert.is_true(shift > 0)
		local after = marks_from(tail_row + shift)
		assert.equals(#before, #after)
		for index, mark in ipairs(before) do
			assert.same({ id = mark.id, row = mark.row + shift, col = mark.col, hl = mark.hl }, after[index])
		end
		assert_cold_equal()
	end)

	it("matches a cold render after the tail's highlights change with its text", function()
		part("p1", "m1", "First line without bold")
		chat.do_render()
		assert_cold_equal()
		part("p2", "m2", "Tail text with `code`\n\n```lua\nlocal tail = 2\n```")
		chat.do_render()
		assert_cold_equal()
		part("p1", "m1", "```lua\nlocal head = 1\n```")
		part("p2", "m2", "Tail text")
		chat.do_render()
		assert_cold_equal()
	end)

	it("falls back to a full tail refresh after an in-place buffer change", function()
		render_state.invalidate_render_highlights(0)
		part("p1", "m1", "First **bold** line\nwith more")
		chat.do_render()
		assert_cold_equal()
	end)

	it("moves the cursor with the text below a change when auto-scroll is off", function()
		state.auto_scroll = false
		local row = find_line("End here")
		vim.api.nvim_win_set_cursor(surface.winid, { row + 1, 2 })
		part("p1", "m1", "First **bold** line\n\nadded\n\nlines")
		chat.do_render()
		local cursor = vim.api.nvim_win_get_cursor(surface.winid)
		assert.is_true(cursor[1] > row + 1)
		assert.equals("End here", vim.api.nvim_buf_get_lines(state.bufnr, cursor[1] - 1, cursor[1], false)[1]:match("End here"))
	end)
end)

describe("chat render throttle", function()
	local surface, saved, clock, elapsed, timers, renders, winbars

	before_each(function()
		events.clear()
		surface = surface_helper.setup()
		app_state.set_session("loop", "Loop")
		chat.create()
		saved = { defer = vim.defer_fn, now = vim.uv.now, hrtime = vim.uv.hrtime,
			render = chat.render, winbar = chat.update_winbar }
		clock, elapsed, timers, renders, winbars = 1000, 0, {}, 0, 0
		-- Loop time stays fixed during a render; only the measured cost advances.
		vim.uv.now = function() return clock end
		vim.uv.hrtime = function() return elapsed * 1e6 end
		vim.defer_fn = function(callback, delay)
			timers[#timers + 1] = { callback = callback, delay = delay }
			return { stop = function() end, close = function() end }
		end
		chat.render = function(...)
			renders = renders + 1
			elapsed = elapsed + 40
			return saved.render(...)
		end
		chat.update_winbar = function(...)
			winbars = winbars + 1
			return saved.winbar(...)
		end
		state.last_render_time, state.last_render_duration, state.render_durations = 0, 0, {}
	end)

	after_each(function()
		vim.defer_fn, vim.uv.now, vim.uv.hrtime = saved.defer, saved.now, saved.hrtime
		chat.render, chat.update_winbar = saved.render, saved.winbar
		events.clear()
		surface_helper.restore(surface)
	end)

	it("measures from the end of a slow render and spaces the next one by twice its cost", function()
		chat.schedule_render({ force = true })
		assert.equals(1, renders)
		assert.equals(1040, state.last_render_time)
		assert.equals(40, state.last_render_duration)
		clock = 1040
		chat.schedule_render({})
		chat.schedule_render({})
		assert.equals(1, renders)
		assert.equals(1, #timers)
		assert.equals(80, timers[1].delay)
		clock = clock + 80
		timers[1].callback()
		assert.equals(2, renders)
	end)

	it("caps the adaptive delay", function()
		state.last_render_time, state.render_durations = clock, { 5000, 5000, 5000 }
		chat.schedule_render({})
		assert.equals(200, timers[1].delay)
	end)

	it("paces by the median cost, so one slow frame does not throttle the next", function()
		state.last_render_time, state.render_durations = clock, { 5, 5, 150 }
		chat.schedule_render({})
		assert.equals(16, timers[1].delay)
		state.render_scheduled, timers = false, {}
		state.render_durations = { 5, 150, 150 }
		chat.schedule_render({})
		assert.equals(200, timers[1].delay)
	end)

	it("renders a user's own action at once and folds a throttled frame into it", function()
		state.last_render_time, state.render_durations = clock, { 100, 100, 100 }
		chat.schedule_render({})
		assert.equals(1, #timers)
		assert.equals(0, renders)
		chat.schedule_render({ immediate = true })
		assert.equals(1, renders)
		assert.is_false(state.render_scheduled)
		timers[1].callback()
		assert.equals(1, renders)
	end)

	it("drops a pending throttled render when the view is disposed", function()
		chat.schedule_render({ force = true })
		chat.schedule_render({})
		assert.equals(1, #timers)
		local before_renders, before_winbars = renders, winbars
		chat.dispose()
		timers[1].callback()
		assert.equals(before_renders, renders)
		assert.equals(before_winbars, winbars)
		assert.is_false(state.render_scheduled)
	end)
end)

describe("chat close and reopen", function()
	it("keeps render, code and shared memo caches", function()
		local memo = require("opencode.util.memo")
		local render = require("opencode.ui.chat.render")
		local projection = require("opencode.protocol.messages")
		local original_config = app_state.get_config()
		local config = vim.deepcopy(require("opencode.config").defaults)
		config.server.auto_start, config.lualine.enabled = false, false
		config.chat.layout, config.chat.close_on_focus_lost = "vertical", false
		app_state.set_config(config)
		local original_render_content = render.render_content
		local ok, err = xpcall(function()
			sync.clear_all()
			app_state.set_session("reopen", "Reopen")
			sync.handle_session_messages("reopen", { projection.project("reopen", {
				id = "reopen-message", type = "assistant", time = { created = 1, completed = 2 },
				content = { { type = "text", text = "Some **text**\n\n```lua\nreturn 1\n```" } },
			}) })
			chat.open()
			chat.do_render()
			local probe = memo.new("render_loop_probe", { max_entries = 2 })
			probe:put("owner", 1, { "kept" })
			local entries = render_state.render_cache_stats().entries
			local code_entries = render_state.code_cache_stats().entries
			assert.is_true(entries > 0)
			chat.close()
			assert.equals(entries, render_state.render_cache_stats().entries)
			assert.equals(code_entries, render_state.code_cache_stats().entries)
			local builds = 0
			render.render_content = function(...)
				builds = builds + 1
				return original_render_content(...)
			end
			chat.open()
			assert.equals(0, builds)
			assert.is_not_nil(probe:get("owner", 1))
			assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n"):find("Some text", 1, true))
		end, debug.traceback)
		render.render_content = original_render_content
		memo.remove("render_loop_probe")
		pcall(chat.close)
		sync.clear_all()
		app_state.reset()
		app_state.set_config(original_config)
		assert.is_true(ok, err)
	end)
end)
