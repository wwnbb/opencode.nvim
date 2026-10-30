describe("edit tool result normalization", function()
	local tool_results = require("opencode.edit.tool_results")

	it("accepts every path, diff and stats spelling for multi-file patches", function()
		local model = tool_results.normalize_model({
			tool = "apply_patch",
			state = {
				status = "completed",
				metadata = {
					files = {
						{ filePath = "a.lua", diff = "@@ -1 +1 @@\n-a\n+b\n" },
						{ filepath = "b.lua", patch = "@@ -1 +1,2 @@\n a\n+c\n", type = "created" },
						{ file_path = "c.lua", added = "4", removed = 1, status = "rejected" },
						{ file = "d.lua", stats = { added = 2, removed = "3" }, move_path = "e.lua", type = "renamed" },
						{ path = "f.lua", relative_path = "rel/f.lua", status = "partially_applied" },
					},
				},
			},
		})
		assert.same({ "a.lua", "b.lua", "c.lua", "d.lua", "f.lua" }, vim.tbl_map(function(file)
			return file.filePath
		end, model.files))
		assert.same({ 1, 1 }, { model.files[1].additions, model.files[1].deletions })
		assert.same({ "add", 1, 0 }, { model.files[2].type, model.files[2].additions, model.files[2].deletions })
		assert.same({ "rejected", 4, 1 }, { model.files[3].status, model.files[3].additions, model.files[3].deletions })
		assert.same({ "move", "e.lua", 2, 3 }, { model.files[4].type, model.files[4].movePath, model.files[4].additions,
			model.files[4].deletions })
		assert.same({ "rel/f.lua", "partial" }, { model.files[5].relativePath, model.files[5].status })
		assert.equals("partial", model.status)
		assert.is_false(model.hasProposed)
	end)

	it("pairs neovim_patch proposals by path, display path or index", function()
		local model = tool_results.normalize_model({
			tool = "neovim_patch",
			state = {
				status = "completed",
				metadata = {
					status = "applied",
					files = { { filePath = "x.lua" }, { filePath = "y.lua" } },
					proposed_files = { { path = "x.lua", diff = "px" }, { proposed_diff = "py" } },
				},
			},
		})
		assert.same({ "px", "py" }, { model.files[1].proposedDiff, model.files[2].proposedDiff })
		assert.is_true(model.hasProposed)
		assert.equals("applied", model.status)
	end)
end)
