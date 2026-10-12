local tool_labels = require("opencode.ui.chat.tool_labels")

describe("opencode tool labels", function()
	it("format_tool_line renders golden label strings", function()
		for _, case in ipairs({
			{ '✱ Glob "*.lua" (3 matches)', "glob", { status = "completed", input = { pattern = "*.lua" }, metadata = { count = 3 } } },
			{ "~ Finding files...", "glob", { status = "pending", input = { pattern = "*.lua" } } },
			{ '✱ Grep "TODO" (2 matches)', "grep", { status = "completed", input = { pattern = "TODO" }, metadata = { matches = 2 } } },
			{ '✱ Glob "*.lua"', "glob", { status = "completed", input = { pattern = "*.lua" } } },
			{ '✱ Grep "TODO"', "grep", { status = "completed", input = { pattern = "TODO" } } },
			{ '✱ Ripgrep "fn" (5 matches)', "rg", { status = "completed", input = { pattern = "fn" }, metadata = { matchCount = 5 } } },
			{ "→ Read ..." .. string.rep("x", 37), "read", { status = "completed", input = { path = string.rep("x", 60) } } },
			{ "~ Reading file...", "read", { status = "pending", input = { path = "short.lua" } } },
			{ "← Wrote " .. string.rep("y", 20), "write", { status = "completed", input = { path = string.rep("y", 20) } } },
			{ "← Edit ..." .. string.rep("z", 37), "edit", { status = "completed", input = { path = string.rep("z", 50) } } },
			{ "# Run tests", "bash", { status = "completed", input = { description = "Run tests" } } },
			{ "~ Writing command...", "bash", { status = "pending", input = {} } },
			{ "⠋ Explore Task – Find stuff", "task", { status = "running", input = { subagent_type = "explore", description = "Find stuff" } } },
			{ "✓ Explore Task – Find stuff", "task", { status = "completed", input = { subagent_type = "explore", description = "Find stuff" } } },
			{ '→ Skill "my-skill"', "skill", { status = "completed", input = { name = "my-skill" } } },
			{ "~ foo...", "foo", { status = "pending", input = {} } },
			{ "⚙ foo", "foo", { status = "completed", input = {} } },
		}) do
			assert.equals(case[1], tool_labels.format_tool_line({ tool = case[2], state = case[3] }), case[2] .. ": " .. case[3].status)
		end
	end)

	it("format_summary_item_label prefers titles, truncates paths, and formats counts", function()
		for _, case in ipairs({
			{ "Grep X", "grep", { status = "completed", title = "X", input = { pattern = "p" } } },
			{ "Grep X", "grep", { status = "running", title = "X", input = { pattern = "p" } } },
			{ "Read ..." .. string.rep("a", 37), "read", { status = "completed", input = { path = string.rep("a", 41) } } },
			{ "Ripgrep fn (5 matches)", "rg", { status = "completed", input = { pattern = "fn" }, metadata = { matchCount = 5 } } },
		}) do
			assert.equals(case[1], tool_labels.format_summary_item_label({ tool = case[2], state = case[3] }), case[2] .. ": " .. case[3].status)
		end
	end)

	it("keeps Unicode paths and descriptions intact when shortening labels", function()
		for _, tool in ipairs({ "read", "write", "edit" }) do
			local label = tool_labels.format_summary_item_label({
				tool = tool,
				state = { status = "completed", input = { path = string.rep("я", 41) } },
			})
			assert.equals(tool:gsub("^%l", string.upper) .. " ..." .. string.rep("я", 37), label)
		end
		assert.equals("Bash " .. string.rep("я", 37) .. "...", tool_labels.format_summary_item_label({
			tool = "bash", state = { input = { description = string.rep("я", 60) } },
		}))
		assert.equals("Grep " .. string.rep("я", 49) .. "...", tool_labels.format_summary_item_label({
			tool = "grep", state = { status = "completed", title = string.rep("я", 60) },
		}))
	end)

	it("format_state_duration formats durations across units", function()
		local cases = {
			{ { start = 5, ["end"] = 5 }, nil, "end <= start yields nil" },
			{ { start = 1000, ["end"] = 4500 }, "3.5s", "seconds with one decimal" },
			{ { start = 0, ["end"] = 550 }, "550ms", "sub-second timestamps remain milliseconds" },
			{ { start = 0, ["end"] = 0.5 }, "1ms", "fractional milliseconds round to the nearest millisecond" },
			{ { start = 0, ["end"] = 55000 }, "55s", "whole seconds" },
			{ { start = 0, ["end"] = 62000 }, "1m02s", "minutes and seconds" },
			{ { start = 0, ["end"] = 9500 }, "9.5s", "sub-ten seconds keeps decimal" },
			{ { start = 0, ["end"] = 59999 }, "1m00s", "rounded seconds carry into minutes" },
			{ { start = 0, ["end"] = 119999 }, "2m00s", "minute remainder does not become 60 seconds" },
			{ nil, nil, "nil time yields nil" },
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
		assert.equals("550ms", require("opencode.ui.chat.tool_labels").format_state_duration(projected.parts[1].state.time))
	end)
end)
