-- Headless checks for opencode input @agent mentions.
-- Run with: nvim --headless --clean --cmd "set rtp+=." -l tests/test-input-mentions.lua

vim.opt.runtimepath:append(vim.fn.getcwd())

local sync = require("opencode.sync")
local mentions = require("opencode.ui.input.mentions")

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

local function names(agents)
	local result = {}
	for _, agent in ipairs(agents or {}) do
		table.insert(result, agent.name or agent.id)
	end
	return result
end

sync.clear_all()
sync.handle_agents({
	{ id = "build", name = "build", mode = "primary" },
	{ id = "plan", name = "plan", mode = "primary", hidden = vim.NIL },
	{ id = "grep_slave", name = "grep_slave", mode = "subagent", description = "Search worker" },
	{ id = "reviewer", name = "reviewer", mode = "subagent", hidden = false },
	{ id = "all", name = "all", mode = "all" },
	{ id = "hidden_worker", name = "hidden_worker", mode = "subagent", hidden = true },
	{ id = "id_only", mode = "subagent" },
	{ mode = "subagent" },
})

assert_eq(
	vim.inspect(names(sync.get_mentionable_agents())),
	vim.inspect({ "grep_slave", "reviewer", "all", "id_only" }),
	"mentionable agents should match upstream visibility"
)

assert_eq(
	vim.inspect(names(mentions.filter_agents(sync.get_agents(), "grep"))),
	vim.inspect({ "grep_slave" }),
	"mention filtering should match names"
)
assert_eq(
	vim.inspect(names(mentions.filter_agents(sync.get_agents(), "search"))),
	vim.inspect({ "grep_slave" }),
	"mention filtering should match descriptions"
)

local function assert_trigger(line, col, start_col, query, message)
	local trigger = mentions.detect_trigger_in_line(line, col)
	assert_truthy(trigger, message .. " should trigger")
	assert_eq(trigger.start_col, start_col, message .. " start_col")
	assert_eq(trigger.end_col, col, message .. " end_col")
	assert_eq(trigger.query, query, message .. " query")
end

assert_trigger("@", 1, 0, "", "line-start @")
assert_trigger("hello @", #"hello @", 6, "", "whitespace before @")
assert_trigger("hello @grep", #"hello @grep", 6, "grep", "query after @")
assert_trigger("hello @old @gre", #"hello @old @gre", 11, "gre", "nearest @ wins")
assert_trigger("multi\t@agent", #"multi\t@agent", 6, "agent", "tab before @")
assert_trigger("unicode @grep", #"unicode @grep", 8, "grep", "ascii whitespace after unicode text")

assert_nil(mentions.detect_trigger_in_line("hello@", #"hello@"), "word-local @ should not trigger")
assert_nil(mentions.detect_trigger_in_line("foo@bar.com", #"foo@bar.com"), "email should not trigger")
assert_nil(mentions.detect_trigger_in_line("hello @grep now", #"hello @grep now"), "space after query should close trigger")
assert_nil(mentions.detect_trigger_in_line("hello @old@new", #"hello @old@new"), "nearest invalid @ should not fallback")
assert_nil(mentions.detect_trigger_in_line("中文@", #"中文@"), "non-whitespace before @ should not trigger")

mentions.setup_highlights()

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

set_one_line("@gre", 4)
local trigger = mentions.detect_trigger_in_line("@gre", 4)
trigger.row = 0
trigger.line = "@gre"
assert_truthy(mentions.insert_mention(state, trigger, { name = "grep_slave" }), "insert mention should succeed")
assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "@grep_slave ", "insert should replace query and add trailing space")

local parts = mentions.active_parts(state)
assert_eq(#parts, 1, "active mention should produce one part")
assert_eq(parts[1].type, "agent", "active part type")
assert_eq(parts[1].name, "grep_slave", "active part agent name")
assert_eq(parts[1].source.start, 0, "active part source start")
assert_eq(parts[1].source["end"], #"@grep_slave", "active part source end")
assert_eq(parts[1].source.value, "@grep_slave", "active part source value")

mentions.clear(state)
set_one_line("ask @gre now", #"ask @gre")
trigger = mentions.detect_trigger_in_line("ask @gre now", #"ask @gre")
trigger.row = 0
trigger.line = "ask @gre now"
assert_truthy(mentions.insert_mention(state, trigger, { name = "grep_slave" }), "insert before space should succeed")
assert_eq(
	vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1],
	"ask @grep_slave now",
	"insert should not duplicate existing whitespace"
)

mentions.clear(state)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello", "@pla" })
vim.api.nvim_win_set_cursor(winid, { 2, 4 })
trigger = mentions.detect_trigger_in_line("@pla", 4)
trigger.row = 1
trigger.line = "@pla"
assert_truthy(mentions.insert_mention(state, trigger, { name = "all" }), "multiline insert should succeed")
parts = mentions.active_parts(state)
assert_eq(parts[1].source.start, #"hello\n", "multiline source start should be byte offset")
assert_eq(parts[1].source["end"], #"hello\n@all", "multiline source end should be byte offset")

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "mention deleted" })
assert_eq(#mentions.active_parts(state), 0, "deleted mention should not produce stale part")

mentions.clear(state)
vim.api.nvim_buf_delete(bufnr, { force = true })
sync.clear_all()

print("Input mention checks passed")
