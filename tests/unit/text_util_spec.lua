local text = require("opencode.util.text")

describe("shared text helpers", function()
	it("fits Unicode and suffixes into display cells without splitting characters", function()
		for _, value in ipairs({ "abcdef", "Привет мир", "界界界界", "éééé", "🙂🙂🙂", "a\tb" }) do
			for _, suffix in ipairs({ "", "...", "…" }) do
				for width = 0, 12 do
					local result = text.truncate(value, width, suffix)
					assert.is_true(vim.fn.strdisplaywidth(result) <= width)
					assert.is_true(vim.fn.strchars(result) <= vim.fn.strchars(value .. suffix))
					if vim.fn.strdisplaywidth(value) <= width and width > 0 then assert.equals(value, result) end
				end
			end
		end
		assert.equals("界…", text.truncate("界界界", 4, "…"))
		assert.equals("ab...", text.truncate("abcdef", 5, "..."))
		assert.equals("..", text.truncate("abcdef", 2, "..."))
		assert.equals("", text.truncate(nil, 5))
		assert.equals("", text.truncate("abc", -1))
	end)

	it("strips BEL and ST terminated OSC without swallowing visible text", function()
		local esc, bel = string.char(27), string.char(7)
		local st = esc .. "\\"
		for _, opening in ipairs({ bel, st }) do
			for _, closing in ipairs({ bel, st }) do
				local value = "before " .. esc .. "]8;;https://example.com" .. opening
					.. esc .. "[31mПривет\n界" .. esc .. "[0m" .. esc .. "]8;;" .. closing .. " after"
				assert.equals("before Привет\n界 after", text.strip_ansi(value))
			end
		end
		assert.equals("visible\\tail", text.strip_ansi(esc .. "]0;title" .. bel .. "visible\\tail"))
		assert.equals("plain\ntext", text.strip_ansi("plain\ntext"))
		assert.equals(esc .. "]0;unfinished", text.strip_ansi(esc .. "]0;unfinished"))
	end)

	it("counts changes across diff files and accepts missing output", function()
		local diff = "--- a/file\n+++ b/file\n@@ -1,2 +1,2 @@\n-old\n+new\n same\n"
			.. "--- /dev/null\n+++ b/new\n@@ -0,0 +1 @@\n+created"
		assert.same({ 2, 1 }, { text.diff_stats(diff) })
		assert.same({ 0, 0 }, { text.diff_stats(nil) })
		assert.same({ 0, 0 }, { text.diff_stats(42) })
		assert.same({ 0, 0 }, { text.diff_stats("") })
	end)

	it("uses the same cell offsets for multiline native mention round trips", function()
		assert.equals(0, text.display_cells(""))
		assert.equals(7, text.display_cells("界\n🙂\na"))
		assert.equals(2, text.display_cells("a\n"))
		assert.equals(1, text.display_cells("é"))
	end)

	it("counts header-like content inside hunks without counting later file headers", function()
		local diff = "--- a/file\n+++ b/file\n@@ -1 +1 @@\n--- old content\n+++ new content\n"
			.. "--- /dev/null\n+++ b/new\n@@ -0,0 +1,2 @@\n+++ second\n+tail\n"
		assert.same({ 3, 1 }, { text.diff_stats(diff) })
		assert.same({ 1, 1 }, { text.diff_stats("-old\n+new") })
	end)
end)
