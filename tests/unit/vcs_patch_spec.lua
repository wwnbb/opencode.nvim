local vcs = require("opencode.vcs")

describe("read-only VCS patch projection", function()
	it("pairs replacements and preserves context and multiple hunk line numbers", function()
		local rows, err = vcs.project(table.concat({ "--- a/a.lua", "+++ b/a.lua", "@@ -2,3 +2,4 @@ example",
			" same", "-old", "+new", "+extra", " end", "@@ -20 +21 @@", "-other", "+changed", "" }, "\n"))
		assert.is_nil(err)
		assert.same({ before = "same", after = "same", before_line = 2, after_line = 2, kind = "context" }, rows[4])
		assert.same({ before = "old", after = "new", before_line = 3, after_line = 3, kind = "change" }, rows[5])
		assert.same({ before = "", after = "extra", after_line = 4, kind = "change" }, rows[6])
		assert.equals(4, rows[7].before_line); assert.equals(5, rows[7].after_line)
		assert.is_true(rows[8].hunk)
		assert.equals(20, rows[9].before_line); assert.equals(21, rows[9].after_line)
	end)

	it("projects added and deleted files with zero ranges and implicit one-line counts", function()
		local added = assert(vcs.project("@@ -0,0 +1,2 @@\n+first\n+second\n"))
		assert.equals(3, #added)
		assert.is_nil(added[2].before_line); assert.equals(1, added[2].after_line)
		assert.is_nil(added[3].before_line); assert.equals(2, added[3].after_line)
		local deleted = assert(vcs.project("@@ -1 +0,0 @@\n-last\n"))
		assert.equals(2, #deleted)
		assert.equals(1, deleted[2].before_line); assert.is_nil(deleted[2].after_line)
	end)

	it("keeps no-newline markers with the corresponding side of the replacement", function()
		local rows = assert(vcs.project("@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"))
		assert.equals(3, #rows)
		assert.equals("old", rows[2].before); assert.equals("new", rows[2].after)
		assert.same({ before = "\\ No newline at end of file", after = "\\ No newline at end of file", kind = "meta" }, rows[3])
		local context = assert(vcs.project("@@ -1 +1 @@\n same\n\\ No newline at end of file\n"))
		assert.equals("context", context[2].kind)
		assert.equals("\\ No newline at end of file", context[3].before)
	end)

	it("rejects truncated, overflowing, malformed, and combined hunks", function()
		for _, text in ipairs({ "@@ -1,2 +1 @@\n-old\n+new", "@@ -1 +1 @@\n-old\n+new\n+overflow",
			"@@ -1 +1 @@\n?invalid", "@@ -1 +1 @@\n-old\n@@ -5 +5 @@\n-x\n+y", "@@ -x +1 @@", "@@@ -1 -1 +1 @@@" }) do
			local rows, err = vcs.project(text)
			assert.is_nil(rows, text); assert.is_string(err)
		end
	end)

	it("preserves binary metadata and represents empty patches explicitly", function()
		local rows = assert(vcs.project("diff --git a/image.png b/image.png\nBinary files differ\n"))
		assert.equals("Binary files differ", rows[2].after)
		assert.equals("meta", rows[2].kind)
		assert.equals("No textual patch", assert(vcs.project(""))[1].after)
	end)

	it("accepts native patch DTOs without before/after and rejects invalid data without mutating input", function()
		local source = { { file = "a.lua", patch = "", status = "modified", additions = 0, deletions = 0 } }
		local copy = assert(vcs.files(source))
		copy[1].file = "changed"
		assert.equals("a.lua", source[1].file)
		for _, bad in ipairs({ { key = "status", value = "unknown" }, { key = "file", value = "" }, { key = "patch", value = false },
			{ key = "additions", value = -1 }, { key = "deletions", value = 0.5 }, { key = "additions", value = math.huge } }) do
			local invalid = vim.deepcopy(source); invalid[1][bad.key] = bad.value
			assert.is_nil(vcs.files(invalid))
		end
		assert.is_nil(vcs.files({ unexpected = true }))
	end)
end)
