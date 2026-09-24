local native = require("opencode.ui.native_diff")
local edits = require("opencode.edit.state")
local state = require("opencode.state")
describe("native v2 review file actions", function()
	local path, notify, select_ui, chat_edits
	local function read() return table.concat(vim.fn.readfile(path, "b"), "\n") end
	local function open(kind)
		vim.fn.writefile({ "before" }, path)
		edits.add_edit("r", "s", { { fileID = "f", filePath = path, before = "before\n", after = "after\n", type = kind or "update" } },
			{ transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
		native.show({ { filePath = path, before = "before\n", after = "after\n", type = kind or "update", edit_file_index = 1 } }, { edit_id = "r" })
	end
	before_each(function()
		path = vim.fn.tempname(); notify, select_ui = vim.notify, vim.ui.select
		vim.notify = function() end
		chat_edits = package.loaded["opencode.ui.chat.edits"]
		package.loaded["opencode.ui.chat.edits"] = { refresh_edit = function() end }
		state.set_config({ server = { shared_filesystem = true } }); state.set_connection("connected")
	end)
	after_each(function()
		local buf = vim.fn.bufnr(path)
		if buf >= 0 then vim.bo[buf].modified = false end
		native.close(); edits.clear_all(); require("opencode.artifact.changes").clear()
		if buf >= 0 and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
		vim.fn.delete(path); vim.notify, vim.ui.select = notify, select_ui
		package.loaded["opencode.ui.chat.edits"] = chat_edits; state.set_connection("idle")
	end)
	it("does not flush a manual diff buffer after connection loss", function()
		open()
		local buf = vim.fn.bufnr(path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "manual" })
		state.set_connection("idle")
		native._confirm_current()
		assert.equals("before\n", read()); assert.is_true(vim.bo[buf].modified)
		assert.equals("pending", edits.get_edit("r").files[1].status)
	end)
	it("reject does not replace divergent disk bytes or unsaved manual buffer", function()
		open()
		local buf = vim.fn.bufnr(path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved manual" })
		native._reject_current()
		assert.equals("before\n", read()); assert.is_true(vim.bo[buf].modified)
		assert.equals("pending", edits.get_edit("r").files[1].status)
		vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
		native._reject_all()
		assert.equals("unsaved manual\n", read())
		assert.equals("rejected", edits.get_edit("r").files[1].status)
	end)
	it("late delete confirmation cannot write after review cancellation", function()
		local choose
		vim.ui.select = function(_, _, callback) choose = callback end
		open("delete")
		edits.set_review_record({ reviewID = "r", sessionID = "s", revision = 1, status = "cancelled" })
		choose("Yes, delete")
		assert.equals("before\n", read())
	end)
end)
