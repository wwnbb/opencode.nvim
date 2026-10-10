-- Native diff review lifecycle checks.
-- Run with: ./tests/run.sh tests/checks/native_diff_review_lifecycle_spec.lua

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
		local edits = require("opencode.edit.state")
		require("opencode.state").set_config({ server = { shared_filesystem = true } })
		if native_diff.is_active() then
			native_diff.close()
		end

		local parent = vim.fn.tempname()
		local filepath = parent .. "/new.lua"
		pcall(os.remove, filepath)

		local files = {
			{
				filePath = filepath,
				before = "",
				after = "return true\n",
				type = "add",
				relativePath = "new.lua",
			},
		}
		edits.add_edit("review-add", "s", files, { transport = "review_rpc", revision = 1,
			native_review = { status = "pending" } })
		assert.is_truthy(native_diff.show(files, { edit_id = "review-add" }), "v2 review should open")

		local state = get_native_state(native_diff)
		assert.is_truthy(state and state.original_is_scratch, "missing add should use a scratch original buffer")
		assert.equals(0, vim.fn.filereadable(filepath), "opening an add diff must not create the target")
		assert.equals(0, vim.fn.isdirectory(parent), "opening an add diff must not create its parent directory")
		assert.equals(2, #vim.api.nvim_tabpage_list_wins(state.tab_page), "native diff should keep two panes")

		for _, buf in ipairs({ state.original_buf, state.proposed_buf }) do
			assert.is_truthy(has_buffer_keymap(buf, "<C-A>"), "current-file confirm should be reachable")
			assert.is_truthy(has_buffer_keymap(buf, "<C-X>"), "current-file reject should be reachable")
			assert.is_truthy(has_buffer_keymap(buf, "<C-S-X>"), "reject-all should be reachable")
		end

		native_diff.close()
		edits.clear_all()
		assert.is_truthy(not native_diff.is_active(), "closing should deactivate native diff")
		assert.equals(0, vim.fn.filereadable(filepath), "closing an unaccepted add diff must not create the target")
		assert.equals(0, vim.fn.isdirectory(parent), "closing an unaccepted add diff must not create its parent directory")
	end)

	it("does not write a modified scratch add while navigating files", function()
		local native_diff = require("opencode.ui.native_diff")
		local edits = require("opencode.edit.state")
		require("opencode.state").set_config({ server = { shared_filesystem = true } })
		if native_diff.is_active() then
			native_diff.close()
		end

		local parent = vim.fn.tempname()
		local add_path = parent .. "/new.lua"
		local next_path = vim.fn.tempname() .. ".lua"
		pcall(os.remove, add_path)
		pcall(os.remove, next_path)

		local files = {
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
		}
		edits.add_edit("review-navigation", "s", files, { transport = "review_rpc", revision = 1,
			native_review = { status = "pending" } })
		assert.is_truthy(native_diff.show(files, { edit_id = "review-navigation" }), "v2 review should open")

		local state = get_native_state(native_diff)
		vim.api.nvim_buf_set_lines(state.original_buf, 0, -1, false, { "manual edit" })
		assert.is_truthy(vim.bo[state.original_buf].modified, "scratch add should be modified for this regression")

		local leader_on = vim.api.nvim_replace_termcodes("<leader>on", true, false, true)
		local navigate = get_buffer_keymap_callback(state.original_buf, leader_on)
		assert.is_truthy(navigate, "next-file navigation keymap should be reachable")
		navigate()

		assert.equals(1, state.current_file_index, "navigation should wait for the modified review buffer")
		assert.equals(0, vim.fn.filereadable(add_path), "navigation must not write a modified scratch add")
		assert.equals(0, vim.fn.isdirectory(parent), "navigation must not create a scratch add parent directory")

		native_diff.close()
		edits.clear_all()
		pcall(os.remove, next_path)
	end)
end)
