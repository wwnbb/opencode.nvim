local webfetch = require("opencode.ui.chat.webfetch")
local render = require("opencode.ui.chat.render")
local view = require("opencode.ui.chat.state").state
local style = require("opencode.ui.chat.exploration_style")

local function part(state)
	return { id = "webfetch-1", type = "tool", tool = "webfetch", state = state }
end

local render_helpers = require("tests.helpers.tool_render")
local text, contains, panel_text = render_helpers.text, render_helpers.contains, render_helpers.panel_text

describe("webfetch custom tool rendering", function()
	local view_fields = { "winid", "bufnr", "visible", "tasks", "tools", "task_anim_frame", "render_scheduled", "render_in_progress" }
	local original_content, old_view, old_columns, bufnr, winid
	before_each(function()
		original_content, old_columns, old_view = render.render_content, vim.o.columns, {}
		for _, field in ipairs(view_fields) do old_view[field] = view[field] end
		vim.o.columns = 120
		bufnr = vim.api.nvim_create_buf(false, true)
		winid = vim.api.nvim_open_win(bufnr, false, { relative = "editor", row = 0, col = 0, width = 100, height = 10 })
		view.winid = winid
	end)

	after_each(function()
		render.render_content = original_content
		for _, field in ipairs(view_fields) do view[field] = old_view[field] end
		vim.api.nvim_win_close(winid, true)
		vim.api.nvim_buf_delete(bufnr, { force = true })
		vim.o.columns = old_columns
	end)

	it("summarizes the target and result in a single collapsed row", function()
		local item = part({
			status = "completed",
			input = { url = "https://example.com/jobs", format = "markdown", timeout = 30 },
			output = "# Careers\n\nUNIQUE_BODY_CONTENT",
			time = { created = 1000, completed = 1905 },
		})
		local result = webfetch.render_tool(item, false)
		local rows = vim.tbl_filter(function(line) return vim.trim(line) ~= "" end, result.lines)
		assert.equals(1, #rows)
		contains(rows[1], "WebFetch")
		contains(rows[1], "example.com/jobs")
		-- A completed fetch needs no status word.
		assert.equals(" → WebFetch example.com/jobs · 905ms", rows[1]:gsub(" +$", ""))
		assert.is_nil(text(result):find("UNIQUE_BODY_CONTENT", 1, true))
		assert.is_nil(text(result):find("Input:", 1, true))
		assert.is_nil(text(result):find('"format"', 1, true))
	end)

	it("distinguishes pending, running, HTTP failure and unknown failure", function()
		local cases = {
			{ status = "pending", expected = "Pending" },
			{ status = "running", expected = "Running" },
			{ status = "error", error = "StatusCode: non 2xx status code (404 GET https://example.com/jobs)", expected = "HTTP 404" },
		}
		for _, state in ipairs(cases) do
			local expected = state.expected
			state.expected = nil
			state.input = { url = "https://example.com/jobs" }
			local output = text(webfetch.render_tool(part(state), false))
			contains(output, expected)
			assert.is_nil(output:find("Fetched", 1, true))
		end
	end)

	it("expands readable request metadata and renders Markdown with tool-scoped styling", function()
		local source = "# Careers\n\n**Senior engineer**\n\n- Remote\n- Platform"
		local calls = {}
		render.render_content = function(content, opts)
			calls[#calls + 1] = { content = content, opts = opts }
			return original_content(content, opts)
		end
		local result = webfetch.render_tool(part({
			status = "completed",
			input = { url = "https://example.com/jobs", format = "markdown", timeout = 30 },
			output = source,
		}), true)
		local output = text(result)
		contains(output, "https://example.com/jobs")
		contains(output:lower(), "markdown")
		contains(output, "30")
		assert.is_nil(output:find('"timeout"', 1, true))
		assert.equals(1, #calls)
		assert.equals("tools", calls[1].opts.scope)
		contains(panel_text(result), "Senior engineer")
		contains(panel_text(result), "Platform")
		assert.is_nil(panel_text(result):find("**Senior engineer**", 1, true))
		local styled_body = false
		for _, span in ipairs(result.highlights) do
			if span.hl_group:find("Strong", 1, true) then
				local line = result.lines[span.line + 1]
				contains(line:sub(span.col_start + 1, span.col_end), "Senior engineer")
				contains(line, style.prefix)
				styled_body = true
			end
		end
		assert.is_true(styled_body)
	end)

	it("preserves HTML and plain text literally instead of interpreting Markdown", function()
		render.render_content = function() error("Raw formats must not enter Markdown rendering") end
		for _, format in ipairs({ "html", "text" }) do
			local source = "<h1>**Literal title**</h1>\n  indented content\n\nlast line"
			local result = webfetch.render_tool(part({
				status = "completed",
				input = { url = "https://example.com", format = format },
				output = source,
			}), true)
			contains(panel_text(result), source)
		end
	end)

	it("retains the original failure inside the expanded panel without ErrorMsg styling", function()
		local message = "StatusCode: non 2xx status code (404 GET https://example.com/jobs)\nRetry another URL."
		local result = webfetch.render_tool(part({
			status = "error",
			input = { url = "https://example.com/jobs", format = "markdown" },
			error = message,
		}), true)
		contains(text(result), "HTTP 404")
		contains(panel_text(result), message)
		for _, span in ipairs(result.highlights) do
			assert.is_not_equal("ErrorMsg", span.hl_group)
		end
	end)

	it("wraps long Unicode URLs and raw content to the available chat width without loss", function()
		local url = "https://example.com/" .. string.rep("世界", 12) .. "?page=tail"
		local source = string.rep("Ж世界", 40) .. "END_OF_BODY"
		for _, width in ipairs({ 80, 12 }) do
			vim.api.nvim_win_set_config(winid, { width = width })
			local item = part({ status = "completed", input = { url = url, format = "text" }, output = source })
			for _, expanded in ipairs({ false, true }) do
				local result = webfetch.render_tool(item, expanded)
				for _, line in ipairs(result.lines) do
					assert.is_true(vim.fn.strdisplaywidth(line) <= width, "Overflow at width " .. width .. ": " .. line)
				end
				if expanded then
					local unwrapped = panel_text(result):gsub("\n", "")
					contains(unwrapped, url)
					contains(unwrapped, source)
				end
			end
		end
	end)

	it("tolerates incomplete and native null states while rejecting unrelated tools", function()
		assert.is_nil(webfetch.render_tool(nil, false))
		assert.is_nil(webfetch.render_tool({ tool = "bash" }, false))
		local items = {
			part({ status = "completed", input = { url = vim.NIL, format = vim.NIL, timeout = vim.NIL }, output = vim.NIL }),
			part({ status = "error", input = "unfinished input", error = vim.NIL }),
		}
		for _, item in ipairs(items) do
			for _, expanded in ipairs({ false, true }) do
				local result = webfetch.render_tool(item, expanded)
				assert.equals("table", type(result.lines))
				assert.equals("table", type(result.highlights))
				contains(text(result), "WebFetch")
				assert.is_nil(text(result):find("vim.NIL", 1, true))
			end
		end
	end)

	it("keeps standalone animation on the compact header without overlaying a trailing URL slash", function()
		local animation = require("opencode.ui.chat.task_animation")
		local namespace = require("opencode.ui.chat.state").chat_anim_ns
		local url = "https://example.com/"
		local item = part({ status = "running", input = { url = url, format = "text" } })
		view.bufnr, view.visible, view.tasks = bufnr, true, {}
		view.render_scheduled, view.render_in_progress = false, false
		for _, width in ipairs({ 100, 12 }) do
			vim.api.nvim_win_set_config(winid, { width = width })
			view.task_anim_frame = 1
			local result = webfetch.render_tool(item, true)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result.lines)
			view.tools = { [item.id] = { start_line = 0, end_line = #result.lines - 1, tool_part = item } }
			contains(result.lines[2], "   ┌")
			local last_header = result.lines[1]:gsub(" +$", "")
			assert.is_not_nil(require("tests.helpers.tool_render").spinner(last_header))
			view.task_anim_frame = 3
			assert.is_true(animation.update_animation_frames_in_place())
			local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
			assert.equals(1, #marks)
			assert.equals(0, marks[1][2])
			local frames = require("opencode.ui.chat.tool_panel").ANIM_FRAMES
			assert.equals(#last_header - #require("tests.helpers.tool_render").spinner(last_header), marks[1][3])
			assert.equals(frames[3], marks[1][4].virt_text[1][1])
			assert.same(result.lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
			contains(panel_text(result):gsub("\n", ""), url)
		end
	end)
end)
