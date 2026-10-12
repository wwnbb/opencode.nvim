describe("inline completion request lifecycle", function()
	local controller, saved, mode, requests, notices, shown, pending, config, old_buf, buf, old_virtualedit
	local state = require("opencode.state")
	local modules = { "opencode.completion", "opencode.ui.completion", "opencode.lifecycle", "opencode.client" }
	local function edit(text, col)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
		vim.api.nvim_win_set_cursor(0, { 1, col or #text })
	end
	local function clock()
		local now, timers = 0, {}
		saved.new_timer, saved.now = vim.uv.new_timer, vim.uv.now
		vim.schedule_wrap = function(callback) return callback end
		vim.uv.now = function() return now end
		vim.uv.new_timer = function()
			local timer = {}
			function timer:start(delay, _, callback) self.due, self.callback = now + delay, callback end
			function timer:stop() self.stopped = true end
			function timer:close() self.closed = true end
			timers[#timers + 1] = timer
			return timer
		end
		local function advance(delay)
			now = now + delay
			for _, timer in ipairs(timers) do
				if not timer.stopped and not timer.closed and timer.due <= now then
					timer.stopped = true; timer.callback()
				end
			end
		end
		return advance, timers
	end
	before_each(function()
		saved = {}
		for _, name in ipairs(modules) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		old_buf, old_virtualedit = vim.api.nvim_get_current_buf(), vim.o.virtualedit
		vim.o.virtualedit = "onemore"
		buf = vim.api.nvim_create_buf(true, false); vim.api.nvim_set_current_buf(buf)
		edit("local x = ")
		mode, requests, notices, shown, pending = "i", {}, {}, {}, {}
		saved.mode, saved.notify, saved.wrap = vim.api.nvim_get_mode, vim.notify, vim.schedule_wrap
		vim.api.nvim_get_mode = function() return { mode = mode } end
		vim.notify = function(message) notices[#notices + 1] = message end
		config = require("opencode.config").merge({ completion = { enabled = true, timeout_ms = 15000, model = { providerID = "test", modelID = "fast" } } })
		state.set_config(config); state.set_connection("connected")
		package.loaded["opencode.ui.completion"] = {
			setup = function() end, teardown = function() end, clear = function() end,
			pending = function(snap) pending[#pending + 1] = snap end,
			show = function(snap, text) shown[#shown + 1] = { snap, text }; return true end,
		}
		package.loaded["opencode.lifecycle"] = {
			ensure_connected = function(callback) callback(); return true end,
			resolve_completion_model = function() return { providerID = "test", id = "fast" } end,
		}
		package.loaded["opencode.client"] = {
			generate_completion = function(prompt, model, callback, opts)
				local record = { prompt = prompt, model = model, callback = callback, opts = opts }
				requests[#requests + 1] = record
				return { cancel = function() record.cancelled = true end }
			end,
		}
		controller = require("opencode.completion"); controller.setup(config.completion)
	end)
	after_each(function()
		controller.teardown()
		if saved.new_timer then vim.uv.new_timer, vim.uv.now = saved.new_timer, saved.now end
		vim.api.nvim_get_mode, vim.notify, vim.schedule_wrap = saved.mode, saved.notify, saved.wrap
		for _, name in ipairs(modules) do package.loaded[name] = saved[name] end
		vim.api.nvim_set_current_buf(old_buf); vim.api.nvim_buf_delete(buf, { force = true })
		vim.o.virtualedit = old_virtualedit
	end)
	it("requests an explicit model without a chat and handles a final response", function()
		assert.is_true(controller.complete()); assert.equals(1, #pending); assert.is_false(controller.visible())
		assert.same({ providerID = "test", id = "fast" }, requests[1].model)
		assert.is_true(requests[1].opts.timeout > 0)
		assert.is_truthy(requests[1].prompt:find("inline completion engine", 1, true))
		requests[1].callback(nil, "42")
		assert.is_true(controller.visible()); assert.equals("42", shown[1][2])
		assert.same({ "local x = " }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end)
	it("keeps a request without a deadline pending until dismissal", function()
		local defaults = require("opencode.config")
		assert.equals(0, defaults.merge().completion.timeout_ms)
		config.completion.timeout_ms = defaults.merge({ completion = { timeout_ms = 0 } }).completion.timeout_ms
		controller.setup(config.completion)
		local advance, timers = clock()
		assert.is_true(controller.complete())
		assert.equals(0, requests[1].opts.timeout)
		assert.equals(0, #timers)
		advance(60000)
		assert.is_nil(requests[1].cancelled)
		assert.same({}, notices)
		assert.is_false(controller.visible())
		assert.is_true(controller.dismiss())
		assert.is_true(requests[1].cancelled)
		requests[1].callback(nil, "late")
		assert.equals(0, #shown)
	end)
	it("replaces streamed previews and ignores updates after replacement, completion, or cancellation", function()
		controller.complete()
		assert.equals(pending[1].root, requests[1].opts.directory)
		requests[1].opts.on_update("4")
		assert.is_true(controller.visible())
		assert.equals("4", shown[#shown][2])
		requests[1].opts.on_update("42")
		assert.equals("42", shown[#shown][2])
		controller.complete()
		assert.is_true(requests[1].cancelled)
		requests[1].opts.on_update("stale")
		assert.equals(2, #shown)
		assert.is_false(controller.visible())
		requests[2].opts.on_update("43")
		requests[2].callback(nil, "44")
		requests[2].opts.on_update("late")
		assert.equals("44", shown[#shown][2])
		assert.equals(4, #shown)
		assert.is_true(controller.visible())
		controller.complete()
		requests[3].opts.on_update("new")
		controller.dismiss()
		requests[3].opts.on_update("dismissed")
		requests[3].callback(nil, "dismissed final")
		assert.equals(5, #shown)
		assert.is_false(controller.visible())
		controller.complete()
		edit("local x = typed")
		requests[4].opts.on_update("changed source")
		assert.is_true(requests[4].cancelled)
		assert.equals(5, #shown)
	end)
	it("hides unusable streamed text, recovers on a valid update, and clears a failed stream", function()
		edit("call()", 5)
		controller.complete()
		for _, invalid in ipairs({ "  ", "first\nsecond", "bad\027text" }) do
			requests[1].opts.on_update('"value"')
			assert.is_true(controller.visible())
			local pending_count = #pending
			requests[1].opts.on_update(invalid)
			assert.is_false(controller.visible())
			assert.equals(pending_count + 1, #pending)
		end
		assert.same({}, notices)
		requests[1].opts.on_update('"recovered"')
		assert.is_true(controller.visible())
		requests[1].callback({ message = "Offline" })
		assert.is_false(controller.visible())
		assert.equals(1, #notices)
		assert.matches("Offline", notices[1])
		local shown_count = #shown
		requests[1].opts.on_update("late")
		requests[1].callback(nil, "late final")
		assert.equals(shown_count, #shown)
		assert.same({ "call()" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end)
	it("keeps a ready proposal when its cancelled deadline callback runs", function()
		local queued
		vim.schedule_wrap = function(callback) queued = callback; return function() end end
		assert.is_true(controller.complete())
		requests[1].callback(nil, "42")
		queued()
		assert.is_true(controller.visible())
		assert.equals("42", shown[1][2])
		assert.same({}, notices)
	end)
	it("withholds streamed fence fragments until the enclosing fence is complete", function()
		controller.complete()
		for _, text in ipairs({ "`", "``", "```", "```lu", "```lua\n", "```lua\n42",
			"```lua\n42\n`", "```lua\n42\n``", "```lua\r\n42\r\n``", "````lua\n42\n```" }) do
			requests[1].opts.on_update(text)
			assert.is_false(controller.visible(), text)
			assert.equals(0, #shown)
		end
		requests[1].opts.on_update("````lua\r\n42\r\n````\r\n")
		assert.is_true(controller.visible())
		assert.equals("42", shown[1][2])
		assert.same({}, notices)
	end)
	it("preserves ambiguous backticks in a final response", function()
		controller.complete()
		local text = "```lua\n42"
		requests[1].opts.on_update(text)
		assert.is_false(controller.visible())
		requests[1].callback(nil, text)
		assert.is_true(controller.visible())
		assert.equals(text, shown[1][2])
	end)
	it("retrigger cancels pending work and requests an alternative to a ready proposal", function()
		controller.complete(); controller.complete()
		assert.is_true(requests[1].cancelled)
		requests[1].callback(nil, "stale"); assert.equals(0, #shown)
		requests[2].callback(nil, "42"); assert.is_true(controller.visible())
		controller.complete(); assert.is_false(controller.visible())
		assert.is_truthy(requests[3].prompt:find('"previous_suggestion":"42"', 1, true))
		requests[3].callback(nil, "43"); assert.equals("43", shown[2][2])
	end)
	it("ignores changed buffers and cursor-only changes before a response", function()
		controller.complete(); edit("local x = 1")
		requests[1].callback(nil, "stale"); assert.equals(0, #shown)
		controller.complete(); vim.api.nvim_win_set_cursor(0, { 1, 0 })
		requests[2].callback(nil, "stale"); assert.equals(0, #shown)
	end)
	it("invalidates ready results on typing and pending work on InsertLeave", function()
		controller.complete(); requests[1].callback(nil, "42")
		edit("local x = a")
		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
		assert.is_false(controller.visible())
		controller.complete()
		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
		assert.is_true(requests[2].cancelled)
		requests[2].callback(nil, "late"); assert.equals(1, #shown)
	end)
	it("keeps queued connection callbacks harmless after cancellation or timeout", function()
		local callback
		package.loaded["opencode.lifecycle"].ensure_connected = function(cb) callback = cb end
		controller.complete(); controller.dismiss(); callback(); assert.equals(0, #requests)
		config.completion.timeout_ms = 15; controller.setup(config.completion)
		controller.complete()
		assert.is_true(vim.wait(250, function() return #notices > 0 end, 5))
		callback(); assert.equals(0, #requests)
		assert.matches("timed out", notices[#notices])
	end)
	it("stops active transport on timeout and reports network failures once", function()
		config.completion.timeout_ms = 15; controller.setup(config.completion)
		controller.complete()
		assert.is_true(vim.wait(250, function() return requests[1].cancelled end, 5))
		requests[1].callback(nil, "late"); assert.equals(0, #shown)
		controller.complete(); requests[2].callback({ message = "Offline" })
		assert.matches("Offline", notices[#notices]); assert.is_false(controller.visible())
	end)

	it("waits for the cold base catalog only after an explicit pre-generation rejection", function()
		local advance = clock()
		controller.complete()
		requests[1].callback({ status = 400, code = "InvalidRequestError", message = "Model unavailable: test/fast" })
		assert.equals(0, #notices)
		advance(100); assert.equals(2, #requests)
		assert.is_true(requests[2].opts.timeout < requests[1].opts.timeout)
		requests[2].callback(nil, "42")
		assert.is_true(controller.visible())
		assert.equals(1, #pending)
		controller.complete()
		requests[3].callback({ status = 500, code = "ProviderError", message = "Model unavailable: test/fast" })
		advance(150)
		assert.equals(3, #requests)
		assert.equals(1, #notices)
	end)

	it("cancels catalog retries on dismiss and honors the overall request deadline", function()
		local advance, timers = clock()
		local failure = { status = 400, code = "InvalidRequestError", message = "Model unavailable: test/fast" }
		controller.complete(); requests[1].callback(failure); controller.dismiss()
		advance(150); timers[2].callback()
		assert.equals(1, #requests)
		config.completion.timeout_ms = 15; controller.setup(config.completion)
		controller.complete(); requests[2].callback(failure)
		advance(15); assert.equals(1, #notices)
		advance(120); timers[4].callback()
		assert.equals(1, #notices)
		assert.equals(2, #requests)
		assert.matches("timed out", notices[#notices])
	end)
	it("does not fall back to the chat model when completion model is missing", function()
		config.completion.model = nil; controller.setup(config.completion)
		assert.is_false(controller.complete()); assert.equals(0, #requests)
		assert.matches("model", notices[#notices]:lower())
	end)

	it("clears immediately when connection startup is refused or preview fails", function()
		state.set_connection("idle")
		package.loaded["opencode.lifecycle"].ensure_connected = function() return false end
		assert.is_false(controller.complete())
		assert.equals(0, #requests)
		state.set_connection("connected")
		package.loaded["opencode.ui.completion"].pending = function() return false end
		assert.is_false(controller.complete())
		assert.equals(0, #requests)
		assert.matches("indicator", notices[#notices])
	end)
	it("handles empty responses and enforces single-line completion before suffix", function()
		edit("call()", 5)
		controller.complete(); requests[1].callback(nil, "\n  a\n")
		assert.equals(0, #shown); assert.matches("line limit", notices[#notices])
		controller.complete(); requests[2].callback(nil, ""); assert.equals(0, #shown)
		controller.complete(); requests[3].callback(nil, '"value"')
		assert.equals('"value"', shown[1][2])
	end)
	it("preserves indentation, strips only an outer fence, rejects control characters", function()
		assert.equals("  foo\n\tbar  ", controller.normalize("```lua\n  foo\n\tbar  \n```\n", 3))
		assert.equals("\n  foo\n", controller.normalize("\n  foo\n", 3))
		assert.equals("Console.WriteLine();", controller.normalize("```c#\nConsole.WriteLine();\n```", 1))
		assert.is_nil(controller.normalize("bad\027text", 3))
		assert.is_nil(controller.normalize("bad\rtext", 1))
		assert.is_nil(controller.normalize(string.rep("x", 16385), 3))
	end)
	it("streams insertions on blank and indented lines without changing source or cursor", function()
		for _, case in ipairs({
			{ "", "value = 1" },
			{ "    ", "return value" },
			{ "\t", "if ready:\n\t\tpass" },
			{ "", "if ready:\n    pass" },
		}) do
			local prefix, insertion = case[1], case[2]
			edit(prefix)
			vim.bo[buf].modified = false
			local changedtick = vim.api.nvim_buf_get_changedtick(buf)
			assert.is_true(controller.complete())
			requests[#requests].opts.on_update(insertion)
			assert.is_true(controller.visible())
			assert.equals(insertion, shown[#shown][2])
			assert.same({ prefix }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
			assert.same({ 1, #prefix }, vim.api.nvim_win_get_cursor(0))
			assert.equals(changedtick, vim.api.nvim_buf_get_changedtick(buf))
			assert.is_false(vim.bo[buf].modified)
		end
		assert.same({}, notices)
	end)
	it("clears a pending request on disconnect and teardown", function()
		controller.complete(); state.set_connection("idle")
		assert.is_true(requests[1].cancelled)
		requests[1].callback(nil, "stale"); assert.equals(0, #shown)
		state.set_connection("connected"); controller.complete(); controller.teardown()
		assert.is_true(requests[2].cancelled)
	end)
end)
