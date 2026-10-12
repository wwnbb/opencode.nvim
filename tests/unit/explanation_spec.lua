local state = require("opencode.state")
local defaults = require("opencode.config")

describe("selection explanation request lifecycle", function()
	local controller, config, source, previous_buf, previous_config, previous_connection
	local saved, requests, views, errors, shown, notices, snapshot
	local modules = {
		"opencode.explanation", "opencode.ui.explanation", "opencode.util.visual_selection",
		"opencode.lifecycle", "opencode.client",
	}

	local function source_snapshot()
		return {
			bufnr = source,
			changedtick = vim.api.nvim_buf_get_changedtick(source),
			path = vim.api.nvim_buf_get_name(source),
			root = "/tmp/opencode-explanation-controller",
			filetype = "lua",
			mode = "V",
			start_line = 1,
			end_line = 2,
			lines = { "local value = 1", "return value" },
			text = "local value = 1\nreturn value",
		}
	end

	local function close_view(view)
		if not view or not view.open then return end
		view.open = false
		if view.on_close then view.on_close() end
	end

	before_each(function()
		saved = {}
		for _, name in ipairs(modules) do
			saved[name], package.loaded[name] = package.loaded[name], nil
		end
		previous_buf, previous_config, previous_connection =
			vim.api.nvim_get_current_buf(), state.get_config(), state.get_connection()
		source = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(source, "/tmp/opencode-explanation-controller/main.lua")
		vim.bo[source].filetype = "lua"
		vim.api.nvim_buf_set_lines(source, 0, -1, false, { "local value = 1", "return value", "after()" })
		vim.api.nvim_set_current_buf(source)
		vim.bo[source].modified = false
		snapshot = source_snapshot()
		config = defaults.merge({ explanation = {
			enabled = true, timeout_ms = 60000, model = { providerID = "test", modelID = "explain" },
		} })
		state.set_config(config)
		state.set_connection("connected")
		requests, views, errors, shown, notices = {}, {}, {}, {}, {}
		saved.notify, saved.wrap = vim.notify, vim.schedule_wrap
		vim.notify = function(message) notices[#notices + 1] = message end
		package.loaded["opencode.util.visual_selection"] = {
			capture = function() return vim.deepcopy(snapshot) end,
		}
		package.loaded["opencode.ui.explanation"] = {
			setup = function() end,
			teardown = function() close_view(views[#views]) end,
			open = function(request, callback)
				local view = { snapshot = request, on_close = callback, open = true }
				views[#views + 1] = view
				return view
			end,
			close = function() close_view(views[#views]) end,
			is_open = function() return views[#views] ~= nil and views[#views].open end,
			show = function(text)
				shown[#shown + 1] = text
				return true
			end,
			error = function(message) errors[#errors + 1] = message; return true end,
		}
		package.loaded["opencode.lifecycle"] = {
			ensure_connected = function(callback)
				callback()
				return true
			end,
			resolve_explanation_model = function()
				return { providerID = "test", id = "explain" }
			end,
		}
		package.loaded["opencode.client"] = {
			generate_explanation = function(prompt, model, callback, opts)
				local request = { prompt = prompt, model = model, callback = callback, opts = opts }
				requests[#requests + 1] = request
				return { cancel = function() request.cancelled = true end }
			end,
		}
		controller = require("opencode.explanation")
		controller.setup(config.explanation)
	end)

	after_each(function()
		controller.teardown()
		if saved.new_timer then vim.uv.new_timer, vim.uv.now = saved.new_timer, saved.now end
		vim.notify, vim.schedule_wrap = saved.notify, saved.wrap
		for _, name in ipairs(modules) do package.loaded[name] = saved[name] end
		state.set_config(previous_config)
		state.set_connection(previous_connection)
		if vim.api.nvim_buf_is_valid(previous_buf) then vim.api.nvim_set_current_buf(previous_buf) end
		if vim.api.nvim_buf_is_valid(source) then vim.api.nvim_buf_delete(source, { force = true }) end
	end)

	it("opens a pending popup and shows the full answer without changing source", function()
		local tick = vim.api.nvim_buf_get_changedtick(source)
		assert.is_true(controller.explain_selection())
		assert.equals(1, #views)
		assert.is_true(views[1].open)
		assert.equals(1, #requests)
		assert.same({ providerID = "test", id = "explain" }, requests[1].model)
		assert.is_true(requests[1].opts.timeout > 0)
		assert.is_truthy(requests[1].prompt:find("local value = 1", 1, true))
		assert.same({}, shown)
		local answers = {
			"L1–2 — Defines and returns a value.\n\nNo side effects.",
			"L1 — Defines a value.",
			"This selection defines and returns a value.",
			"L1–3 — Explains the whole function.",
		}
		for index, answer in ipairs(answers) do
			if index > 1 then assert.is_true(controller.explain_selection()) end
			requests[index].callback(nil, answer)
			assert.equals(answer, shown[index])
			assert.is_true(views[index].open)
		end
		assert.same(answers, shown)
		assert.same({}, errors)
		assert.same({ "local value = 1", "return value", "after()" },
			vim.api.nvim_buf_get_lines(source, 0, -1, false))
		assert.equals(tick, vim.api.nvim_buf_get_changedtick(source))
		assert.is_false(vim.bo[source].modified)
	end)

	it("keeps the default request pending without a deadline until dismissal", function()
		config.explanation.timeout_ms = defaults.merge().explanation.timeout_ms
		assert.equals(0, config.explanation.timeout_ms)
		controller.setup(config.explanation)
		local now, timer_calls = 0, 0
		saved.new_timer, saved.now = vim.uv.new_timer, vim.uv.now
		vim.uv.now = function() return now end
		vim.uv.new_timer = function()
			timer_calls = timer_calls + 1
			return { start = function() end, stop = function() end, close = function() end }
		end
		assert.is_true(controller.explain_selection())
		assert.equals(0, requests[1].opts.timeout)
		assert.equals(0, timer_calls)
		now = 60001
		assert.equals("pending", views[1].snapshot.phase)
		assert.is_true(views[1].open)
		assert.is_nil(requests[1].cancelled)
		assert.same({}, errors)
		assert.is_true(controller.dismiss())
		assert.is_true(requests[1].cancelled)
		requests[1].callback(nil, "late")
		assert.same({}, shown)
	end)

	it("streams only the answer and ignores updates after completion or dismissal", function()
		assert.is_true(controller.explain_selection())
		local request = requests[1]
		assert.equals(snapshot.root, request.opts.directory)
		request.opts.on_update("Preparing the answer.\n<ans")
		assert.same({}, shown)
		request.opts.on_update("Preparing the answer.\n<answer>\nОпределяет значение")
		assert.same({ "Определяет значение" }, shown)
		assert.equals("pending", views[1].snapshot.phase)
		request.callback(nil, "<answer>\nОпределяет значение.\n</answer>")
		request.opts.on_update("late update")
		assert.same({ "Определяет значение", "Определяет значение." }, shown)
		assert.equals("ready", views[1].snapshot.phase)
		controller.explain_selection()
		close_view(views[2])
		requests[2].opts.on_update("<answer>\nlate update")
		assert.same({ "Определяет значение", "Определяет значение." }, shown)
	end)

	it("keeps a completed answer when its cancelled deadline callback runs", function()
		local queued
		vim.schedule_wrap = function(callback) queued = callback; return function() end end
		assert.is_true(controller.explain_selection())
		requests[1].callback(nil, "Defines a value.")
		queued()
		assert.same({ "Defines a value." }, shown)
		assert.same({}, errors)
		assert.is_true(views[1].open)
	end)

	it("cancels on popup close and ignores late answers", function()
		assert.is_true(controller.explain_selection())
		local request, view = requests[#requests], views[#views]
		close_view(view)
		assert.is_true(request.cancelled)
		request.opts.on_update("<answer>\nL1–2 — stale")
		request.callback(nil, "L1–2 — stale")
		assert.same({}, shown)
		assert.same({}, errors)
		assert.is_true(controller.explain_selection())
	end)

	it("dismisses a request cancelled by the client and ignores later updates", function()
		config.explanation.timeout_ms = 0
		controller.setup(config.explanation)
		assert.is_true(controller.explain_selection())
		local request = requests[1]
		request.callback({ cancelled = true, message = "Request cancelled" })
		assert.is_false(views[1].open)
		assert.is_false(controller.dismiss())
		request.opts.on_update("<answer>\nlate update")
		request.callback(nil, "late answer")
		assert.same({}, shown)
		assert.same({}, errors)
	end)

	it("keeps a replacement request when the old request replies late", function()
		assert.is_true(controller.explain_selection())
		local first = requests[1]
		assert.is_true(controller.explain_selection())
		assert.is_true(first.cancelled)
		first.opts.on_update("<answer>\nold update")
		first.callback(nil, "old answer")
		assert.same({}, shown)
		assert.is_true(views[2].open)
		requests[2].callback(nil, "new answer")
		assert.same({ "new answer" }, shown)
		assert.same({}, errors)
	end)

	it("does not retain a handle after a synchronous response completes", function()
		local generate = package.loaded["opencode.client"].generate_explanation
		package.loaded["opencode.client"].generate_explanation = function(prompt, model, callback, opts)
			local handle = generate(prompt, model, callback, opts)
			callback(nil, "Immediate answer")
			return handle
		end
		assert.is_true(controller.explain_selection())
		assert.same({ "Immediate answer" }, shown)
		assert.equals("ready", views[1].snapshot.phase)
		assert.is_true(controller.dismiss())
		assert.is_nil(requests[1].cancelled)
	end)

	it("ignores a late answer after the source changes and reports the stale selection", function()
		controller.explain_selection()
		vim.api.nvim_buf_set_lines(source, 0, 1, false, { "local value = 2" })
		requests[1].opts.on_update("<answer>\nL1–2 — stale")
		requests[1].callback(nil, "L1–2 — stale")
		assert.is_true(requests[1].cancelled)
		assert.same({}, shown)
		assert.is_truthy(errors[1]:find("Source buffer changed", 1, true))
		assert.is_true(views[1].open)
	end)

	it("times out, closes the request, and keeps a late response out of the popup", function()
		config.explanation.timeout_ms = 10
		controller.setup(config.explanation)
		assert.is_true(controller.explain_selection())
		assert.is_true(vim.wait(500, function() return #errors > 0 end, 5))
		assert.matches("timed out", errors[1])
		assert.is_true(requests[1].cancelled)
		requests[1].callback(nil, "L1–2 — too late")
		assert.same({}, shown)
	end)

	it("shows a budget error without sending a request", function()
		config.explanation.context.max_bytes = 1024
		snapshot.lines = { string.rep("é", 700) }
		snapshot.start_line, snapshot.end_line = 1, 1
		snapshot.text = snapshot.lines[1]
		controller.setup(config.explanation)
		assert.is_true(controller.explain_selection())
		assert.equals(1, #views)
		assert.same({}, requests)
		assert.is_truthy(errors[1]:find("full selection exceeds", 1, true))
		assert.is_true(views[1].open)
	end)
end)
