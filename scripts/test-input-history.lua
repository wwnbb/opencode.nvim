-- Headless checks for opencode input history ownership.
-- Run with: nvim --headless --clean --cmd "set rtp+=." -l scripts/test-input-history.lua

vim.opt.runtimepath:append(vim.fn.getcwd())

local history = require("opencode.ui.input.history")

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_entries(expected, message)
	assert_eq(vim.inspect(history.entries()), vim.inspect(expected), message)
end

local history_file = vim.fn.tempname()
history.configure({
	history_file = history_file,
	max_history = 2,
})
history.clear()

history.add("one")
history.add("two")
history.add("three")
assert_entries({ "two", "three" }, "max_history should trim old entries")

history.add("three")
assert_entries({ "two", "three" }, "most recent duplicate should not be added")

local pending_parts = {
	{
		type = "file",
		filename = "original.png",
		source = {
			type = "file",
			path = "original.png",
			text = { value = "[Image 1]" },
		},
	},
}

history.set_pending("draft", pending_parts)
pending_parts[1].filename = "mutated.png"

local pending_copy = history.get_pending_parts()
assert_eq(pending_copy[1].filename, "original.png", "pending parts should copy input tables")

pending_copy[1].filename = "copy-mutated.png"
assert_eq(history.get_pending_parts()[1].filename, "original.png", "pending parts should copy output tables")

local stash_parts = {
	{
		type = "file",
		filename = "stash.png",
		source = {
			type = "file",
			path = "stash.png",
			text = { value = "[Image 1]" },
		},
	},
}

history.set_stash("stashed", stash_parts)
stash_parts[1].filename = "mutated-stash.png"

local text, restored_parts = history.take_stash()
assert_eq(text, "stashed", "stash should restore text")
assert_eq(restored_parts[1].filename, "stash.png", "stashed parts should copy input tables")

restored_parts[1].filename = "copy-mutated-stash.png"
history.set_stash("stashed-again", restored_parts)
restored_parts[1].filename = "mutated-after-restash.png"

local _, restored_again = history.take_stash()
assert_eq(restored_again[1].filename, "copy-mutated-stash.png", "stashed parts should copy output tables")

history.clear()
os.remove(history_file)

print("input history checks passed")
