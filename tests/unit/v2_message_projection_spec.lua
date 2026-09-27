local projection = require("opencode.protocol.v2.messages")
local sync = require("opencode.sync")

describe("v2 history projection", function()
	before_each(function() sync.clear_all() end)
	after_each(function() sync.clear_all() end)
	it("preserves the real reasoning/text order and native metadata", function()
		local history = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/runtime/history.json"), "\n"))
		local page = projection.page("ses_test", history.data)
		sync.handle_session_messages("ses_test", page)
		local messages = sync.get_messages("ses_test")
		assert.equals("user", messages[1].role)
		assert.equals("assistant", messages[2].role)
		assert.is_true(messages[3].hidden)
		local parts = sync.get_parts(messages[2].id)
		assert.equals("reasoning", parts[1].type)
		assert.equals("text", parts[2].type)
		-- Ordinals are per content type in the real stream, not content[] indices.
		assert.equals(0, parts[1].ordinal)
		assert.equals(0, parts[2].ordinal)
		assert.equals("Привет, Neovim!", parts[2].text)
		assert.same(history.data[2], messages[2]._v2)
		assert.equals("mimo-v2.5-free", messages[2].modelID)
	end)

	it("keeps mixed tool output, call identity, errors, input and exact metadata", function()
		local message = { id = "msg_tool", type = "assistant", time = { created = 10 }, content = {
			{ type = "text", text = "Before" },
			{ type = "tool", id = "call/1", name = "neovim_edit", time = { created = 11, ran = 12, completed = 13 }, state = {
				status = "error", input = { file = "a.lua" }, metadata = { reviewed = false },
				error = { type = "Rejected", message = "User rejected" },
				content = { { type = "text", text = "First" }, { type = "file", uri = "file:///a", mime = "text/plain" }, { type = "text", text = "Second" } },
			} },
			{ type = "reasoning", text = "After" },
			{ type = "text", text = "Done" },
		} }
		sync.handle_session_messages("ses_test", { projection.project("ses_test", message) })
		local parts = sync.get_parts(message.id)
		assert.same({ "text", "tool", "reasoning", "text" }, vim.tbl_map(function(p) return p.type end, parts))
		assert.equals("First\nSecond", parts[2].state.output)
		assert.equals("file:///a", parts[2].state.files[1].uri)
		assert.equals("User rejected", parts[2].state.error)
		assert.equals("Rejected", parts[2].state.native_error.type)
		local identity = parts[2].id
		message.content[2].state.metadata = { replacement = true }
		sync.handle_session_messages("ses_test", { projection.project("ses_test", message) })
		assert.equals(identity, sync.get_parts(message.id)[2].id)
		assert.same({ replacement = true }, sync.get_parts(message.id)[2].state.metadata)
	end)

	it("removes only vanished content and never treats a partial page as deletion", function()
		local function message(id, time, content) return projection.project("ses_test", { id = id, type = "assistant", time = { created = time }, content = content }) end
		local a = message("msg_a", 1, { { type = "text", text = "A" } })
		local b = message("msg_b", 2, { { type = "text", text = "B" } })
		local c = message("msg_c", 3, { { type = "text", text = "C" }, { type = "reasoning", text = "gone" } })
		sync.handle_session_messages("ses_test", { a, b, c })
		local snapshot = sync.capture_session_snapshot("ses_test")
		sync.handle_session_messages("ses_test", { a, message("msg_c", 3, { { type = "text", text = "C" } }) }, { snapshot = snapshot, reconcile = true })
		assert.equals(3, #sync.get_messages("ses_test"))
		assert.equals(1, #sync.get_parts("msg_c"))
	end)

	it("preserves every native service message without creating a user turn", function()
		local hidden_types = { idle = true, ["agent-switched"] = true, ["model-switched"] = true }
		for _, kind in ipairs({ "synthetic", "system", "skill", "shell", "agent-switched", "model-switched", "location-switched", "compaction", "idle" }) do
			local native = { id = "msg_" .. kind, type = kind, time = { created = 1 }, metadata = { custom = false } }
			local projected = projection.project("ses_test", native)
			assert.equals("system", projected.info.role)
			assert.same(native, projected.info._v2)
			assert.equals(hidden_types[kind] == true, projected.info.hidden)
		end
	end)
end)
