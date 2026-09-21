describe("opencode edit review storage", function()
	local changes = require("opencode.artifact.changes")
	local edits = require("opencode.edit.state")
	local root
	local function write(path, content)
		local file = assert(io.open(path, "wb"))
		assert(file:write(content))
		assert(file:close())
	end
	local function read(path)
		local file = assert(io.open(path, "rb"))
		local content = file:read("*all")
		file:close()
		return content
	end
	before_each(function()
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		changes.setup({ auto_backup = false })
		changes.clear()
		edits.clear_all()
	end)
	after_each(function()
		edits.clear_all()
		changes.clear()
		changes.setup({})
		vim.fn.delete(root, "rf")
	end)

	it("can accept every file in a patch larger than the history budget", function()
		local files = {}
		for index = 1, 101 do
			files[index] = { filePath = root .. "/" .. index, before = "", after = "new\n", type = "add" }
		end
		edits.add_edit("large", "session", files)
		assert.is_true(edits.accept_all("large"))
		assert.equals("all_accepted", edits.get_resolution("large"))
		for _, file in ipairs(files) do assert.equals("new\n", read(file.filePath)) end
	end)

	it("trims resolved history without evicting an older pending review", function()
		changes.setup({ auto_backup = false, max_changes = 2 })
		local pending = changes.add_change(root .. "/pending", "", "proposed")
		local resolved = {}
		for index = 1, 4 do
			resolved[index] = changes.add_change(root .. "/resolved" .. index, "", "value")
			assert.is_true(changes.resolve_manually(resolved[index]))
		end
		assert.is_not_nil(changes.get(pending))
		assert.equals(3, #changes.get_all())
		assert.is_nil(changes.get(resolved[1]))
		assert.is_not_nil(changes.get(resolved[4]))
		assert.is_true(changes.accept(pending))
		assert.equals("proposed", read(root .. "/pending"))
	end)

	for _, content in ipairs({ "", "original\n" }) do
		it("deletes an accepted file with content " .. vim.inspect(content), function()
			local path = root .. "/delete"
			write(path, content)
			edits.add_edit("delete", "session", { { filePath = path, before = content, after = "", type = "delete" } })
			assert.is_true(edits.accept_file("delete", 1))
			assert.equals(0, vim.fn.filereadable(path))
			assert.equals("all_accepted", edits.get_resolution("delete"))
		end)
	end

	it("rejecting a deletion restores an already removed file", function()
		local path = root .. "/restore"
		write(path, "original\n")
		edits.add_edit("restore", "session", { { filePath = path, before = "original\n", after = "", type = "delete" } })
		assert(os.remove(path))
		assert.is_true(edits.reject_file("restore", 1))
		assert.equals("original\n", read(path))
	end)

	it("restores the original BOM independently from the proposed BOM", function()
		local path = root .. "/bom"
		write(path, "before\n")
		edits.add_edit("bom", "session", { {
			filePath = path, before = "before\n", after = "after\n", type = "update", bom = true, before_bom = false,
		} })
		write(path, "\xEF\xBB\xBFafter\n")
		assert.is_true(edits.reject_file("bom", 1))
		assert.equals("before\n", read(path))
	end)
end)
