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
end)
