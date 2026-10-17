describe("opencode cleanup", function()
	local module_names = {
		"opencode.cleanup",
		"opencode.sync",
		"opencode.permission.state",
		"opencode.question.state",
		"opencode.edit.state",
		"opencode.artifact.changes",
		"opencode.state",
		"opencode.session.lock",
		"opencode.permission.danger",
		"opencode.ui.chat",
		"opencode.events",
	}
	local saved_modules
	local calls

	local function stub(module_name, functions)
		local module = {}
		for _, function_name in ipairs(functions) do
			module[function_name] = function()
				table.insert(calls, module_name .. "." .. function_name)
			end
		end
		package.loaded[module_name] = module
	end

	before_each(function()
		saved_modules = {}
		for _, module_name in ipairs(module_names) do
			saved_modules[module_name] = package.loaded[module_name]
		end
		calls = {}

		stub("opencode.sync", { "clear_all" })
		stub("opencode.permission.state", { "clear_all" })
		stub("opencode.question.state", { "clear_all" })
		stub("opencode.edit.state", { "clear_all" })
		stub("opencode.artifact.changes", { "clear" })
		stub("opencode.state", { "reset" })
		stub("opencode.session.lock", { "clear_all" })
		stub("opencode.permission.danger", { "clear" })
		stub("opencode.ui.chat", { "clear" })
		stub("opencode.events", { "clear_history", "clear" })
		package.loaded["opencode.cleanup"] = nil
	end)

	after_each(function()
		for _, module_name in ipairs(module_names) do
			package.loaded[module_name] = saved_modules[module_name]
		end
	end)

	it("clears all transient owners and clears history last", function()
		require("opencode.cleanup").clear_transient({ reset_state = false, clear_chat = true })

		assert.same({
			"opencode.sync.clear_all",
			"opencode.permission.state.clear_all",
			"opencode.question.state.clear_all",
			"opencode.edit.state.clear_all",
			"opencode.artifact.changes.clear",
			"opencode.session.lock.clear_all",
			"opencode.permission.danger.clear",
			"opencode.ui.chat.clear",
			"opencode.events.clear_history",
		}, calls, "transient cleanup order")
	end)

	it("resets app state before clearing history without clearing listeners", function()
		require("opencode.cleanup").reset_all()

		assert.equals("opencode.state.reset", calls[#calls - 1], "state reset order")
		assert.equals("opencode.events.clear_history", calls[#calls], "history final order")
		for _, call in ipairs(calls) do
			assert(call ~= "opencode.events.clear", "cleanup must preserve event listeners")
		end
	end)

	it("clears and invalidates every pane on reset", function()
		local views = require("opencode.ui.chat.state")
		local second = views.new()
		local cleared, invalidated = {}, {}
		package.loaded["opencode.ui.chat"] = { for_view = function(view)
			return {
				clear = function() cleared[view.id] = true end,
				session_changed = function(session, opts)
					assert.same({}, session)
					assert.equals("reset", opts.reason)
					invalidated[view.id] = true
				end,
			}
		end }
		local ok, err = xpcall(function()
			require("opencode.cleanup").reset_all()
			for _, view in ipairs(views.all()) do
				assert.is_true(cleared[view.id])
				assert.equals(view.session_bound == true, invalidated[view.id] == true)
			end
			assert.is_not_true(views.state.session_bound)
		end, debug.traceback)
		views.remove(second)
		assert.is_true(ok, err)
	end)
end)
