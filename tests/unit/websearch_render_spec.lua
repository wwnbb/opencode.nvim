local websearch = require("opencode.ui.chat.websearch")
local render = require("opencode.ui.chat.render")
local style = require("opencode.ui.chat.exploration_style")
local view = require("opencode.ui.chat.state").state

local function part(state)
	return { id = "websearch-1", type = "tool", tool = "websearch", state = state }
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

describe("websearch list rendering", function()
	local original_content, old_winid, old_frame, old_columns, bufnr, winid
	before_each(function()
		original_content, old_winid, old_frame, old_columns = render.render_content, view.winid, view.task_anim_frame, vim.o.columns
		vim.o.columns = 120
		bufnr = vim.api.nvim_create_buf(false, true)
		winid = vim.api.nvim_open_win(bufnr, false, { relative = "editor", row = 0, col = 0, width = 100, height = 10 })
		view.winid, view.task_anim_frame = winid, 1
	end)

	after_each(function()
		render.render_content, view.winid, view.task_anim_frame = original_content, old_winid, old_frame
		vim.api.nvim_win_close(winid, true)
		vim.api.nvim_buf_delete(bufnr, { force = true })
		vim.o.columns = old_columns
	end)

	it("keeps the query compact until its unnumbered results are opened", function()
		local item = part({ status = "completed", input = { query = "Lua coroutines" },
			output = "# Results\n\n**Coroutine guide**\n\nhttps://example.com/lua" })
		local closed, opened = websearch.render(item, false), websearch.render(item, true)
		assert.equals(1, #closed.lines)
		contains(closed.lines[1], '→ WebSearch "Lua coroutines" · Searched')
		assert.is_nil(text(closed):find("Coroutine guide", 1, true))
		assert.equals(closed.lines[1]:gsub("→", "↘"), opened.lines[1])
		assert.equals(style.header_hl, opened.highlights[1].hl_group)
		contains(opened.lines[2], "   ┌")
		contains(opened.lines[#opened.lines], "   └")
		contains(text(opened), style.prefix .. "Coroutine guide")
		contains(body_text(opened), "https://example.com/lua")
		assert.is_nil(text(opened):find("1: Coroutine guide", 1, true))
		local emphasized = false
		for _, hl in ipairs(opened.highlights) do
			if hl.hl_group:find("Strong", 1, true) then
				contains(opened.lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end), "Coroutine guide")
				emphasized = true
			end
		end
		assert.is_true(emphasized)
	end)

	it("renders native structured results with readable search options and no input JSON", function()
		local source = "# Native results\n\nFound the official documentation."
		local item = part({ status = "completed", input = {
			query = "OpenCode API", numResults = 5, type = "deep", livecrawl = "preferred", contextMaxCharacters = 12000,
		}, output = { provider = "exa", text = source }, time = { start = 1000, ["end"] = 2100 } })
		local snapshot = vim.deepcopy(item)
		local calls = {}
		render.render_content = function(content, opts)
			calls[#calls + 1] = { content = content, opts = opts }
			return original_content(content, opts)
		end
		local result = websearch.render(item, true)
		contains(text(result), "1.1s")
		contains(body_text(result), "Results: 5")
		contains(body_text(result), "Search: deep")
		contains(body_text(result), "Live crawl: preferred")
		contains(body_text(result), "Context characters: 12000")
		assert.is_nil(text(result):find('"numResults"', 1, true))
		assert.equals(1, #calls)
		assert.equals(source, calls[1].content)
		assert.equals("tools", calls[1].opts.scope)
		assert.equals(95, calls[1].opts.width)
		assert.same(snapshot, item)
	end)

	it("keeps the full Unicode query and wrapped results accessible in narrow windows", function()
		local query = string.rep("世界Ж", 20) .. " query tail"
		local source = string.rep("世界Ж", 30) .. "RESULT_TAIL"
		for _, width in ipairs({ 80, 24, 12 }) do
			vim.api.nvim_win_set_config(winid, { width = width })
			local item = part({ status = "completed", input = { query = query }, output = source })
			assert.equals(1, #websearch.render(item, false).lines)
			local result = websearch.render(item, true)
			for _, line in ipairs(result.lines) do
				assert.is_true(vim.fn.strdisplaywidth(line) <= width, "Overflow: " .. line)
			end
			local unwrapped = body_text(result):gsub("\n", "")
			contains(unwrapped:gsub(" ", ""), query:gsub(" ", ""))
			contains(unwrapped, source)
		end
	end)

	it("preserves full errors and partial results inside the same shaded frame", function()
		local message = "HTTP 429: rate limit reached\nTry again later."
		local result = websearch.render(part({ status = "error", input = { query = "latest research" },
			output = "Partial result", error = { message = message } }), true)
		assert.equals(style.error_hl, result.highlights[1].hl_group)
		contains(result.lines[1], "HTTP 429")
		contains(body_text(result), "Partial result")
		contains(body_text(result), message)
		local found = false
		for _, hl in ipairs(result.highlights) do
			assert.is_not_equal("ErrorMsg", hl.hl_group)
			if hl.hl_group == style.body_error_hl then
				assert.equals(3, hl.col_start)
				found = true
			end
		end
		assert.is_true(found)
	end)

	it("uses shared working status and leaves animation to the group when nested", function()
		for _, state in ipairs({
			{ status = "pending" }, { status = "streaming" },
			{ status = "running", time = { completed = 2000 } }, {},
		}) do
			state.input = { query = "search query" }
			local item = part(state)
			for _, width in ipairs({ 100, 24, 12 }) do
				vim.api.nvim_win_set_config(winid, { width = width })
				for _, expanded in ipairs({ false, true }) do
					local standalone = websearch.render(item, expanded)
					local grouped = websearch.render(item, expanded, { grouped = true })
					assert.equals("|", vim.trim(standalone.lines[1]):sub(-1))
					assert.is_nil(grouped.lines[1]:find("|", 1, true))
					if expanded then contains(standalone.lines[2], "   ┌") end
				end
			end
		end
		vim.api.nvim_win_set_config(winid, { width = 100 })
		local completed = websearch.render(part({ input = { query = "finished" }, error = false,
			time = { start = 1000, completed = 2000 } }), true)
		contains(completed.lines[1], "Searched")
		contains(body_text(completed), "Empty response")
		assert.is_nil(completed.lines[1]:find("|", 1, true))
		assert.is_nil(text(completed):find("false", 1, true))
	end)

	it("handles null or incomplete inputs without leaking native nulls", function()
		assert.is_nil(websearch.render(nil, false))
		assert.is_nil(websearch.render({ tool = "webfetch" }, false))
		for _, item in ipairs({
			{ tool = "websearch" }, part({ status = "running", input = vim.NIL }),
			part({ status = "completed", input = { query = vim.NIL, type = vim.NIL, numResults = vim.NIL }, output = vim.NIL }),
			part({ status = "error", input = "unfinished input", error = vim.NIL }),
		}) do
			for _, expanded in ipairs({ false, true }) do
				local result = websearch.render(item, expanded)
				contains(text(result), "WebSearch")
				assert.is_nil(text(result):find("vim.NIL", 1, true))
			end
		end
	end)
end)
