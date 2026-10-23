local keymaps = require("opencode.util.keymap")
local app = require("opencode.state")

describe("inline diff review keys", function()
	local edits, reviews, actions = require("opencode.ui.chat.edits"), require("opencode.edit.state"), require("opencode.actions")
	local saved_config, saved_reply, previous_tab, tab, paths

	local function mapping(bufnr, key)
		for _, item in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
			if keymaps.matches(item.lhs, key) then return item.callback end
		end
	end

	local function marked_windows()
		local result = {}
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if edits.is_inline_diff_window(win) then result[#result + 1] = win end
		end
		return result
	end

	before_each(function()
		saved_config, saved_reply = app.get_config(), actions.reply_review
		app.set_config({ server = { shared_filesystem = true } })
		app.set_connection("connected")
		previous_tab = vim.api.nvim_get_current_tabpage()
		paths = { vim.fn.tempname(), vim.fn.tempname() }
		for _, path in ipairs(paths) do vim.fn.writefile({ "before" }, path) end
		vim.cmd("tabnew " .. vim.fn.fnameescape(paths[1]))
		tab = vim.api.nvim_get_current_tabpage()
	end)

	after_each(function()
		edits.close_inline_diff_split({ silent = true })
		reviews.clear_all()
		actions.reply_review = saved_reply
		if tab and vim.api.nvim_tabpage_is_valid(tab) then
			vim.api.nvim_set_current_tabpage(tab)
			vim.cmd("tabclose!")
		end
		vim.api.nvim_set_current_tabpage(previous_tab)
		app.set_connection("idle")
		app.set_config(saved_config)
	end)

	it("confirm resolves the split's file and reject rejects it, each closing the split", function()
		local replies = {}
		actions.reply_review = function(id) replies[#replies + 1] = id; return true end
		local review = reviews.add_edit("inline-keys", "s", {
			{ fileID = "a", filePath = paths[1], before = "before\n", after = "after\n", type = "update" },
			{ fileID = "b", filePath = paths[2], before = "before\n", after = "after\n", type = "update" },
		}, { transport = "review_rpc", revision = 1, native_review = { status = "pending" } })

		edits.open_inline_diff_split(review.files[1], { edit_id = "inline-keys", file_index = 1 })
		assert.equals(2, #marked_windows())
		local confirm = mapping(vim.api.nvim_get_current_buf(), "<C-a>")
		assert.is_truthy(confirm)
		confirm()
		assert.same({}, marked_windows())
		assert.are_not.equal("pending", reviews.get_edit("inline-keys").files[1].status)
		assert.equals("pending", reviews.get_edit("inline-keys").files[2].status)

		edits.open_inline_diff_split(review.files[2], { edit_id = "inline-keys", file_index = 2 })
		local actual = vim.api.nvim_get_current_buf()
		assert.equals(vim.fn.resolve(paths[2]), vim.fn.resolve(vim.api.nvim_buf_get_name(actual)))
		local reject = mapping(actual, "<C-x>")
		assert.is_truthy(reject)
		reject()
		assert.same({}, marked_windows())
		assert.equals("rejected", reviews.get_edit("inline-keys").files[2].status)
		assert.same({ "inline-keys" }, replies)
	end)

	it("ignores review keys once the split's file is no longer pending", function()
		local review = reviews.add_edit("inline-stale", "s", {
			{ fileID = "a", filePath = paths[1], before = "before\n", after = "after\n", type = "update" },
			{ fileID = "b", filePath = paths[2], before = "before\n", after = "after\n", type = "update" },
		}, { transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
		edits.open_inline_diff_split(review.files[1], { edit_id = "inline-stale", file_index = 1 })
		assert.is_true(reviews.reject_file("inline-stale", 1))
		mapping(vim.api.nvim_get_current_buf(), "<C-a>")()
		assert.equals(2, #marked_windows())
		assert.equals("rejected", reviews.get_edit("inline-stale").files[1].status)
	end)
end)
