local changes = require("opencode.artifact.changes")

describe("tracked change statistics", function()
	local original_text_diff

	local function stats(before, after, file_type)
		local id = changes.add_change(vim.fn.tempname(), before, after, { file_type = file_type })
		return changes.get(id).stats
	end

	before_each(function()
		original_text_diff = vim.text and vim.text.diff
		changes.setup({ auto_backup = false })
		changes.clear()
	end)

	after_each(function()
		if vim.text then vim.text.diff = original_text_diff end
		changes.clear()
		changes.setup({})
	end)

	it("counts changed lines without treating shifted or empty lines as changes", function()
		for _, case in ipairs({
			{ "old\n", "new\n", 1, 1 },
			{ "a\nb\nc\n", "x\na\nb\nc\n", 1, 0 },
			{ "a\nb\nc\n", "a\nx\nb\nc\n", 1, 0 },
			{ "a\nb\nc\n", "a\nc\n", 0, 1 },
			{ "", "", 0, 0, "add" },
			{ "", "a\nb\n", 2, 0, "add" },
			{ "a\nb\n", "", 0, 2, "delete" },
			{ "", "a", 1, 0, "add" },
			{ "a", "a\n", 1, 1 },
			{ "a\n", "a", 1, 1 },
			{ "a\n", "a\n", 0, 0 },
		}) do
			assert.same({ added = case[3], removed = case[4] }, stats(case[1], case[2], case[5]), vim.inspect(case))
		end
	end)

	it("includes pending changes and excludes resolved changes from public status", function()
		stats("old\n", "new\n")
		stats("", "a\nb\n", "add")
		local resolved = changes.add_change(vim.fn.tempname(), "a\nb\n", "", { file_type = "delete" })
		assert.is_true(changes.resolve_manually(resolved))
		assert.same({ total_files = 2, total_additions = 3, total_deletions = 1 },
			require("opencode").get_status().diff_stats)
	end)

	it("uses the native diff compatibility API when vim.text.diff is unavailable", function()
		if vim.text then vim.text.diff = nil end
		assert.same({ added = 1, removed = 1 }, stats("old\n", "new\n"))
		assert.same({ added = 1, removed = 0 }, stats("a\nb\nc\n", "a\nx\nb\nc\n"))
	end)
end)
