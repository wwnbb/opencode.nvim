describe("opencode global keymaps", function()
	local commands = require("opencode.commands")
	local actions = require("opencode.actions")
	local first, second, user_key = "<Plug>(opencode-test-first)", "<Plug>(opencode-test-second)", "<Plug>(opencode-test-user)"

	local function mapping(lhs)
		return vim.fn.maparg(lhs, "n", false, true)
	end

	after_each(function()
		commands.configure_keymaps({})
		for _, lhs in ipairs({ first, second, user_key }) do
			if next(mapping(lhs)) then vim.keymap.del("n", lhs) end
		end
	end)

	it("replaces and disables plugin mappings", function()
		commands.configure_keymaps({ toggle = first, command_palette = second })
		assert.equals("Toggle OpenCode", mapping(first).desc)
		assert.equals("OpenCode command palette", mapping(second).desc)

		commands.configure_keymaps({ toggle = second, command_palette = false })
		assert.same({}, mapping(first))
		assert.equals("Toggle OpenCode", mapping(second).desc)

		commands.configure_keymaps(nil)
		assert.same({}, mapping(second))
	end)

	it("preserves user replacements and separate mappings of the same action", function()
		commands.configure_keymaps({ toggle = first })
		local original = mapping(first).callback
		local replacement = function() end
		vim.keymap.set("n", first, replacement)
		vim.keymap.set("n", user_key, actions.toggle)

		commands.configure_keymaps({ toggle = second })
		assert.equals(replacement, mapping(first).callback)
		assert.equals(actions.toggle, mapping(user_key).callback)
		assert.is_not.equal(original, mapping(second).callback)

		commands.configure_keymaps({})
		assert.same({}, mapping(second))
		assert.equals(replacement, mapping(first).callback)
		assert.equals(actions.toggle, mapping(user_key).callback)
	end)

	it("remaps every abort alias and restores the previous mapping when disabled", function()
		local previous_abort, calls = actions.abort, 0
		actions.abort = function() calls = calls + 1 end
		local ok, err = pcall(function()
			vim.keymap.set("n", first, "original abort key")
			local original = mapping(first)
			commands.configure_keymaps({ abort = { first, second } })
			mapping(first).callback()
			mapping(second).callback()
			assert.equals(2, calls)
			commands.configure_keymaps({ abort = user_key })
			assert.same(original, mapping(first))
			assert.same({}, mapping(second))
			assert.equals("Abort OpenCode generation", mapping(user_key).desc)
			commands.configure_keymaps({ abort = false })
			assert.same({}, mapping(user_key))
			assert.same(original, mapping(first))
		end)
		actions.abort = previous_abort
		if not ok then error(err) end
	end)

	it("keeps a newer user abort mapping when disabling all global bindings", function()
		commands.configure_keymaps({ abort = { first, second } })
		local replacement = function() end
		vim.keymap.set("n", first, replacement)
		commands.configure_keymaps({})
		assert.equals(replacement, mapping(first).callback)
		assert.same({}, mapping(second))
	end)

	it("removes the default abort mapping without adding omitted global bindings", function()
		local defaults = require("opencode.config").defaults.keymaps
		local before_abort, before_toggle = mapping(defaults.abort), mapping(defaults.toggle)
		commands.configure_keymaps({ abort = defaults.abort })
		assert.equals("Abort OpenCode generation", mapping(defaults.abort).desc)
		assert.same(before_toggle, mapping(defaults.toggle))
		commands.configure_keymaps({ abort = false })
		assert.same(before_abort, mapping(defaults.abort))
		assert.same(before_toggle, mapping(defaults.toggle))
	end)

	it("returns to explicit default keys even when app state still contains a custom configuration", function()
		local app, config = require("opencode.state"), require("opencode.config")
		local previous_config = app.get_config()
		local ok, err = pcall(function()
			local customized = config.merge({ keymaps = { toggle = first } })
			app.set_config(customized)
			commands.configure_keymaps(customized.keymaps)
			assert.equals("Toggle OpenCode", mapping(first).desc)
			commands.configure_keymaps(config.defaults.keymaps)
			assert.same({}, mapping(first))
			assert.equals("Toggle OpenCode", mapping(config.defaults.keymaps.toggle).desc)
		end)
		app.set_config(previous_config)
		if not ok then error(err) end
	end)
end)
