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
			winid = vim.api.nvim_get_current_win(),
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
			enabled = true, model = { providerID = "test", modelID = "explain" },
		} })
		state.set_config(config)
		state.set_connection("connected")
		requests, views, errors, shown, notices = {}, {}, {}, {}, {}
		saved.notify = vim.notify
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
		vim.notify = saved.notify
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
		local answer = "L1–2 — Defines and returns a value.\n\nNo side effects."
		requests[1].callback(nil, answer)
		assert.same({ answer }, shown)
		assert.same({}, errors)
		assert.same({ "local value = 1", "return value", "after()" },
			vim.api.nvim_buf_get_lines(source, 0, -1, false))
		assert.equals(tick, vim.api.nvim_buf_get_changedtick(source))
		assert.is_false(vim.bo[source].modified)
	end)

	it("cancels on popup q and Esc and ignores late answers", function()
		for _, key in ipairs({ "q", "Esc" }) do
			assert.is_true(controller.explain_selection())
			local request, view = requests[#requests], views[#views]
			-- The UI sends the same on_close callback for either key.
			close_view(view)
			assert.is_true(request.cancelled, key)
			request.callback(nil, "L1–2 — stale")
			assert.same({}, shown)
			assert.same({}, errors)
		end
	end)

	it("ignores a late answer after the source changes and reports the stale selection", function()
		controller.explain_selection()
		vim.api.nvim_buf_set_lines(source, 0, 1, false, { "local value = 2" })
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

	it("shows an answer with incomplete line ranges without changing the source", function()
		controller.explain_selection()
		local answer = "L1 — Defines a value."
		requests[1].callback(nil, answer)
		assert.same({ answer }, shown)
		assert.same({}, errors)
		assert.is_true(views[1].open)
		assert.same({ "local value = 1", "return value", "after()" },
			vim.api.nvim_buf_get_lines(source, 0, -1, false))
	end)

	it("shows arbitrary prose and out-of-range headings without validating them", function()
		controller.explain_selection()
		local prose = "This selection defines and returns a value."
		requests[1].callback(nil, prose)
		assert.same({ prose }, shown)
		assert.same({}, errors)
		controller.explain_selection()
		local broad = "L1–3 — Explains the whole function."
		requests[2].callback(nil, broad)
		assert.same({ prose, broad }, shown)
		assert.same({}, errors)
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
