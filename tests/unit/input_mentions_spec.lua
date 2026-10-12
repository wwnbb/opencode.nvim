describe("opencode input mentions", function()
	it("detects and serializes agent mentions", function()

local sync = require("opencode.sync")
local mentions = require("opencode.ui.input.mentions")

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

assert.same({ "grep_slave", "reviewer", "all", "id_only" }, names(sync.get_mentionable_agents()), "mentionable agents should match upstream visibility")

assert.same({ "grep_slave" }, names(mentions.filter_agents(sync.get_agents(), "grep")), "mention filtering should match names")
assert.same({ "grep_slave" }, names(mentions.filter_agents(sync.get_agents(), "search")), "mention filtering should match descriptions")

local unicode_agents = {
	{ id = "review", name = "Обзор", mode = "subagent", description = "ПРОВЕРКА" },
	{ id = "other", name = "Other", mode = "subagent" },
}
for _, query in ipairs({ "обзор", "ОБЗОР", "проверка" }) do
	assert.same({ unicode_agents[1] }, mentions.filter_agents(unicode_agents, query))
end

local function assert_trigger(line, col, start_col, query, message)
	local trigger = mentions.detect_trigger_in_line(line, col)
	assert.is_truthy(trigger, message .. " should trigger")
	assert.equals(start_col, trigger.start_col, message .. " start_col")
	assert.equals(col, trigger.end_col, message .. " end_col")
	assert.equals(query, trigger.query, message .. " query")
end

assert_trigger("@", 1, 0, "", "line-start @")
assert_trigger("hello @", #"hello @", 6, "", "whitespace before @")
assert_trigger("hello @grep", #"hello @grep", 6, "grep", "query after @")
assert_trigger("hello @old @gre", #"hello @old @gre", 11, "gre", "nearest @ wins")
assert_trigger("multi\t@agent", #"multi\t@agent", 6, "agent", "tab before @")
assert_trigger("unicode @grep", #"unicode @grep", 8, "grep", "ascii whitespace after unicode text")

assert.is_nil(mentions.detect_trigger_in_line("hello@", #"hello@"), "word-local @ should not trigger")
assert.is_nil(mentions.detect_trigger_in_line("foo@bar.com", #"foo@bar.com"), "email should not trigger")
assert.is_nil(mentions.detect_trigger_in_line("hello @grep now", #"hello @grep now"), "space after query should close trigger")
assert.is_nil(mentions.detect_trigger_in_line("hello @old@new", #"hello @old@new"), "nearest invalid @ should not fallback")
assert.is_nil(mentions.detect_trigger_in_line("中文@", #"中文@"), "non-whitespace before @ should not trigger")

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
assert.is_truthy(mentions.insert_mention(state, trigger, { name = "grep_slave" }), "insert mention should succeed")
assert.equals("@grep_slave ", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "insert should replace query and add trailing space")

local parts = mentions.active_parts(state)
assert.equals(1, #parts, "active mention should produce one part")
assert.equals("agent", parts[1].type, "active part type")
assert.equals("grep_slave", parts[1].name, "active part agent name")
assert.equals(0, parts[1].source.start, "active part source start")
assert.equals(#"@grep_slave", parts[1].source["end"], "active part source end")
assert.equals("@grep_slave", parts[1].source.value, "active part source value")

mentions.clear(state)
set_one_line("ask @gre now", #"ask @gre")
trigger = mentions.detect_trigger_in_line("ask @gre now", #"ask @gre")
trigger.row = 0
trigger.line = "ask @gre now"
assert.is_truthy(mentions.insert_mention(state, trigger, { name = "grep_slave" }), "insert before space should succeed")
assert.equals("ask @grep_slave now", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "insert should not duplicate existing whitespace")

mentions.clear(state)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello", "@pla" })
vim.api.nvim_win_set_cursor(winid, { 2, 4 })
trigger = mentions.detect_trigger_in_line("@pla", 4)
trigger.row = 1
trigger.line = "@pla"
assert.is_truthy(mentions.insert_mention(state, trigger, { name = "all" }), "multiline insert should succeed")
parts = mentions.active_parts(state)
assert.equals(#"hello\n", parts[1].source.start, "multiline source start should be byte offset")
assert.equals(#"hello\n@all", parts[1].source["end"], "multiline source end should be byte offset")

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "mention deleted" })
assert.equals(0, #mentions.active_parts(state), "deleted mention should not produce stale part")

mentions.clear(state)
vim.api.nvim_buf_delete(bufnr, { force = true })
sync.clear_all()

	end)
end)
