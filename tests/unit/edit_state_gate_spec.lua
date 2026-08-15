-- Unit checks for the edit-review disk-divergence gate and BOM handling.
-- Run with: ./tests/run.sh unit

local BOM = "\xEF\xBB\xBF"

local edit_state = require("opencode.edit.state")
local changes = require("opencode.artifact.changes")

local notifications = {}

local function write_disk(path, content)
	local file = assert(io.open(path, "wb"))
	file:write(content)
	file:close()
end

local function read_disk(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local content = file:read("*all")
	file:close()
	return content
end

local function add_edit(permission_id, file_data)
	return edit_state.add_edit(permission_id, "session_gate", { file_data })
end

describe("opencode edit state gate", function()
	before_each(function()
		notifications = {}
		vim.notify = function(message, level)
			table.insert(notifications, { message = message, level = level })
		end
		edit_state.clear_all()
		changes.clear()
	end)

	it("accept writes after when disk still matches before", function()
		local path = vim.fn.tempname()
		write_disk(path, "line1\nline2\n")

		local estate = add_edit("gate_1", {
			filePath = path,
			before = "line1\nline2\n",
			after = "line1\nchanged\n",
			type = "update",
		})

		local ok = edit_state.accept_file("gate_1", 1)
		assert.is_true(ok)
		assert.equals("line1\nchanged\n", read_disk(path))
		assert.equals("accepted", estate.files[1].status)
		assert.equals(0, #notifications)
	end)

	it("accept does not overwrite a file changed during review", function()
		local path = vim.fn.tempname()
		write_disk(path, "line1\nline2\n")

		local estate = add_edit("gate_2", {
			filePath = path,
			before = "line1\nline2\n",
			after = "line1\nchanged\n",
			type = "update",
		})

		write_disk(path, "user edits\n")

		local ok = edit_state.accept_file("gate_2", 1)
		assert.is_true(ok)
		assert.equals("user edits\n", read_disk(path))
		assert.is_not_equals("pending", estate.files[1].status)
		assert.is_true(#notifications > 0)
		assert.is_true(notifications[1].message:find(path, 1, true) ~= nil)
	end)

	it("reject restores before when disk holds the proposal", function()
		local path = vim.fn.tempname()
		write_disk(path, "original\n")

		local estate = add_edit("gate_3", {
			filePath = path,
			before = "original\n",
			after = "proposed\n",
			type = "update",
		})

		write_disk(path, "proposed\n")

		local ok = edit_state.reject_file("gate_3", 1)
		assert.is_true(ok)
		assert.equals("original\n", read_disk(path))
		assert.equals("rejected", estate.files[1].status)
		assert.equals(0, #notifications)
	end)

	it("reject keeps user-modified content and classifies as rejected", function()
		local path = vim.fn.tempname()
		write_disk(path, "original\n")

		local estate = add_edit("gate_4", {
			filePath = path,
			before = "original\n",
			after = "proposed\n",
			type = "update",
		})

		write_disk(path, "user edits\n")

		local ok = edit_state.reject_file("gate_4", 1)
		assert.is_true(ok)
		assert.equals("user edits\n", read_disk(path))
		assert.equals("rejected", estate.files[1].status)
		assert.is_true(#notifications > 0)
	end)

	it("reject of a new file keeps user-populated content", function()
		local path = vim.fn.tempname()

		local estate = add_edit("gate_5", {
			filePath = path,
			before = "",
			after = "proposed\n",
			type = "add",
		})

		write_disk(path, "user content\n")

		local ok = edit_state.reject_file("gate_5", 1)
		assert.is_true(ok)
		assert.equals("user content\n", read_disk(path))
		assert.equals("rejected", estate.files[1].status)
		assert.is_true(#notifications > 0)
	end)

	it("accept re-adds the BOM when the proposal carries one", function()
		local path = vim.fn.tempname()
		write_disk(path, BOM .. "line1\n")

		local estate = add_edit("gate_6", {
			filePath = path,
			before = "line1\n",
			after = "line1\nbom kept\n",
			type = "update",
			bom = true,
		})

		local ok = edit_state.accept_file("gate_6", 1)
		assert.is_true(ok)
		assert.equals(BOM .. "line1\nbom kept\n", read_disk(path))
		assert.equals("accepted", estate.files[1].status)
	end)
end)
