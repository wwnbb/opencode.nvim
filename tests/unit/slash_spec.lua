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
