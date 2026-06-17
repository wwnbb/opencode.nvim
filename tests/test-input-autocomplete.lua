-- Headless checks for opencode input autocomplete widget selection.
-- Run with: nvim --headless --clean --cmd "set rtp+=." -l tests/test-input-autocomplete.lua

vim.opt.runtimepath:append(vim.fn.getcwd())

local autocomplete = require("opencode.ui.input.autocomplete")
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
assert_truthy(autocomplete.confirm(state), "slash autocomplete confirm should insert command")
assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1], "/help ", "slash autocomplete text")

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

autocomplete.clear(state)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })

print("Input autocomplete checks passed")
