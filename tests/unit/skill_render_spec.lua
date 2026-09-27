local skill = require("opencode.ui.chat.skill")
local render = require("opencode.ui.chat.render")
local style = require("opencode.ui.chat.tool_style")
local syntax = require("opencode.ui.syntax")
local sync = require("opencode.sync")
local view = require("opencode.ui.chat.state").state

local function part(state)
	return { id = "skill-1", type = "tool", tool = "skill", state = state }
end

local function text(result)
	return table.concat(result.lines, "\n")
end

local function contains(value, expected)
	assert.is_truthy(value:find(expected, 1, true), "Missing " .. vim.inspect(expected) .. " in " .. vim.inspect(value))
end

local function body_text(result)
	local lines = {}
	for _, line in ipairs(result.lines) do
		if line:sub(1, #"   │") == "   │" then
			lines[#lines + 1] = line:gsub("^   │ ?", ""):gsub(" +$", "")
		end
	end
	return table.concat(lines, "\n")
end

local function native_output(name, body)
	return table.concat({
		'<skill_content name="' .. name .. '">', '# Skill: ' .. name, "", body, "",
		"Base directory for this skill: /tmp/skills/review",
		"Relative paths in this skill (e.g., scripts/, reference/) are relative to this base directory.",
		"Note: file list is sampled.", "", "<skill_files>",
		"<file>/tmp/skills/review/scripts/check.lua</file>", "<file>/tmp/skills/review/reference/notes.md</file>",
		"</skill_files>", "</skill_content>",
	}, "\n")
end

describe("skill list rendering", function()
	local old_winid, old_frame, old_columns, old_catalog, old_highlight, bufnr, winid
	before_each(function()
		old_winid, old_frame, old_columns = view.winid, view.task_anim_frame, vim.o.columns
		old_catalog, old_highlight = sync.get_skills, syntax.highlight_text
		sync.get_skills = function() return {} end
		vim.o.columns = 120
		bufnr = vim.api.nvim_create_buf(false, true)
		winid = vim.api.nvim_open_win(bufnr, false, { relative = "editor", row = 0, col = 0, width = 100, height = 10 })
		view.winid, view.task_anim_frame = winid, 1
	end)

	after_each(function()
		view.winid, view.task_anim_frame = old_winid, old_frame
		sync.get_skills, syntax.highlight_text = old_catalog, old_highlight
		vim.api.nvim_win_close(winid, true)
		vim.api.nvim_buf_delete(bufnr, { force = true })
		vim.o.columns = old_columns
	end)

	it("keeps all details folded into one row and opens a shared frame with rendered Markdown", function()
		local body = table.concat({ "---", 'description: "Review Lua changes"', "---", "# Instructions", "",
			"**Check invariants** before making changes.", "", "- Keep the public API stable." }, "\n")
		local item = part({ status = "completed", input = { name = "review" }, output = native_output("review", body) })
		local snapshot = vim.deepcopy(item)
		local closed, opened = skill.render_tool(item, false), skill.render_tool(item, true)
		assert.equals(1, #closed.lines)
		assert.equals(' → Skill "review"', closed.lines[1]:gsub(" +$", ""))
		assert.equals(closed.lines[1]:gsub("→", "↘"), opened.lines[1])
		assert.equals(style.header_hl, opened.highlights[1].hl_group)
		contains(opened.lines[2], "   ┌")
		contains(opened.lines[#opened.lines], "   └")
		local output = body_text(opened)
		contains(output, "Skill: review")
		contains(output, "Review Lua changes")
		contains(output, "Base: /tmp/skills/review")
		contains(output, "Files: 2 sampled")
		contains(output, "/tmp/skills/review/scripts/check.lua")
		contains(output, "/tmp/skills/review/reference/notes.md")
		contains(output, "Check invariants")
		assert.is_nil(output:find("<skill_content", 1, true))
		assert.is_nil(output:find("description:", 1, true))
		assert.is_nil(output:find("**Check invariants**", 1, true))
		assert.is_nil(output:find("1: Check invariants", 1, true))
		local emphasized = false
		for _, hl in ipairs(opened.highlights) do
			if hl.hl_group:find("Strong", 1, true) then
				contains(opened.lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end), "Check invariants")
				emphasized = true
			elseif hl.hl_group == style.output_hl or hl.hl_group == style.border_hl then
				assert.equals(3, hl.col_start)
			end
		end
		assert.is_true(emphasized)
		assert.same(snapshot, item)
	end)

	it("accepts native structured outputs and plain legacy Skill banners", function()
		for _, output in ipairs({
			{ name = "native-review", directory = "/tmp/native-review", output = "## Guide\n\nNative instructions." },
			"# Skill: native-review\n\nNative instructions.\n\nBase directory for this skill: /tmp/native-review",
		}) do
			local rendered = skill.render_tool(part({ status = "completed", output = output,
				time = { created = 1000, completed = 1250 } }), true)
			contains(rendered.lines[1], 'Skill "native-review"')
			contains(rendered.lines[1], "250ms")
			contains(body_text(rendered), "Native instructions.")
			contains(body_text(rendered), "Base: /tmp/native-review")
		end
	end)

	it("normalizes Windows output and renders instructions once when no description is given", function()
		local source = native_output("windows-review", "**Review carefully** before editing."):gsub("\n", "\r\n")
		local result = skill.render_tool(part({ status = "completed", output = source }), true)
		local output = body_text(result)
		contains(result.lines[1], 'Skill "windows-review"')
		contains(output, "Base: /tmp/skills/review")
		contains(output, "Review carefully before editing.")
		assert.is_nil(output:find("\r", 1, true))
		assert.is_nil(output:find("**Review carefully**", 1, true))
		local _, occurrences = output:gsub("Review carefully", "")
		assert.equals(1, occurrences)
	end)

	it("keeps the full Unicode name in the body while headers stay on one row", function()
		local name = string.rep("世界Ж", 30) .. "_TAIL"
		for _, width in ipairs({ 100, 24, 12 }) do
			vim.api.nvim_win_set_config(winid, { width = width })
			local item = part({ status = "streaming", input = { name = name }, output = "Working instructions." })
			local closed, opened = skill.render_tool(item, false), skill.render_tool(item, true)
			assert.equals(1, #closed.lines)
			assert.equals("|", vim.trim(closed.lines[1]):sub(-1))
			contains(opened.lines[2], "   ┌")
			contains(body_text(opened):gsub("\n", ""), name)
			for _, line in ipairs(opened.lines) do
				assert.is_true(vim.fn.strdisplaywidth(line) <= width, "Overflow: " .. line)
			end
		end
	end)

	it("retains syntax highlights across wrapped fenced instructions without a gutter", function()
		local source = 'print("' .. string.rep("世界", 60) .. '")'
		syntax.highlight_text = function(value, language, opts)
			assert.equals(source, value)
			assert.equals("lua", language)
			assert.equals("tools", opts.scope)
			return { { line = 0, col_start = 0, col_end = #source, hl_group = "String" } }
		end
		local result = skill.render_tool(part({ status = "completed", input = { name = "code" },
			output = "# Example\n\n```lua\n" .. source .. "\n```" }), true)
		local captured = {}
		for _, hl in ipairs(result.highlights) do
			if hl.hl_group == "String" then
				assert.is_true(hl.col_start >= #style.prefix)
				captured[#captured + 1] = result.lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end)
			end
		end
		assert.is_true(#captured > 1)
		assert.equals(source, table.concat(captured))
		assert.is_nil(text(result):find("1: print", 1, true))
	end)

	it("uses catalog details and invalidates its cache when the selected skill changes", function()
		local catalog = { { name = "review", description = "Original description", location = "/tmp/original/SKILL.md" } }
		sync.get_skills = function() return catalog end
		local item = part({ status = "completed", input = { name = "review" } })
		local key = skill.cache_key(item)
		local first = skill.render_tool(item, true)
		contains(body_text(first), "Original description")
		contains(body_text(first), "Base: /tmp/original")
		catalog[1].description, catalog[1].location = "Updated description", "/tmp/updated/SKILL.md"
		assert.is_not_equal(key, skill.cache_key(item))
		local second = skill.render_tool(item, true)
		contains(body_text(second), "Updated description")
		contains(body_text(second), "Base: /tmp/updated")
		key = skill.cache_key(item)
		catalog[#catalog + 1] = { name = "unrelated", description = "Not shown", location = "/tmp/other/SKILL.md" }
		assert.equals(key, skill.cache_key(item))
	end)

	it("keeps full errors behind the folded row and stops animation for terminal failures", function()
		for _, status in ipairs({ "error", "cancelled", "canceled", "interrupted", "aborted" }) do
			local message = "Unable to load skill review\nTry an available skill."
			local item = part({ status = status, input = { name = "review" }, error = { message = message } })
			local closed, opened = skill.render_tool(item, false), skill.render_tool(item, true)
			assert.equals(1, #closed.lines)
			assert.equals(style.error_hl, closed.highlights[1].hl_group)
			contains(closed.lines[1], "Failed")
			assert.is_nil(closed.lines[1]:find("|", 1, true))
			contains(body_text(opened), message)
			for _, hl in ipairs(opened.highlights) do
				assert.is_not_equal("ErrorMsg", hl.hl_group)
				if hl.hl_group == style.body_error_hl then assert.equals(3, hl.col_start) end
			end
		end
	end)

	it("uses shared working policy for streaming, incomplete and timestamped states", function()
		for _, state in ipairs({ {}, { status = "pending" }, { status = "streaming" },
			{ status = "running", time = { completed = 2000 } } }) do
			state.input = { name = "review" }
			assert.equals("|", vim.trim(skill.render_tool(part(state), false).lines[1]):sub(-1))
		end
		local finished = skill.render_tool(part({ input = { name = "review" }, error = false,
			time = { start = 1000, completed = 2000 } }), true)
		contains(body_text(finished), "No instructions returned")
		assert.is_nil(finished.lines[1]:find("|", 1, true))
		assert.is_nil(text(finished):find("false", 1, true))
	end)

	it("handles incomplete and native null values without exposing them", function()
		assert.is_nil(skill.render_tool(nil, false))
		assert.is_nil(skill.render_tool({ tool = "read" }, false))
		for _, item in ipairs({
			{ tool = "skill" }, part({ status = "running", input = vim.NIL }),
			{ tool = "skill", state = vim.NIL, metadata = vim.NIL },
			part({ status = "completed", metadata = vim.NIL }),
			part({ status = "completed", input = { name = vim.NIL }, output = vim.NIL, error = vim.NIL }),
			part({ status = "error", input = "unfinished input", error = vim.NIL }),
		}) do
			for _, expanded in ipairs({ false, true }) do
				local rendered = skill.render_tool(item, expanded)
				contains(rendered.lines[1], "Skill")
				assert.is_nil(text(rendered):find("vim.NIL", 1, true))
			end
		end
	end)

	it("leaves attachment content unconfirmed without server text and never uses its UI id as a catalog id", function()
		sync.get_skills = function() return {
			{ id = "catalog-review", name = "Review changes", content = "CATALOG_INSTRUCTIONS", description = "CATALOG_DESCRIPTION" },
			{ id = "ui-part-1", name = "WRONG_SKILL" },
		} end
		for _, attachment in ipairs({
			{ type = "skill", id = "ui-part-1", skillID = "catalog-review" },
			{ type = "skill", id = "ui-part-1", skillID = "catalog-review", text = vim.NIL },
			{ type = "skill", id = "ui-part-1", skillID = "catalog-review", text = false },
		}) do
			local snapshot = vim.deepcopy(attachment)
			local closed, opened = skill.render_attachment(attachment, false), skill.render_attachment(attachment, true)
			assert.equals(1, #closed.lines)
			contains(closed.lines[1], 'Skill "Review changes" · Unconfirmed')
			assert.is_nil(closed.lines[1]:find("|", 1, true))
			contains(body_text(opened), "Skill instructions are not available in this message")
			assert.is_nil(text(opened):find("CATALOG_", 1, true))
			assert.is_nil(text(opened):find("WRONG_SKILL", 1, true))
			assert.same(snapshot, attachment)
		end
		local fallback = skill.render_attachment({ type = "skill", id = "ui-part-1", skillID = "unlisted-id" }, false)
		contains(fallback.lines[1], 'Skill "unlisted-id"')
	end)

	it("renders only an attachment's server snapshot with its source metadata and Markdown highlights", function()
		sync.get_skills = function() return {
			{ id = "catalog-review", name = "Catalog review", content = "CATALOG_INSTRUCTIONS",
				description = "CATALOG_DESCRIPTION", location = "/tmp/catalog/SKILL.md" },
		} end
		local attachment = { type = "skill", id = "ui-part-1", skillID = "catalog-review", name = "Selected review",
			text = native_output("Source review", "---\ndescription: Server description\n---\n**Server instructions**") }
		local snapshot = vim.deepcopy(attachment)
		local closed, opened = skill.render_attachment(attachment, false), skill.render_attachment(attachment, true)
		contains(closed.lines[1], 'Skill "Selected review" · Attached')
		assert.is_nil(closed.lines[1]:find("|", 1, true))
		contains(opened.lines[2], "   ┌")
		contains(opened.lines[#opened.lines], "   └")
		local output = body_text(opened)
		contains(output, "Skill: Source review")
		contains(output, "Server description")
		contains(output, "Base: /tmp/skills/review")
		contains(output, "/tmp/skills/review/scripts/check.lua")
		contains(output, "Server instructions")
		assert.is_nil(output:find("CATALOG_", 1, true))
		assert.is_nil(output:find("/tmp/catalog", 1, true))
		local emphasized = false
		for _, hl in ipairs(opened.highlights) do
			if hl.hl_group:find("Strong", 1, true) then
				contains(opened.lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end), "Server instructions")
				emphasized = true
			end
		end
		assert.is_true(emphasized)
		assert.same(snapshot, attachment)
	end)

	it("treats an empty server snapshot as attached while retaining an empty body", function()
		assert.is_nil(skill.render_attachment(nil, false))
		assert.is_nil(skill.render_attachment({ type = "tool", tool = "skill" }, false))
		local result = skill.render_attachment({ type = "skill", skillID = "empty", text = "" }, true)
		contains(result.lines[1], 'Skill "empty" · Attached')
		assert.is_nil(result.lines[1]:find("|", 1, true))
		contains(body_text(result), "No instructions returned")
		assert.is_nil(text(result):find("Unconfirmed", 1, true))
	end)

	it("resolves native tool ids and refreshes attachment names when the catalog changes", function()
		local catalog = { { id = "catalog-review", name = "First name", description = "Catalog details" } }
		sync.get_skills = function() return catalog end
		local attachment = { type = "skill", id = "ui-part-1", skillID = "catalog-review" }
		local tool = part({ status = "completed", input = { id = "catalog-review" }, output = "Native instructions" })
		local key = skill.cache_key(attachment)
		assert.equals(key, skill.cache_key(attachment))
		contains(skill.render_attachment(attachment, false).lines[1], 'Skill "First name"')
		contains(skill.render_tool(tool, false).lines[1], 'Skill "First name"')
		local tool_key = skill.cache_key(tool)
		catalog[1].name = "Renamed skill"
		assert.is_not_equal(key, skill.cache_key(attachment))
		assert.is_not_equal(tool_key, skill.cache_key(tool))
		contains(skill.render_attachment(attachment, false).lines[1], 'Skill "Renamed skill"')
		contains(skill.render_tool(tool, false).lines[1], 'Skill "Renamed skill"')
		catalog = {}
		contains(skill.render_tool(tool, false).lines[1], 'Skill "catalog-review"')
	end)
end)
