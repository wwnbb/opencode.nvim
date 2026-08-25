-- Unit checks for cleanup orchestration and artifact reset semantics.
-- Run with: ./tests/run.sh tests/unit/cleanup_spec.lua

local function assert_eq(actual, expected, message)
	local equal = type(actual) == "table" and type(expected) == "table" and vim.deep_equal(actual, expected)
		or actual == expected
	if not equal then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

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
		stub("opencode.state", { "clear_all_pending_changes", "reset" })
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

		assert_eq(calls, {
			"opencode.sync.clear_all",
			"opencode.permission.state.clear_all",
			"opencode.question.state.clear_all",
			"opencode.edit.state.clear_all",
			"opencode.artifact.changes.clear",
			"opencode.state.clear_all_pending_changes",
			"opencode.session.lock.clear_all",
			"opencode.permission.danger.clear",
			"opencode.ui.chat.clear",
			"opencode.events.clear_history",
		}, "transient cleanup order")
	end)

	it("resets app state before clearing history without clearing listeners", function()
		require("opencode.cleanup").reset_all()

		assert_eq(calls[#calls - 1], "opencode.state.reset", "state reset order")
		assert_eq(calls[#calls], "opencode.events.clear_history", "history final order")
		for _, call in ipairs(calls) do
			assert(call ~= "opencode.events.clear", "cleanup must preserve event listeners")
		end
	end)
end)

describe("artifact change reset", function()
	local original_changes

	before_each(function()
		original_changes = package.loaded["opencode.artifact.changes"]
		package.loaded["opencode.artifact.changes"] = nil
	end)

	after_each(function()
		package.loaded["opencode.artifact.changes"] = original_changes
	end)

	it("resets the change ID allocator", function()
		local changes = require("opencode.artifact.changes")
		changes.clear()
		local first = changes.add_change("/tmp/opencode-cleanup-one", "before", "after")
		local second = changes.add_change("/tmp/opencode-cleanup-two", "before", "after")
		assert(first:match("_1$") ~= nil, "first change should use ID 1")
		assert(second:match("_2$") ~= nil, "second change should use ID 2")

		changes.clear()
		local reset = changes.add_change("/tmp/opencode-cleanup-reset", "before", "after")
		assert(reset:match("_1$") ~= nil, "clear should reset the change ID allocator")
		changes.clear()
	end)
end)
