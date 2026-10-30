local tool_labels = require("opencode.ui.chat.tool_labels")

describe("opencode tool labels", function()
	it("labels task child rows with display names, quoted patterns and shared vocabulary", function()
		for _, case in ipairs({
			{ 'Glob "*.lua" (3 files)', "glob", { status = "completed", input = { pattern = "*.lua" }, metadata = { count = 3 } } },
			{ 'Grep "TODO" (1 match)', "grep", { status = "completed", input = { pattern = "TODO" }, metadata = { matches = 1 } } },
			{ "Shell Run checks", "bash", { status = "completed", input = { description = "Run checks" } } },
			{ "Explore Task · Find stuff", "task", { status = "completed", input = { subagent_type = "explore", description = "Find stuff" } } },
			{ "WebSearch", "websearch", { status = "completed", input = {} } },
			{ "My Tool", "my_tool", { status = "completed", input = {} } },
		}) do
			assert.equals(case[1], tool_labels.format_summary_item_label({ tool = case[2], state = case[3] }), case[2])
		end
		assert.equals("1 tool call", tool_labels.format_toolcall_count(1))
		assert.equals("3 tool calls", tool_labels.format_toolcall_count(3))
		assert.equals("Read lua/x.lua", tool_labels.format_summary_item_label({
			tool = "read", state = { status = "completed", input = { path = vim.fn.getcwd() .. "/lua/x.lua" } },
		}))
	end)

	it("keeps Unicode paths and descriptions intact when shortening labels", function()
		assert.equals("Grep X", tool_labels.format_summary_item_label({
			tool = "grep", state = { status = "running", title = "X", input = { pattern = "p" } },
		}))
		assert.equals("Read …" .. string.rep("я", 39), tool_labels.format_summary_item_label({
			tool = "read", state = { status = "completed", input = { path = string.rep("я", 41) } },
		}))
		assert.equals("Shell " .. string.rep("я", 39) .. "…", tool_labels.format_summary_item_label({
			tool = "bash", state = { input = { description = string.rep("я", 60) } },
		}))
	end)

	it("format_state_duration uses the shared duration format", function()
		local cases = {
			{ { start = 5, ["end"] = 5 }, nil, "end <= start yields nil" },
			{ { start = 1000, ["end"] = 4500 }, "3.5s", "seconds with one decimal" },
			{ { start = 0, ["end"] = 550 }, "550ms", "sub-second timestamps remain milliseconds" },
			{ { start = 0, ["end"] = 62000 }, "1m 2s", "minutes and seconds" },
			{ { start = 0, ["end"] = 3700000 }, "1h 1m", "hours and minutes" },
		}
		for _, case in ipairs(cases) do
			assert.equals(case[2], tool_labels.format_state_duration(case[1]), case[3])
		end
	end)

	it("formats projected native task timestamps in milliseconds", function()
		local projection = require("opencode.protocol.messages")
		local projected = projection.project("duration-session", {
			id = "assistant", type = "assistant", content = { {
				type = "tool", id = "call", name = "subagent",
				time = { created = 1700000000000, ran = 1700000000100, completed = 1700000000650 },
				state = { status = "completed", input = { agent = "explore" } },
			} },
		})
		assert.equals("550ms", tool_labels.format_state_duration(projected.parts[1].state.time))
	end)
end)
