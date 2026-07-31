-- Native diff review lifecycle checks.
-- Run with: ./tests/run.sh tests/checks/native_diff_review_lifecycle_spec.lua

local function assert_true(value, message)
	if not value then
		error(message)
	end
end

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function get_native_state(native_diff)
	for index = 1, math.huge do
		local name, value = debug.getupvalue(native_diff.show, index)
		if not name then
			break
		end
		if name == "state" then
			return value
		end
	end
	return nil
end

local function has_buffer_keymap(buf, lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if mapping.lhs == lhs then
			return true
		end
	end
	return false
end

local function get_buffer_keymap_callback(buf, lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if mapping.lhs == lhs then
			return mapping.callback
		end
	end
	return nil
end

describe("native diff review lifecycle", function()
	it("does not materialize an add target before confirmation", function()
		local native_diff = require("opencode.ui.native_diff")
		if native_diff.is_active() then
			native_diff.close()
		end

		local parent = vim.fn.tempname()
		local filepath = parent .. "/new.lua"
		pcall(os.remove, filepath)

		native_diff.show("native_diff_lifecycle_permission", {
			{
				filePath = filepath,
				before = "",
				after = "return true\n",
				type = "add",
				relativePath = "new.lua",
			},
		})

		local state = get_native_state(native_diff)
		assert_true(state and state.original_is_scratch, "missing add should use a scratch original buffer")
		assert_eq(vim.fn.filereadable(filepath), 0, "opening an add diff must not create the target")
		assert_eq(vim.fn.isdirectory(parent), 0, "opening an add diff must not create its parent directory")
		assert_eq(#vim.api.nvim_tabpage_list_wins(state.tab_page), 2, "native diff should keep two panes")

		for _, buf in ipairs({ state.original_buf, state.proposed_buf }) do
			assert_true(has_buffer_keymap(buf, "<C-A>"), "current-file confirm should be reachable")
			assert_true(has_buffer_keymap(buf, "<C-X>"), "current-file reject should be reachable")
			assert_true(has_buffer_keymap(buf, "<C-S-X>"), "reject-all should be reachable")
		end

		native_diff.close()
		assert_true(not native_diff.is_active(), "closing should deactivate native diff")
		assert_eq(vim.fn.filereadable(filepath), 0, "closing an unaccepted add diff must not create the target")
		assert_eq(vim.fn.isdirectory(parent), 0, "closing an unaccepted add diff must not create its parent directory")
	end)

	it("does not write a modified scratch add while navigating files", function()
		local native_diff = require("opencode.ui.native_diff")
		if native_diff.is_active() then
			native_diff.close()
		end

		local parent = vim.fn.tempname()
		local add_path = parent .. "/new.lua"
		local next_path = vim.fn.tempname() .. ".lua"
		pcall(os.remove, add_path)
		pcall(os.remove, next_path)

		native_diff.show(nil, {
			{
				filePath = add_path,
				before = "",
				after = "return true\n",
				type = "add",
			},
			{
				filePath = next_path,
				before = "",
				after = "next\n",
				type = "update",
			},
		})

		local state = get_native_state(native_diff)
		vim.api.nvim_buf_set_lines(state.original_buf, 0, -1, false, { "manual edit" })
		assert_true(vim.bo[state.original_buf].modified, "scratch add should be modified for this regression")

		local leader_on = vim.api.nvim_replace_termcodes("<leader>on", true, false, true)
		local navigate = get_buffer_keymap_callback(state.original_buf, leader_on)
		assert_true(navigate, "next-file navigation keymap should be reachable")
		navigate()

		assert_eq(state.current_file_index, 2, "navigation should advance to the next file")
		assert_eq(vim.fn.filereadable(add_path), 0, "navigation must not write a modified scratch add")
		assert_eq(vim.fn.isdirectory(parent), 0, "navigation must not create a scratch add parent directory")

		native_diff.close()
		pcall(os.remove, next_path)
	end)
end)
