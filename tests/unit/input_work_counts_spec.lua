local layout = require("opencode.ui.input.layout")
local info_bar = require("opencode.ui.input.info_bar")
local app = require("opencode.state")
local sync = require("opencode.sync")

-- Compare bounded reads with the original full-draft height calculation.
local function original_height(lines, cfg, width)
	local display_lines = 0
	for _, line in ipairs(lines) do
		if display_lines >= cfg.max_height then break end
		local line_width = vim.fn.strdisplaywidth(line)
		display_lines = display_lines + (line_width == 0 and 1 or math.ceil((line_width + 1) / width))
	end
	return math.max(cfg.min_height, math.min(display_lines, cfg.max_height))
end

describe("input draft read work counts", function()
	local state, saved, reads, winid
	local function snapshot()
		local marks = {}
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.info_bufnr,
			vim.api.nvim_create_namespace("opencode_input_info"), 0, -1, { details = true })) do
			marks[#marks + 1] = { mark[2], mark[3], mark[4] }
		end
		return { lines = saved.get_lines(state.info_bufnr, 0, -1, false), marks = marks }
	end

	local function assert_info(expected_reads, expected_text)
		reads = {}
		local cursor = vim.api.nvim_win_get_cursor(winid)
		info_bar.update(state)
		assert.equals(expected_reads, #reads)
		if expected_reads > 0 then assert.same({ 0, -1, false }, reads[1]) end
		local actual = snapshot()
		if expected_text then assert.equals(expected_text, actual.lines[1]) end
		local highlights = {}
		for _, mark in ipairs(actual.marks) do
			assert.is_true(mark[2] >= 0 and mark[3].end_col <= #actual.lines[1])
			highlights[mark[3].hl_group] = actual.lines[1]:sub(mark[2] + 1, mark[3].end_col)
		end
		assert.is_true(#actual.marks > 0)
		if expected_text then
			assert.equals("Code ", highlights.Identifier)
			assert.equals("Model", highlights.OpenCodeInputModel)
			assert.equals(expected_text:match(" · Skills?: .+$"), highlights.OpenCodeInputSkill)
		end
		assert.same(cursor, vim.api.nvim_win_get_cursor(winid))
		return actual.lines[1]
	end

	before_each(function()
		saved = { get_lines = vim.api.nvim_buf_get_lines, session = app.get_session,
			skills = sync.get_skills, local_module = package.loaded["opencode.local"] }
		app.get_session = function() return nil end
		sync.get_skills = function()
			return { { id = "catalog", name = "Catalog 名称" }, { id = "invalid-name", name = {} } }
		end
		package.loaded["opencode.local"] = {
			agent = { current = function() return { name = "code" } end, color = function() return "Identifier" end },
			model = { parsed = function() return { name = "Model", provider = "Provider" } end },
			variant = { current = function() return "Variant" end },
		}
		state = { visible = true, bufnr = vim.api.nvim_create_buf(false, true),
			info_bufnr = vim.api.nvim_create_buf(false, true), parts = {},
			config = { min_height = 1, max_height = 6 },
			layout = { row = 10, col = 1, content_width = 20, current_height = 1 } }
		winid = vim.api.nvim_open_win(state.bufnr, false, {
			relative = "editor", row = 10, col = 1, width = 20, height = 1, style = "minimal",
		})
		state.winid = winid
		state.popup = { update_layout = function(_, frame)
			vim.api.nvim_win_set_config(winid, { relative = "editor", row = frame.position.row,
				col = frame.position.col, width = frame.size.width, height = frame.size.height })
		end }
		state.marker_range = function(text, marker) return text:find(marker, 1, true) end
		reads = {}
		vim.api.nvim_buf_get_lines = function(bufnr, first, last, strict)
			if bufnr == state.bufnr then reads[#reads + 1] = { first, last, strict } end
			return saved.get_lines(bufnr, first, last, strict)
		end
	end)

	after_each(function()
		vim.api.nvim_buf_get_lines = saved.get_lines
		app.get_session, sync.get_skills = saved.session, saved.skills
		package.loaded["opencode.local"] = saved.local_module
		if winid and vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
		for _, bufnr in ipairs({ state.bufnr, state.info_bufnr }) do
			if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		end
		state, winid = nil, nil
	end)

	it("matches full-draft heights while reading at most max_height physical lines", function()
		local long = {}
		for index = 1, 2000 do long[index] = "line " .. index end
		local fixtures = { { "" }, { "short", "", "last" }, { string.rep("x", 3000) }, long,
			{ "\tTabbed", "宽字符", "é é é", "👩‍💻 🙂", "尾", "", "later" } }
		for _, width in ipairs({ 6, 20, 40 }) do
			vim.api.nvim_win_set_width(winid, width)
			state.layout.content_width = width
			for _, lines in ipairs(fixtures) do
				vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
				vim.api.nvim_win_set_cursor(winid, { 1, 0 })
				local expected = original_height(lines, state.config, width)
				reads = {}
				layout.resize(state)
				assert.same({ { 0, state.config.max_height, false } }, reads)
				assert.equals(expected, state.layout.current_height)
				assert.equals(expected, vim.api.nvim_win_get_height(winid))
				local config = vim.api.nvim_win_get_config(winid)
				assert.equals(state.layout.row - math.max(0, expected - state.config.min_height), config.row)
				assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(winid))
				assert.same(lines, saved.get_lines(state.bufnr, 0, -1, false))
			end
		end
	end)

	it("does no draft read for hidden or closed resize targets", function()
		state.visible = false
		layout.resize(state)
		state.visible = true
		vim.api.nvim_win_close(winid, true)
		layout.resize(state)
		assert.same({}, reads)
	end)

	it("skips draft reads without marked skills while resolving names and removing duplicates", function()
		local core = "Code Model Provider · Variant"
		state.layout.content_width = 120
		for _, case in ipairs({
			{ parts = {}, text = core },
			{ parts = { { type = "file", id = "file" }, { type = "agent", name = "agent" } }, text = core },
			{ parts = { { type = "skill", id = "catalog" }, { type = "skill", id = "fallback", name = "Fallback" },
				{ type = "skill", id = "catalog", name = "Duplicate" }, { type = "skill", id = "invalid-name" } },
				text = core .. " · Skills: Catalog 名称, Fallback, invalid-name" },
		}) do
			state.parts = case.parts
			assert_info(0, case.text)
		end
	end)

	it("shares one complete read for distant skill markers and preserves filtering and order", function()
		local lines = {}
		for index = 1, 2000 do lines[index] = "draft " .. index end
		lines[#lines] = "Use @catalog and @last"
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
		state.layout.content_width = 120
		state.parts = {
			{ type = "skill", id = "ui-id", skillID = "catalog", _marker = "@missing" },
			{ type = "skill", id = "last", name = "Last", _marker = "@last" },
			{ type = "skill", id = "catalog", _marker = "@catalog" },
			{ type = "skill", id = "last", name = "Duplicate" },
		}
		assert_info(1, "Code Model Provider · Variant · Skills: Last, Catalog 名称")
		vim.api.nvim_buf_set_lines(state.bufnr, #lines - 1, -1, false, { "Markers removed" })
		assert_info(1, "Code Model Provider · Variant · Skill: Duplicate")
		state.layout.content_width = 14
		local narrow = assert_info(1)
		assert.equals("… Model · Ski…", narrow)
		assert.is_true(vim.fn.strdisplaywidth(narrow) <= 14)
		assert.same({ { 0, 4, "Identifier" }, { 4, 9, "OpenCodeInputModel" }, { 9, 19, "OpenCodeInputSkill" } },
			vim.tbl_map(function(mark) return { mark[2], mark[3].end_col, mark[3].hl_group } end, snapshot().marks))
	end)

	it("avoids draft reads when marker validation is unavailable", function()
		state.parts = { { type = "skill", id = "catalog", _marker = "@catalog" } }
		state.marker_range = nil
		assert_info(0, "Code Model Provider · Variant")
	end)
end)
