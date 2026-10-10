-- Unit checks for opencode input /command completion.
-- Run with: ./tests/run.sh unit

describe("opencode input slash commands", function()
	it("detects, filters, ranks, and formats slash completions", function()

local slash = require("opencode.slash")
local slash_commands = require("opencode.ui.input.slash_commands")

local function names(commands)
	local result = {}
	for _, command in ipairs(commands or {}) do
		table.insert(result, command.name)
	end
	return result
end

local unicode_commands = {
	{ name = "Обзор", description = "ПРОВЕРКА", aliases = { "ОЦЕНКА" } },
	{ name = "other", description = "Other" },
}
for _, query in ipairs({ "обзор", "ОБЗОР", "проверка", "оценка" }) do
	assert.same({ unicode_commands[1] }, slash_commands.filter_commands(unicode_commands, query))
end

local function assert_trigger(line, col, row, query, message)
	local trigger = slash_commands.detect_trigger_in_line(line, col, row)
	assert.is_truthy(trigger, message .. " should trigger")
	assert.equals(0, trigger.start_col, message .. " start_col")
	assert.equals(col, trigger.end_col, message .. " end_col")
	assert.equals(query, trigger.query, message .. " query")
end

assert_trigger("/", 1, 0, "", "bare slash")
assert_trigger("/help", #"/help", 0, "help", "slash command query")
assert_trigger("/models", #"/models", nil, "models", "row-agnostic helper")

assert.is_nil(slash_commands.detect_trigger_in_line("", 0, 0), "empty line should not trigger")
assert.is_nil(slash_commands.detect_trigger_in_line("hello /", #"hello /", 0), "slash after text should not trigger")
assert.is_nil(slash_commands.detect_trigger_in_line("/help x", #"/help x", 0), "command with args should not trigger")
assert.is_nil(slash_commands.detect_trigger_in_line("/help", #"/help", 1), "second row should not trigger")

local cleanup = {
	"ztest_alpha",
	"ztest_models",
	"ztest_sessions",
	"ztest_hidden",
}
for _, name in ipairs(cleanup) do
	slash.unregister(name)
end

local function noop() end

slash.register({
	name = "ztest_alpha",
	description = "Run alpha workflow",
	category = "test",
	handler = noop,
})
slash.register({
	name = "ztest_models",
	description = "Switch model",
	category = "test",
	handler = noop,
})
slash.register({
	name = "ztest_sessions",
	aliases = { "resume", "continue" },
	description = "List sessions",
	category = "test",
	handler = noop,
})
slash.register({
	name = "ztest_hidden",
	description = "Hidden command",
	category = "test",
	handler = noop,
	enabled = false,
})

local commands = slash.get_commands()
slash.register_defaults()
for _, command in ipairs(slash.get_commands()) do
	assert.is_truthy(command.name ~= "skill", "singular /skill must not be offered")
end
assert.same({ "ztest_alpha", "ztest_models", "ztest_sessions" }, names(slash_commands.filter_commands(commands, "ztest_")), "slash filtering should match command names")
assert.same({ "ztest_models" }, names(slash_commands.filter_commands(commands, "model")), "slash filtering should match descriptions")
assert.same({ "ztest_sessions" }, names(slash_commands.filter_commands(commands, "resume")), "slash filtering should match aliases")
assert.same({}, names(slash_commands.filter_commands(commands, "hidden")), "disabled commands should not be returned by slash.get_commands")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
local winid = vim.api.nvim_get_current_win()
local state = {
	visible = true,
	bufnr = bufnr,
	winid = winid,
}

local function set_one_line(line, col)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
	vim.api.nvim_win_set_cursor(winid, { 1, col })
end

set_one_line("/ztest_alpha", #"/ztest_alpha")
local trigger = slash_commands.detect_trigger_in_line("/ztest_alpha", #"/ztest_alpha", 0)
trigger.row = 0
trigger.line = "/ztest_alpha"
assert.is_truthy(slash_commands.insert_command(state, trigger, { name = "ztest_alpha" }), "slash insert should succeed")
assert.equals("/ztest_alpha ", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "slash insert should add a trailing space")

set_one_line("/ztest_alpha args", #"/ztest_alpha")
trigger = slash_commands.detect_trigger_in_line("/ztest_alpha args", #"/ztest_alpha", 0)
trigger.row = 0
trigger.line = "/ztest_alpha args"
assert.is_truthy(slash_commands.insert_command(state, trigger, { name = "ztest_alpha" }), "slash insert before args should succeed")
assert.equals("/ztest_alpha args", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "slash insert should not duplicate existing whitespace")

slash_commands.clear(state)
vim.api.nvim_buf_delete(bufnr, { force = true })
for _, name in ipairs(cleanup) do
	slash.unregister(name)
end

	end)
end)
