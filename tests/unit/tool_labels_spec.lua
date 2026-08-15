-- Unit checks for pure tool label formatting (golden strings captured
-- from opencode.ui.chat.tasks before the tool_labels extraction).
-- Run with: ./tests/run.sh tests/unit/tool_labels_spec.lua

describe("opencode tool labels", function()
	it("format_tool_line renders golden label strings", function()
vim.opt.runtimepath:append(vim.fn.getcwd())

local tool_labels = require("opencode.ui.chat.tool_labels")

local function assert_line(tool_part, expected, message)
	local actual = tool_labels.format_tool_line(tool_part)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

assert_line({
	tool = "glob",
	state = { status = "completed", input = { pattern = "*.lua" }, metadata = { count = 3 } },
}, '✱ Glob "*.lua" (3 matches)', "glob completed")

assert_line({
	tool = "glob",
	state = { status = "pending", input = { pattern = "*.lua" } },
}, "~ Finding files...", "glob pending")

assert_line({
	tool = "grep",
	state = { status = "completed", input = { pattern = "TODO" }, metadata = { matches = 2 } },
}, '✱ Grep "TODO" (2 matches)', "grep completed")

assert_line({
	tool = "rg",
	state = { status = "completed", input = { pattern = "fn" }, metadata = { matchCount = 5 } },
}, '✱ Ripgrep "fn" (5 matches)', "rg completed")

assert_line({
	tool = "read",
	state = { status = "completed", input = { filePath = string.rep("x", 60) } },
}, "→ Read ..." .. string.rep("x", 37), "read completed with 60-char path")

assert_line({
	tool = "read",
	state = { status = "pending", input = { filePath = "short.lua" } },
}, "~ Reading file...", "read pending")

assert_line({
	tool = "write",
	state = { status = "completed", input = { filePath = string.rep("y", 20) } },
}, "← Wrote " .. string.rep("y", 20), "write completed with 20-char path")

assert_line({
	tool = "edit",
	state = { status = "completed", input = { filePath = string.rep("z", 50) } },
}, "← Edit ..." .. string.rep("z", 37), "edit completed with 50-char path")

assert_line({
	tool = "bash",
	state = { status = "completed", input = { description = "Run tests" } },
}, "# Run tests", "bash completed")

assert_line({
	tool = "bash",
	state = { status = "pending", input = {} },
}, "~ Writing command...", "bash pending")

assert_line({
	tool = "todowrite",
	state = {
		status = "completed",
		input = {
			todos = {
				{ content = "A", status = "completed" },
				{ content = "B", status = "pending" },
				{ content = "C", status = "completed" },
			},
		},
	},
}, "⚙ Updated Todos 2/3 done", "todowrite completed")

assert_line({
	tool = "task",
	state = { status = "running", input = { subagent_type = "explore", description = "Find stuff" } },
}, "⠋ Explore Task – Find stuff", "task running")

assert_line({
	tool = "task",
	state = { status = "completed", input = { subagent_type = "explore", description = "Find stuff" } },
}, "✓ Explore Task – Find stuff", "task completed")

assert_line({
	tool = "skill",
	state = { status = "completed", input = {}, raw = "my-skill" },
}, '→ Skill "my-skill"', "skill completed")

assert_line({
	tool = "foo",
	state = { status = "pending", input = {} },
}, "~ foo...", "unknown tool pending")

assert_line({
	tool = "foo",
	state = { status = "completed", input = {} },
}, "⚙ foo", "unknown tool completed")
	end)

	it("format_summary_item_label prefers titles, truncates paths, and formats counts", function()
vim.opt.runtimepath:append(vim.fn.getcwd())

local tool_labels = require("opencode.ui.chat.tool_labels")

local function assert_label(item, expected, message)
	local actual = tool_labels.format_summary_item_label(item)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

assert_label({
	tool = "grep",
	state = { status = "completed", title = "X", input = { pattern = "p" } },
}, "Grep X", "server title preferred when completed")

assert_label({
	tool = "grep",
	state = { status = "running", title = "X", input = { pattern = "p" } },
}, "Grep X", "server title preferred when running")

assert_label({
	tool = "read",
	state = { status = "completed", input = { filePath = string.rep("a", 41) } },
}, "Read ..." .. string.rep("a", 37), "read fallback path truncation at 41 chars")

assert_label({
	tool = "rg",
	state = { status = "completed", input = { pattern = "fn" }, metadata = { matchCount = 5 } },
}, "Ripgrep fn (5 matches)", "rg matchCount fallback suffix")

assert_label({
	tool = "todowrite",
	state = {
		status = "completed",
		input = {
			todos = {
				{ content = "A", status = "completed" },
				{ content = "B", status = "pending" },
				{ content = "C", status = "completed" },
			},
		},
	},
}, "Update Todos 2/3 done", "todo progress label")
	end)

	it("format_state_duration formats durations across units", function()
vim.opt.runtimepath:append(vim.fn.getcwd())

local tool_labels = require("opencode.ui.chat.tool_labels")

local cases = {
	{ { start = 5, ["end"] = 5 }, nil, "end <= start yields nil" },
	{ { start = 1000, ["end"] = 4500 }, "3.5s", "seconds with one decimal" },
	{ { start = 0, ["end"] = 550 }, "9m10s", "sub-1000 raw delta stays in seconds" },
	{ { start = 0, ["end"] = 0.5 }, "500ms", "fractional duration yields milliseconds" },
	{ { start = 0, ["end"] = 55000 }, "55s", "whole seconds" },
	{ { start = 0, ["end"] = 62000 }, "1m02s", "minutes and seconds" },
	{ { start = 0, ["end"] = 9500 }, "9.5s", "sub-ten seconds keeps decimal" },
	{ nil, nil, "nil time yields nil" },
}
for _, case in ipairs(cases) do
	local actual = tool_labels.format_state_duration(case[1])
	if actual ~= case[2] then
		error(string.format("%s: expected %s, got %s", case[3], vim.inspect(case[2]), vim.inspect(actual)))
	end
end
	end)
end)
