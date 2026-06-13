-- Headless checks for opencode input /command completion.
-- Run with: nvim --headless --clean --cmd "set rtp+=." -l scripts/test-input-slash-commands.lua

vim.opt.runtimepath:append(vim.fn.getcwd())

local slash = require("opencode.slash")
local slash_commands = require("opencode.ui.input.slash_commands")

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_truthy(value, message)
	if not value then
		error(message)
	end
end

local function assert_nil(value, message)
	if value ~= nil then
		error(string.format("%s: expected nil, got %s", message, vim.inspect(value)))
	end
end

local function names(commands)
	local result = {}
	for _, command in ipairs(commands or {}) do
		table.insert(result, command.name)
	end
	return result
end

local function assert_trigger(line, col, row, query, message)
	local trigger = slash_commands.detect_trigger_in_line(line, col, row)
	assert_truthy(trigger, message .. " should trigger")
	assert_eq(trigger.start_col, 0, message .. " start_col")
	assert_eq(trigger.end_col, col, message .. " end_col")
	assert_eq(trigger.query, query, message .. " query")
end

assert_trigger("/", 1, 0, "", "bare slash")
assert_trigger("/help", #"/help", 0, "help", "slash command query")
assert_trigger("/models", #"/models", nil, "models", "row-agnostic helper")

assert_nil(slash_commands.detect_trigger_in_line("", 0, 0), "empty line should not trigger")
assert_nil(slash_commands.detect_trigger_in_line("hello /", #"hello /", 0), "slash after text should not trigger")
assert_nil(slash_commands.detect_trigger_in_line("/help x", #"/help x", 0), "command with args should not trigger")
assert_nil(slash_commands.detect_trigger_in_line("/help", #"/help", 1), "second row should not trigger")

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
assert_eq(
	vim.inspect(names(slash_commands.filter_commands(commands, "ztest_"))),
	vim.inspect({ "ztest_alpha", "ztest_models", "ztest_sessions" }),
	"slash filtering should match command names"
)
assert_eq(
	vim.inspect(names(slash_commands.filter_commands(commands, "model"))),
	vim.inspect({ "ztest_models" }),
	"slash filtering should match descriptions"
)
assert_eq(
	vim.inspect(names(slash_commands.filter_commands(commands, "resume"))),
	vim.inspect({ "ztest_sessions" }),
	"slash filtering should match aliases"
)
assert_eq(
	vim.inspect(names(slash_commands.filter_commands(commands, "hidden"))),
	vim.inspect({}),
	"disabled commands should not be returned by slash.get_commands"
)

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
assert_truthy(slash_commands.insert_command(state, trigger, { name = "ztest_alpha" }), "slash insert should succeed")
assert_eq(
	vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1],
	"/ztest_alpha ",
	"slash insert should add a trailing space"
)

set_one_line("/ztest_alpha args", #"/ztest_alpha")
trigger = slash_commands.detect_trigger_in_line("/ztest_alpha args", #"/ztest_alpha", 0)
trigger.row = 0
trigger.line = "/ztest_alpha args"
assert_truthy(slash_commands.insert_command(state, trigger, { name = "ztest_alpha" }), "slash insert before args should succeed")
assert_eq(
	vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1],
	"/ztest_alpha args",
	"slash insert should not duplicate existing whitespace"
)

slash_commands.clear(state)
vim.api.nvim_buf_delete(bufnr, { force = true })
for _, name in ipairs(cleanup) do
	slash.unregister(name)
end

print("Input slash command checks passed")
