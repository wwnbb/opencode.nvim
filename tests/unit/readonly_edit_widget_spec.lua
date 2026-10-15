local edits = require("opencode.edit.state")
local widget = require("opencode.ui.edit_widget")

describe("read-only edit widget", function()
	before_each(function() edits.clear_all() end)
	after_each(function() edits.clear_all() end)

	local function render(files)
		local edit = edits.add_edit("preview", "session", files, {
			review_mode = "readonly", status = "sent", file_statuses = { "accepted", "accepted" },
		})
		return table.concat(widget.get_resolved_lines("preview", edit), "\n"), edit
	end

	it("labels completed previews as applied and retains the recorded diff", function()
		local text, edit = render({ { filePath = "file.txt", diff = "@@ -1 +1 @@\n-before\n+after" } })
		assert.is_truthy(text:find("(applied)", 1, true))
		assert.is_nil(text:find("(approved)", 1, true))
		assert.is_truthy(text:find("+1 -1", 1, true))
		edits.toggle_inline_diff("preview", 1)
		text = table.concat(widget.get_resolved_lines("preview", edit), "\n")
		assert.is_truthy(text:find("before", 1, true))
		assert.is_truthy(text:find("after", 1, true))
	end)

	it("shows unavailable diffs instead of fabricated zero counts", function()
		local text = render({ { filePath = "unknown.txt" } })
		assert.is_truthy(text:find("Diff unavailable", 1, true))
		assert.is_nil(text:find("+0 -0", 1, true))
		assert.is_truthy(text:find("# Edit unknown.txt (applied)", 1, true))
	end)

	it("omits incomplete totals but preserves counts for known files", function()
		local text = render({
			{ filePath = "known.txt", diff = "@@ -1 +1 @@\n-before\n+after" },
			{ filePath = "unknown.txt" },
		})
		assert.is_truthy(text:find("# Edit 2 files (applied)", 1, true))
		assert.is_truthy(text:find("known.txt  +1 -1", 1, true))
		assert.is_truthy(text:find("unknown.txt  Diff unavailable", 1, true))
	end)

	it("preserves supplied counts while explaining an unavailable expanded diff", function()
		local _, edit = render({ { filePath = "counted.txt", additions = 4, deletions = 2 } })
		edits.toggle_inline_diff("preview", 1)
		local text = table.concat(widget.get_resolved_lines("preview", edit), "\n")
		assert.is_truthy(text:find("+4 -2", 1, true))
		assert.is_truthy(text:find("Diff unavailable", 1, true))
	end)

	it("preserves explicit empty diffs and interactive review labels", function()
		local _, edit = render({ { filePath = "empty.txt", diff = "" } })
		edits.toggle_inline_diff("preview", 1)
		local text = table.concat(widget.get_resolved_lines("preview", edit), "\n")
		assert.is_truthy(text:find("+0 -0", 1, true))
		assert.is_nil(text:find("Diff unavailable", 1, true))
		edit.review_mode = "interactive"
		text = table.concat(widget.get_resolved_lines("preview", edit), "\n")
		assert.is_truthy(text:find("(approved)", 1, true))
		assert.is_truthy(text:find("+0 -0", 1, true))
	end)
end)
