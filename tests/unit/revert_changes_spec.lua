local changes = require("opencode.artifact.changes")
local edits = require("opencode.edit.state")
local app = require("opencode.state")
local actions = require("opencode.actions")

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes))
	assert(file:close())
end

local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local bytes = assert(file:read("*all"))
	assert(file:close())
	return bytes
end

local function revert_action()
	local commands = {}
	require("opencode.ui.palette.actions").register({
		register = function(command) commands[command.id] = command end,
	})
	return assert(commands["action.revert"]).action
end

describe("Revert Changes palette safety", function()
	local root, old_select, old_notify, old_remove, old_reply, modified_buf
	local choices, prompts, notices

	local function tracked(id, name, before, after, kind, opts)
		local path = root .. "/" .. name
		if kind ~= "add" and kind ~= "create" and kind ~= "new" then write(path, before) end
		local review = edits.add_edit(id, "session", {
			{ fileID = name, filePath = path, before = before, after = after, type = kind },
		}, opts)
		return path, review
	end

	local function choose(...)
		choices = { ... }
		revert_action()()
	end

	before_each(function()
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		changes.setup({ auto_backup = false })
		changes.clear()
		edits.clear_all()
		old_select, old_notify, old_remove, old_reply = vim.ui.select, vim.notify, os.remove, actions.reply_review
		choices, prompts, notices = {}, {}, {}
		vim.ui.select = function(_, opts, callback)
			table.insert(prompts, opts.prompt)
			callback(table.remove(choices, 1))
		end
		vim.notify = function(message) table.insert(notices, message) end
	end)

	after_each(function()
		vim.ui.select, vim.notify, os.remove, actions.reply_review = old_select, old_notify, old_remove, old_reply
		if modified_buf and vim.api.nvim_buf_is_valid(modified_buf) then
			vim.api.nvim_buf_delete(modified_buf, { force = true })
		end
		modified_buf = nil
		edits.clear_all()
		changes.clear()
		changes.setup({})
		app.reset()
		vim.fn.delete(root, "rf")
	end)

	it("preserves later edits by default and requires a second confirmation to overwrite them", function()
		local path, review = tracked("update", "update", "before\n", "proposal\n", "update")
		write(path, "manual\n")
		choose("Revert safely (keep later edits)")
		assert.equals("manual\n", read(path))
		assert.equals("pending", review.files[1].status)
		assert.is_truthy(notices[#notices]:find("Preserved files changed since review", 1, true))

		choose("Force overwrite changed files...", "Cancel")
		assert.equals("manual\n", read(path))
		assert.is_truthy(prompts[#prompts]:find("Are you sure?", 1, true))

		choose("Force overwrite changed files...", "Yes, overwrite or delete current files")
		assert.equals("before\n", read(path))
		assert.equals("rejected", review.files[1].status)
		assert.equals(0, #changes.get_pending())
	end)

	it("removes added files, preserves changed ones, and reports partial failures", function()
		local first, first_review = tracked("first", "first", "", "proposal\n", "create")
		write(first, "manual\n")
		choose("Revert safely (keep later edits)")
		assert.equals("manual\n", read(first))
		assert.equals("pending", first_review.files[1].status)

		write(first, "proposal\n")
		local second, second_review = tracked("second", "second", "", "proposal\n", "new")
		write(second, "proposal\n")
		os.remove = function(path)
			if path == second then return nil, "permission denied" end
			return old_remove(path)
		end
		choose("Revert safely (keep later edits)")
		assert.is_nil(read(first))
		assert.equals("proposal\n", read(second))
		assert.equals("rejected", first_review.files[1].status)
		assert.equals("pending", second_review.files[1].status)
		assert.is_truthy(notices[#notices]:find("Reverted 1 of 2", 1, true))
		assert.is_truthy(notices[#notices]:find("permission denied", 1, true))

		os.remove = old_remove
		write(second, "manual\n")
		choose("Force overwrite changed files...", "Yes, overwrite or delete current files")
		assert.is_nil(read(second))
		assert.equals(0, #changes.get_pending())
	end)

	it("protects unsaved buffers and symbolic links even in force mode", function()
		local path, review = tracked("protected", "protected", "before\n", "proposal\n", "update")
		write(path, "proposal\n")
		modified_buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(modified_buf, path)
		vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, { "unsaved manual edit" })
		choose("Force overwrite changed files...", "Yes, overwrite or delete current files")
		assert.equals("proposal\n", read(path))
		assert.is_truthy(notices[#notices]:find("unsaved buffer changes", 1, true))
		vim.api.nvim_buf_delete(modified_buf, { force = true })
		modified_buf = nil

		local target = root .. "/target"
		write(target, "proposal\n")
		assert(os.remove(path))
		assert(vim.uv.fs_symlink(target, path))
		choose("Revert safely (keep later edits)")
		assert.is_truthy(notices[#notices]:find("Path is now a link", 1, true))
		choose("Force overwrite changed files...", "Yes, overwrite or delete current files")
		assert.equals("link", vim.fn.getftype(path))
		assert.equals("proposal\n", read(target))
		assert.equals("pending", review.files[1].status)
	end)

	it("restores a deleted file after its review widget is cleared", function()
		local path = tracked("orphan", "deleted", "before\n", "", "remove")
		assert(os.remove(path))
		edits.clear_all()
		choose("Revert safely (keep later edits)")
		assert.equals("before\n", read(path))
		assert.equals(0, #changes.get_pending())
	end)

	it("does not copy a proposal BOM into the restored original", function()
		local path = root .. "/bom"
		write(path, "before\n")
		edits.add_edit("bom", "session", {
			{ filePath = path, before = "before\n", after = "proposal\n", type = "update", bom = true },
		})
		write(path, "\239\187\191proposal\n")
		choose("Revert safely (keep later edits)")
		assert.equals("before\n", read(path))
	end)

	it("reports a review reply failure separately from a successful local revert", function()
		app.set_connection("connected")
		app.set_config({ server = { shared_filesystem = true } })
		local path, review = tracked("rpc", "review", "before\n", "proposal\n", "update", {
			transport = "review_rpc", revision = 1, location = { directory = root },
		})
		write(path, "proposal\n")
		actions.reply_review = function() return false end
		choose("Revert safely (keep later edits)")
		assert.equals("before\n", read(path))
		assert.equals("rejected", review.files[1].status)
		assert.equals("pending", review.status)
		assert.is_truthy(notices[#notices]:find("Reverted 1 of 1", 1, true))
		assert.is_truthy(notices[#notices]:find("Review reply not sent", 1, true))
	end)
end)
