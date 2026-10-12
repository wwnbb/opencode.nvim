local registry = require("opencode.command_registry")
local slash = require("opencode.slash")

describe("slash parsing", function()
	it("rejects text without a leading slash command", function()
		assert.is_nil(slash.parse(nil))
		for _, text in ipairs({ "", "/", "/ command", "command", " /command" }) do
			assert.is_nil(slash.parse(text))
		end
	end)

	it("preserves multiline arguments and the original text", function()
		local text = "/command \tfirst\nsecond\n"
		assert.same({ command = "command", args = "first\nsecond\n", raw = text }, slash.parse(text))
		assert.same({ command = "command", args = "", raw = "/command" }, slash.parse("/command"))
	end)
end)

describe("slash defaults", function()
	it("keeps slash and keybinding help registered independently", function()
		local palette = require("opencode.ui.palette")
		for _, register in ipairs({ slash.register_defaults, palette.register_defaults, slash.register_defaults }) do
			register()
			local command_help = registry.get_slash("help")
			local keybinding_help = registry.get("system.help")
			assert.is_not_nil(command_help)
			assert.is_not_nil(keybinding_help)
			assert.is_true(command_help.id ~= keybinding_help.id)
			assert.is_false(command_help.palette)
			assert.is_true(keybinding_help.palette)
			assert.equals("Show available commands", command_help.description)
			assert.equals("Show keybinding help", keybinding_help.description)
		end
	end)
end)

describe("slash undo availability", function()
	local state = require("opencode.state")
	local sync = require("opencode.sync")
	local projection = require("opencode.protocol.messages")

	before_each(function()
		state.reset()
		sync.clear_all()
		slash.register_defaults()
	end)

	after_each(function()
		sync.clear_all()
		state.reset()
	end)

	it("requires a user turn before the staged revert boundary", function()
		assert.is_false(registry.enabled("session.undo"))
		state.set_session("s", "Test")
		assert.is_false(registry.enabled("session.undo"))
		sync.handle_session_messages("s", projection.page("s", {
			{ id = "assistant", type = "assistant", content = {}, time = { created = 1 } },
			{ id = "first", type = "user", text = "First", time = { created = 2 } },
			{ id = "second", type = "user", text = "Second", time = { created = 3 } },
		}))
		assert.is_true(registry.enabled("session.undo"))
		state.upsert_session({ id = "s", revert = { messageID = "second" } })
		assert.is_true(registry.enabled("session.undo"))
		state.upsert_session({ id = "s", revert = { messageID = "first" } })
		assert.is_false(registry.enabled("session.undo"))
		state.upsert_session({ id = "s", revert = { messageID = "unloaded" } })
		assert.is_true(registry.enabled("session.undo"))
	end)
end)
