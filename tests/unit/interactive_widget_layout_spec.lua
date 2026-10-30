-- The question, permission and edit widgets share one panel layout and vocabulary.
local question_widget = require("opencode.ui.question_widget")
local permission_widget = require("opencode.ui.permission_widget")
local edit_widget = require("opencode.ui.edit_widget")
local widget_base = require("opencode.ui.widget_base")

local function trimmed(lines)
	local out = {}
	for _, line in ipairs(lines) do out[#out + 1] = (line:gsub("%s+$", "")) end
	return out
end

local function text(lines) return table.concat(trimmed(lines), "\n") end

local function highlighted(lines, highlights, group)
	for _, hl in ipairs(highlights) do
		if hl.hl_group == group then return lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end) end
	end
end

local function has_highlight(lines, highlights, group, span)
	for _, hl in ipairs(highlights) do
		if hl.hl_group == group and lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end) == span then return true end
	end
	return false
end

---No two blank panel rows in a row, and the panel closes with a blank row and the "" separator.
local function assert_panel(lines)
	local rows = trimmed(lines)
	assert.equals("▏", rows[1])
	assert.equals("", rows[#rows])
	assert.equals("▏", rows[#rows - 1])
	for i = 2, #rows do
		assert.is_false(rows[i] == "▏" and rows[i - 1] == "▏", "double blank row at " .. i .. ":\n" .. table.concat(rows, "\n"))
	end
end

describe("interactive widget layout", function()
	it("keeps one blank row between the question header and its options", function()
		local lines = question_widget.get_lines_for_question("q", { questions = {
			{ header = "Pick one", question = "Pick one", options = { { label = "Yes" }, { label = "No" } } },
		} }, { current_tab = 1, selections = {} }, "pending", { width = 80 })
		assert_panel(lines)
		local rows = trimmed(lines)
		assert.same({ "▏", "▏  # Question Pick one", "▏", "▏    1. Yes" }, { rows[1], rows[2], rows[3], rows[4] })
	end)

	it("frames a form that has no visible question yet", function()
		local lines = question_widget.get_lines_for_question("q", { questions = {} },
			{ current_tab = 1, selections = {}, form = { title = "Setup" } }, "pending", { width = 80 })
		assert_panel(lines)
		assert.is_truthy(text(lines):find("▏  # Question Setup\n▏\n▏  <CR> review form defaults", 1, true))
	end)

	it("states question progress as lowercase parenthesized suffixes", function()
		local data = { questions = { { header = "History", question = "Pick", options = { { label = "Red" } } } } }
		local answered = text((question_widget.get_answered_lines("q", data, { { "Red" } }, { width = 80 })))
		assert.is_truthy(answered:find("▏  # Question (answered)\n▏\n▏  History: Red", 1, true))
		local cancelled = question_widget.get_rejected_lines("q", data, { width = 80 })
		assert_panel(cancelled)
		assert.is_truthy(text(cancelled):find("▏  # Question History (cancelled)", 1, true))
		local submitting = text((question_widget.get_submitting_lines("q", data, { current_tab = 1 }, { width = 80 })))
		assert.is_truthy(submitting:find("# Question History (submitting)\n▏\n▏  Submitting answer…", 1, true))
		local confirm, highlights = question_widget.get_confirmation_lines("q", data,
			{ selections = { { selected_indices = { 1 }, is_answered = true } } }, { width = 80 })
		assert_panel(confirm)
		assert.is_truthy(text(confirm):find("▏  # Question (ready to submit)", 1, true))
		assert.is_truthy(text(confirm):find("<CR> continue · <Esc> back to questions", 1, true))
		assert.equals("❯", highlighted(confirm, highlights, "OpenCodeQuestionSelectedMarker"))
	end)

	it("marks a selected custom answer like any other option", function()
		local lines, highlights = question_widget.get_lines_for_question("q", { questions = {
			{ header = "Name", question = "Your name?", custom = true, options = {} },
		} }, { current_tab = 1, selections = { { custom_present = true, custom_input = "Ada" } } }, "pending", { width = 80 })
		assert.is_truthy(text(lines):find("❯ Custom: Ada", 1, true))
		assert.equals("❯", highlighted(lines, highlights, "OpenCodeQuestionSelectedMarker"))
		local unselected, unselected_hl = question_widget.get_lines_for_question("q", { questions = {
			{ header = "Name", question = "Your name?", custom = true, options = {} },
		} }, { current_tab = 1, selections = {} }, "pending", { width = 80 })
		assert.is_truthy(text(unselected):find("Custom answer…", 1, true))
		-- The row takes the option colour; only its "▏" border is muted.
		for _, hl in ipairs(unselected_hl) do
			if unselected[hl.line + 1]:find("Custom answer", 1, true) and hl.col_end > #"▏  " then
				assert.equals("OpenCodeQuestionOutput", hl.hl_group)
			end
		end
	end)

	it("gives only the tool name the permission title highlight", function()
		local lines, highlights = permission_widget.render({
			permission_id = "p", permission_type = "external_directory", status = "pending", selected_option = 1,
			tool_name = "read", patterns = { "/srv/data/*" }, always = { "*" },
		}, { width = 80 })
		assert.is_truthy(text(lines):find("▏  # Permission required for Read", 1, true))
		assert.equals("Read", highlighted(lines, highlights, "OpenCodePermissionTitle"))
	end)

	it("names the permission in the always-allow preview, never its identifier", function()
		local rendered = text((permission_widget.render({
			permission_id = "p", permission_type = "external_directory", status = "pending", selected_option = 2,
			tool_name = "read", patterns = { "/srv/data/*" }, always = { "*" },
		}, { width = 80 })))
		assert.is_truthy(rendered:find("This will always allow External directory for this project.", 1, true))
		assert.is_nil(rendered:find("external_directory", 1, true))
	end)

	it("closes a submitting permission panel and puts errors after the options", function()
		local base = { permission_id = "p", permission_type = "read", status = "pending", selected_option = 2,
			tool_name = "read", patterns = { "/srv/a.txt" }, always = { "*" } }
		local submitting = permission_widget.render(vim.tbl_extend("force", base, { submitting = true }), { width = 80 })
		assert_panel(submitting)
		assert.is_truthy(text(submitting):find("# Permission required for Read (submitting)", 1, true))
		local failed, _, meta = permission_widget.render(vim.tbl_extend("force", base,
			{ selected_option = 1, error = { message = "Server refused" } }), { width = 80 })
		assert_panel(failed)
		assert.is_truthy(text(failed):find("3. Reject\n▏\n▏  Server refused\n▏  1-3 select", 1, true))
		assert.equals(meta.option_lines[1], widget_base.get_focus_offset(meta))
		local _, _, second = permission_widget.render(vim.tbl_extend("force", base, { selected_option = 2 }), { width = 80 })
		assert.equals(second.option_lines[2], widget_base.get_focus_offset(second))
	end)

	it("numbers edit files like options and lists the review keys", function()
		local edit = { permission_id = "e", status = "pending", selected_file = 2, message = "first\nsecond", files = {
			{ filepath = "/srv/a.txt", stats = { added = 3, removed = 1 }, status = "pending" },
			{ filepath = "/srv/b.txt", stats = { added = 0, removed = 2 }, status = "pending" },
		} }
		local lines, highlights, meta = edit_widget.render(edit, { width = 120 })
		assert_panel(lines)
		local rendered = text(lines)
		assert.is_truthy(rendered:find("▏  Message: first\n▏           second", 1, true))
		assert.is_truthy(rendered:find("▏    1.   M /srv/a.txt · +3 -1\n▏  ❯ 2.   M /srv/b.txt · +0 -2", 1, true))
		assert.is_truthy(rendered:find("<C-a> accept · <C-x> reject · <C-m> resolve · = diff · m message", 1, true))
		assert.equals("❯", highlighted(lines, highlights, "OpenCodeEditSelectedMarker"))
		assert.is_true(has_highlight(lines, highlights, "OpenCodeEditMuted", "Message: "))
		assert.equals(meta.file_ranges[2].start_line, widget_base.get_focus_offset(meta))

		edit.submitting = true
		local sending = text((edit_widget.render(edit, { width = 120 })))
		assert.is_truthy(sending:find("# Edit 2 files · +3 -3 (submitting)", 1, true))
		assert.is_nil(sending:find("❯", 1, true))
		assert.is_nil(sending:find("accept", 1, true))
	end)
end)
