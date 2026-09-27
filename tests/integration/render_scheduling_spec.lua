local surface_helper = require("tests.helpers.chat_surface")
local equivalence = require("tests.helpers.render_equivalence")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local app_state = require("opencode.state")
local sync = require("opencode.sync")
local events = require("opencode.events")
local coordinator = require("opencode.ui.chat.render_coordinator")
local project = require("opencode.protocol.v2.messages").project

describe("transcript render scheduling", function()
	local surface, scheduled, timers, saved, renders, winbars, last_rendered, extra_buffers, extra_windows

	local function seed(id, text, content)
		sync.handle_session_messages(id, { project(id, {
			id = id .. "-message", type = "assistant", time = { created = 1, completed = 2 },
			content = content or { { type = "text", text = text } },
		}) })
	end

	local function flush_scheduled()
		local iterations = 0
		while #scheduled > 0 do
			iterations = iterations + 1
			assert.is_true(iterations < 100, "schedule queue did not settle")
			table.remove(scheduled, 1)()
		end
	end

	local function settle()
		flush_scheduled()
		local iterations = 0
		while #timers > 0 do
			iterations = iterations + 1
			assert.is_true(iterations < 100, "timer queue did not settle")
			local next_timer = table.remove(timers, 1)
			assert.is_true(next_timer.delay <= 16, "render throttle increased")
			next_timer.callback()
			flush_scheduled()
		end
	end

	local function request(id, extra)
		events.emit("sync_changed", vim.tbl_extend("force", {
			kind = "message", action = "updated", session_id = id,
		}, extra or {}))
	end

	local function text()
		return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
	end

	local function hide()
		local buffer = vim.api.nvim_create_buf(false, true)
		extra_buffers[#extra_buffers + 1] = buffer
		vim.api.nvim_win_set_buf(surface.winid, buffer)
		state.visible, state.winid, state.tabpage = false, nil, nil
		return buffer
	end

	local function assert_cold_equal()
		local live = equivalence.snapshot({ rendered = last_rendered })
		assert.same(live, equivalence.cold_snapshot())
	end

	before_each(function()
		events.clear()
		surface = surface_helper.setup()
		extra_buffers, extra_windows = {}, {}
		app_state.set_session("current", "Current")
		seed("current", "Initial **current** text")
		seed("foreign", "Foreign text")
		coordinator.setup(events)
		chat.create()
		state.auto_scroll = false
		scheduled, timers = {}, {}
		saved = { schedule = vim.schedule, defer = vim.defer_fn, now = vim.uv.now,
			render = chat.render, winbar = chat.update_winbar }
		vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
		vim.defer_fn = function(callback, delay)
			timers[#timers + 1] = { callback = callback, delay = delay }
			return { stop = function() end, close = function() end }
		end
		vim.uv.now = function() return 100 end
		state.last_render_time = 100
		renders, winbars = 0, 0
		chat.render = function(...)
			renders = renders + 1
			local raw, nui, highlights = saved.render(...)
			last_rendered = equivalence.rendered(raw, nui, highlights)
			return raw, nui, highlights
		end
		chat.update_winbar = function(...)
			winbars = winbars + 1
			return saved.winbar(...)
		end
	end)

	after_each(function()
		settle()
		require("opencode.ui.chat.execute_details").close(false)
		require("opencode.ui.chat.tasks").stop_task_animation_timer()
		chat.render, chat.update_winbar = saved.render, saved.winbar
		vim.schedule, vim.defer_fn, vim.uv.now = saved.schedule, saved.defer, saved.now
		events.clear()
		for _, window in ipairs(extra_windows) do
			if vim.api.nvim_win_is_valid(window) then vim.api.nvim_win_close(window, true) end
		end
		surface_helper.restore(surface)
		for _, buffer in ipairs(extra_buffers) do
			if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
		end
	end)

	it("keeps foreign snapshot events while doing no transcript work", function()
		local emitted, before = 0, equivalence.snapshot()
		events.on("chat_render", function() emitted = emitted + 1 end)
		request("foreign")
		settle()
		assert.equals(1, emitted)
		assert.equals(0, renders)
		assert.is_true(winbars > 0)
		assert.same(before, equivalence.snapshot())
	end)

	it("retains every scope and force in either same-tick order", function()
		local packet
		events.on("chat_render", function(data) packet = data end)
		for _, order in ipairs({ { "foreign", "current" }, { "current", "foreign" } }) do
			local before = renders
			seed("current", "Updated **" .. order[1] .. "**")
			request(order[1], { force = true })
			request(order[2], { force = false })
			settle()
			assert.equals(before + 1, renders)
			assert.is_true(packet.force)
			assert.same({ current = true, foreign = true }, packet._render_sessions)
			assert_cold_equal()
		end
	end)

	it("merges scopes across the existing throttle and retains unscoped invalidations", function()
		seed("current", "Changed across throttle")
		chat.schedule_render({ sessionID = "foreign", force = true })
		chat.schedule_render({ sessionId = "current", force = false })
		assert.equals(1, #timers)
		assert.equals(16, timers[1].delay)
		settle()
		assert.equals(1, renders)
		assert.is_truthy(text():find("Changed across throttle", 1, true))
		chat.schedule_render({ session_id = "foreign" })
		chat.schedule_render({ reason = "theme" })
		settle()
		assert.equals(2, renders)
		chat.schedule_render({ reason = "global before scoped" })
		chat.schedule_render({ session_id = "foreign" })
		settle()
		assert.equals(3, renders)
		assert_cold_equal()
	end)

	it("checks the selected session again when the delayed callback executes", function()
		request("current")
		flush_scheduled()
		app_state.set_session("foreign", "Foreign")
		settle()
		assert.equals(0, renders)
		app_state.set_session("current", "Current")
		request("foreign")
		flush_scheduled()
		app_state.set_session("foreign", "Foreign")
		settle()
		assert.equals(1, renders)
		assert.is_truthy(text():find("Foreign text", 1, true))
		assert_cold_equal()
	end)

	it("marks a closed transcript dirty and refreshes before an external display", function()
		hide()
		seed("current", "Hidden update")
		request("current")
		settle()
		assert.equals(0, renders)
		assert.is_true(state.transcript_dirty)
		assert.is_nil(text():find("Hidden update", 1, true))
		vim.api.nvim_win_set_buf(surface.winid, state.bufnr)
		assert.equals(1, renders)
		assert.is_false(state.transcript_dirty)
		assert.is_truthy(text():find("Hidden update", 1, true))
	end)

	it("keeps explicit synchronous hidden renders and retires their stale timer", function()
		request("current")
		flush_scheduled()
		hide()
		seed("current", "Synchronous update")
		chat.do_render()
		assert.equals(1, renders)
		assert.is_truthy(text():find("Synchronous update", 1, true))
		settle()
		assert.equals(1, renders)
		assert.is_false(state.transcript_dirty)
	end)

	it("rechecks visibility after scheduling and restores the complete dirty buffer", function()
		seed("current", "Closed before callback")
		request("current")
		flush_scheduled()
		hide()
		settle()
		assert.equals(0, renders)
		assert.is_true(state.transcript_dirty)
		vim.api.nvim_win_set_buf(surface.winid, state.bufnr)
		assert.equals(1, renders)
		assert_cold_equal()
	end)

	it("updates a transcript displayed in another window even when the chat is closed", function()
		vim.cmd("vsplit")
		local external = vim.api.nvim_get_current_win()
		extra_windows[#extra_windows + 1] = external
		local hidden = hide()
		assert.equals(state.bufnr, vim.api.nvim_win_get_buf(external))
		seed("current", "Externally displayed update")
		request("current")
		settle()
		assert.equals(1, renders)
		assert.is_false(state.transcript_dirty)
		assert.equals(hidden, vim.api.nvim_win_get_buf(surface.winid))
		assert.is_truthy(text():find("Externally displayed update", 1, true))
		assert_cold_equal()
	end)

	it("refreshes tabs for a filtered foreign status without rebuilding the transcript", function()
		app_state.set_session("foreign", "Foreign")
		app_state.set_session("current", "Current")
		chat.update_winbar()
		local previous = vim.wo[surface.winid].winbar
		app_state.set_session_status("foreign", { type = "busy" })
		events.emit("session_status_change", { session_id = "foreign", status = { type = "busy" } })
		events.emit("sessions_changed", { session_id = "foreign", status_origin = true })
		settle()
		assert.equals(0, renders)
		assert.is_true(winbars > 1)
		assert.is_not.equals(previous, vim.wo[surface.winid].winbar)
	end)

	it("refreshes an external transcript after config, theme and its own resize", function()
		vim.cmd("vsplit")
		local external = vim.api.nvim_get_current_win()
		extra_windows[#extra_windows + 1] = external
		hide()
		events.emit("config_change", {})
		settle()
		assert.equals(1, renders)
		chat.handle_colorscheme()
		settle()
		assert.equals(2, renders)
		vim.api.nvim_exec_autocmds("WinResized", { data = { windows = { surface.winid } } })
		settle()
		assert.equals(2, renders)
		vim.api.nvim_exec_autocmds("WinResized", { data = { windows = { external } } })
		settle()
		assert.equals(3, renders)
		assert_cold_equal()
	end)

	it("defers hidden stream work and uses the complete latest text on redisplay", function()
		sync.handle_message_updated({ id = "stream-message", sessionID = "current", role = "assistant", time = { created = 3 } })
		sync.handle_part_updated({ id = "stream-part", messageID = "stream-message", sessionID = "current",
			type = "text", text = "Stream start" })
		chat.do_render()
		local before = renders
		hide()
		sync.handle_part_updated({ id = "stream-part", messageID = "stream-message", sessionID = "current",
			type = "text", text = "Stream start plus hidden **delta**" })
		request("current", { kind = "part", action = "updated", message_id = "stream-message", part_id = "stream-part",
			field = "text", delta = " plus hidden **delta**" })
		settle()
		assert.equals(before, renders)
		assert.is_true(state.transcript_dirty)
		assert.is_nil(text():find("hidden", 1, true))
		vim.api.nvim_win_set_buf(surface.winid, state.bufnr)
		assert.equals(before + 1, renders)
		assert.is_truthy(text():find("Stream start plus hidden delta", 1, true))
		assert_cold_equal()
	end)

	it("keeps detail content and cursor stable and refreshes the transcript on return", function()
		local details = require("opencode.ui.chat.execute_details")
		local part = { type = "tool", tool = "execute", state = { status = "completed", output = "one\ntwo\nthree" } }
		details.open(part)
		local detail_buf = vim.api.nvim_win_get_buf(surface.winid)
		vim.api.nvim_win_set_cursor(surface.winid, { 2, 0 })
		local previous = vim.api.nvim_buf_get_lines(detail_buf, 0, -1, false)
		local bar = vim.wo[surface.winid].winbar
		seed("current", "Changed while inspecting")
		request("current")
		settle()
		assert.equals(0, renders)
		assert.is_true(state.transcript_dirty)
		assert.same(previous, vim.api.nvim_buf_get_lines(detail_buf, 0, -1, false))
		assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(surface.winid))
		assert.equals(bar, vim.wo[surface.winid].winbar)
		details.close()
		assert.equals(1, renders)
		assert.equals(state.bufnr, vim.api.nvim_win_get_buf(surface.winid))
		assert.is_truthy(text():find("Changed while inspecting", 1, true))
	end)

	it("refreshes displayed child task activity without rendering an unrelated child", function()
		local child_tool = { type = "tool", id = "read", name = "read", state = {
			status = "completed", input = { path = "before.lua" }, content = { { type = "text", text = "body" } },
		}, time = { created = 1, completed = 2 } }
		seed("child", "", { child_tool })
		seed("current", "", { { type = "tool", id = "task", name = "task", state = {
			status = "running", input = { description = "Inspect", subagent_type = "explore" },
			metadata = { sessionID = "child" },
		}, time = { created = 1 } } })
		chat.do_render()
		local before = renders
		child_tool.state.input.path = "after.lua"
		seed("child", "", { child_tool })
		request("child")
		settle()
		assert.equals(before + 1, renders)
		assert.is_truthy(text():find("after.lua", 1, true))
		request("unrelated-child")
		settle()
		assert.equals(before + 1, renders)
		assert_cold_equal()
	end)
end)
