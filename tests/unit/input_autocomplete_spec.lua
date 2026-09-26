-- Unit checks for opencode input autocomplete widget selection.
-- Run with: ./tests/run.sh unit

describe("opencode input autocomplete", function()
	it("confirms slash commands and mentions", function()
vim.opt.runtimepath:append(vim.fn.getcwd())

local autocomplete = require("opencode.ui.input.autocomplete")
local registry = require("opencode.command_registry")
local mentions = require("opencode.ui.input.mentions")
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

local bufnr = vim.api.nvim_get_current_buf()
local winid = vim.api.nvim_get_current_win()
local previous_virtualedit = vim.o.virtualedit
vim.o.virtualedit = "onemore"
local state = {
	visible = true,
	bufnr = bufnr,
	winid = winid,
	mentions = { parts = {} },
	autocomplete = {},
}

local function set_one_line(line, col)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
	vim.api.nvim_win_set_cursor(winid, { 1, col })
end

set_one_line("/", #"/")
state.autocomplete = {
	visible = true,
	selected = 1,
	trigger = {
		row = 0,
		line = "/",
		start_col = 0,
		end_col = 1,
		query = "",
	},
	items = {
		{ kind = "slash", label = "/help", command = { name = "help" } },
	},
}
local current_trigger = slash_commands.detect_trigger(state)
assert_truthy(current_trigger, "slash autocomplete trigger should be current")
assert_eq(current_trigger.query, state.autocomplete.trigger.query, "slash autocomplete query")
assert_truthy(autocomplete.confirm(state), "slash autocomplete confirm should insert command")
assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "/help ", "slash autocomplete text")

local runs, active = 0, true
registry.register({
	id = "test.autocomplete_popup",
	title = "Autocomplete popup",
	category = "test",
	slash = { name = "ztest_popup" },
	enabled = function() return active end,
	run = function() runs = runs + 1 end,
	on_select = function(ctx) return ctx.run() end,
})
state.allow_chat_commands = true
set_one_line("/ztest_po", #"/ztest_po")
state.autocomplete = {
	visible = true,
	selected = 1,
	trigger = slash_commands.detect_trigger_in_line("/ztest_po", #"/ztest_po", 0),
	items = {
		{ kind = "slash", label = "/ztest_popup", command = { id = "test.autocomplete_popup", name = "ztest_popup" } },
	},
}
local consumed, selected = autocomplete.confirm(state)
assert_truthy(consumed, "interactive slash completion should consume the token")
assert_eq(selected.id, "test.autocomplete_popup", "selection should identify the canonical command")
assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "", "selected command should leave no prompt token")
assert_truthy(registry.select(selected.id, { source = "slash_select" }), "selection should run through the registry")
assert_eq(runs, 1, "selected command should execute once")

active = false
set_one_line("/ztest_po", #"/ztest_po")
state.autocomplete = {
	visible = true,
	selected = 1,
	trigger = slash_commands.detect_trigger_in_line("/ztest_po", #"/ztest_po", 0),
	items = {
		{ kind = "slash", label = "/ztest_popup", command = { id = "test.autocomplete_popup", name = "ztest_popup" } },
	},
}
consumed, selected = autocomplete.confirm(state)
assert_eq(consumed, false, "disabled stale completion should not be confirmed")
assert_eq(selected, nil, "disabled stale completion should not activate")
assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "/ztest_po", "stale completion should preserve the draft")
assert_eq(runs, 1, "disabled stale completion should not execute")
active = true

local offered
for _, entry in ipairs(registry.list_slash()) do
	if entry.id == "test.autocomplete_popup" then offered = entry; break end
end
assert_truthy(offered and offered.generation, "slash completion should identify its registration")
registry.register({
	id = "test.autocomplete_popup",
	title = "Replacement popup",
	category = "test",
	slash = { name = "ztest_popup" },
	run = function() runs = runs + 100 end,
	on_select = function(ctx) return ctx.run() end,
})
set_one_line("/ztest_po", #"/ztest_po")
state.autocomplete = {
	visible = true,
	selected = 1,
	trigger = slash_commands.detect_trigger_in_line("/ztest_po", #"/ztest_po", 0),
	items = { { kind = "slash", label = "/ztest_popup", command = offered } },
}
consumed, selected = autocomplete.confirm(state)
assert_eq(consumed, false, "replaced completion should not be confirmed")
assert_eq(selected, nil, "replaced completion should not activate")
assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "/ztest_po", "replaced completion should preserve draft")
assert_eq(runs, 1, "replaced completion should not execute either registration")

state.allow_chat_commands = false
set_one_line("/ztest_po", #"/ztest_po")
state.autocomplete = {
	visible = true,
	selected = 1,
	trigger = slash_commands.detect_trigger_in_line("/ztest_po", #"/ztest_po", 0),
	items = {
		{ kind = "slash", label = "/ztest_popup", command = { id = "test.autocomplete_popup", name = "ztest_popup" } },
	},
}
consumed, selected = autocomplete.confirm(state)
assert_truthy(consumed, "non-chat editors should complete the command as text")
assert_eq(selected, nil, "non-chat completion should not activate the command")
assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "/ztest_popup ", "non-chat completion text")
assert_eq(runs, 1, "non-chat completion should not execute the command")

state.allow_chat_commands = true
set_one_line("/ztest_po then", #"/ztest_po")
state.autocomplete = {
	visible = true,
	selected = 1,
	trigger = slash_commands.detect_trigger_in_line("/ztest_po then", #"/ztest_po", 0),
	items = {
		{ kind = "slash", label = "/ztest_popup", command = { id = "test.autocomplete_popup", name = "ztest_popup" } },
	},
}
consumed, selected = autocomplete.confirm(state)
assert_truthy(consumed, "completion before existing text should insert the command")
assert_eq(selected, nil, "completion before existing text should not activate")
assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "/ztest_popup then", "completion should preserve following text")
assert_eq(runs, 1, "completion before text should not execute the command")

set_one_line("@cod", #"@cod")
state.autocomplete = {
	visible = true,
	selected = 1,
	trigger = mentions.detect_trigger_in_line("@cod", #"@cod"),
	items = {
		{ kind = "mention", label = "@coder_slave", agent = { name = "coder_slave" } },
	},
}
state.autocomplete.trigger.row = 0
state.autocomplete.trigger.line = "@cod"
assert_truthy(autocomplete.confirm(state), "mention autocomplete confirm should insert mention")
assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "@coder_slave ", "mention autocomplete text")

local parts = mentions.active_parts(state)
assert_eq(#parts, 1, "mention autocomplete should create one part")
assert_eq(parts[1].name, "coder_slave", "mention autocomplete part name")

set_one_line("/", #"/")
state.autocomplete = {
	visible = true,
	selected = 1,
	trigger = slash_commands.detect_trigger_in_line("/", #"/", 0),
	items = {
		{ kind = "slash", label = "/first", command = { name = "first" } },
		{ kind = "slash", label = "/second", command = { name = "second" } },
	},
}
assert_truthy(autocomplete.select_next(state), "select_next should move selection")
assert_eq(state.autocomplete.selected, 2, "select_next selected index")
assert_truthy(autocomplete.select_prev(state), "select_prev should move selection")
assert_eq(state.autocomplete.selected, 1, "select_prev selected index")

local confirmed, sent = 0, 0
require("opencode.ui.input.keymaps").setup(bufnr, { keymaps = { send = "<C-g>" } }, {
	autocomplete_visible = function() return true end,
	autocomplete_confirm = function() confirmed = confirmed + 1 end,
	send = function() sent = sent + 1 end,
})
local enter = vim.fn.maparg("<CR>", "i", false, true)
assert_truthy(type(enter.callback) == "function", "input Enter mapping should exist")
enter.callback()
assert_truthy(vim.wait(100, function() return confirmed == 1 end, 5), "Enter confirmation should run")
local tab = vim.fn.maparg("<Tab>", "i", false, true)
assert_truthy(type(tab.callback) == "function", "input Tab mapping should exist")
tab.callback()
assert_truthy(vim.wait(100, function() return confirmed == 2 end, 5), "Tab confirmation should run")
local send_key = vim.fn.maparg("<C-g>", "i", false, true)
assert_truthy(type(send_key.callback) == "function", "send key mapping should exist")
send_key.callback()
assert_truthy(vim.wait(100, function() return confirmed == 3 end, 5), "send key confirmation should run")
assert_eq(sent, 0, "completion should not send the draft")

autocomplete.clear(state)
registry.unregister("test.autocomplete_popup")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
vim.o.virtualedit = previous_virtualedit

print("Input autocomplete checks passed")
	end)
end)
