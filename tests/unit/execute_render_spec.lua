local execute = require("opencode.ui.chat.execute")
local cs = require("opencode.ui.chat.state")
local view = cs.state
local syntax = require("opencode.ui.syntax")

local function part(state)
	return { id = "exec", tool = "execute", state = state }
end

local function text(result)
	return table.concat(vim.tbl_map(function(line) return line:gsub(" +$", "") end, result.lines), "\n")
end

local function contains(value, needle)
	assert.is_truthy(value:find(needle, 1, true), "Missing " .. needle .. " in " .. value)
end

describe("universal execute widget", function()
	local bufnr, winid, saved, original_highlight
	before_each(function()
		saved = { winid = view.winid, bufnr = view.bufnr, visible = view.visible, tools = view.tools,
			tasks = view.tasks, expanded_tools = view.expanded_tools, task_anim_frame = view.task_anim_frame,
			render_scheduled = view.render_scheduled, render_in_progress = view.render_in_progress }
		bufnr = vim.api.nvim_create_buf(false, true)
		winid = vim.api.nvim_open_win(bufnr, true, { relative = "editor", row = 1, col = 1, width = 80, height = 20 })
		view.bufnr, view.winid, view.expanded_tools = bufnr, winid, {}
		original_highlight = syntax.highlight_text
	end)
	after_each(function()
		syntax.highlight_text = original_highlight
		require("opencode.ui.chat.tasks").stop_task_animation_timer()
		if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
		if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		for key, value in pairs(saved) do view[key] = value end
		view.winid, view.bufnr, view.visible = saved.winid, saved.bufnr, saved.visible
		view.task_anim_frame = saved.task_anim_frame
	end)

	it("uses recorded MCP calls and native millisecond timing instead of inferring tools from code", function()
		local item = part({ status = "completed", time = { start = 1000, ["end"] = 1250 },
			input = { code = 'return tools.fake.guessed_call()' }, output = '{"ok":true}',
			metadata = { toolCalls = {
				{ tool = "arbitrary-server.search", status = "completed" },
				{ tool = "arbitrary-server.search", status = "completed" },
			} },
		})
		local result = execute.render_tool(item, false)
		contains(text(result), "✓ execute")
		contains(text(result), "2 tools · 250ms")
		local _, count = text(result):gsub("arbitrary%-server.search", "")
		assert.equals(2, count)
		assert.is_nil(text(result):find("Result", 1, true))
		assert.is_nil(text(result):find("guessed_call", 1, true))
		assert.same(execute.render_tool(item, true), execute.render(item, true))
	end)

	it("shows one Explore-style row and opens only the recorded MCP calls", function()
		local item = part({ status = "completed", time = { start = 1000, ["end"] = 1250 },
			input = { code = "return tools.fake.guessed_call()" },
			output = string.rep("large output must stay hidden\n", 10000),
			metadata = { toolCalls = {
				{ tool = "arbitrary-server.search", status = "completed" },
				{ tool = "another-server.fetch", status = "completed" },
			} },
		})
		local result = execute.render(item, false)
		assert.equals(1, #result.lines)
		assert.equals(" → arbitrary-server.search · +1 more · 250ms", text(result))
		assert.same({}, result.children)
		local opened = execute.render(item, true)
		contains(opened.lines[1], "execute")
		contains(text(opened), "  ↳ ✓ arbitrary-server.search")
		contains(text(opened), "  ↳ ✓ another-server.fetch")
		assert.equals(3, #opened.lines)
		assert.is_not_nil(opened.children[execute.section_id(item.id, "calls")])
		assert.equals(1, vim.tbl_count(opened.children))
		assert.is_nil(text(opened):find("Result", 1, true))
		assert.is_nil(text(opened):find("Code", 1, true))
		assert.is_nil(text(opened):find("large output", 1, true))
	end)

	it("marks folded failures and cancellation without dumping errors or results", function()
		for _, failed_state in ipairs({
			{ status = "error", error = "A long\nmultiline error" },
			{ status = "cancelled" },
			{ status = "completed", metadata = { error = true }, output = "Execution cancelled." },
			{ status = "completed", metadata = { toolCalls = {
				{ tool = "server.first", status = "completed" },
				{ tool = "server.second", status = "error" },
			} }, output = "handled failure" },
		}) do
			local item = part(failed_state)
			local result = execute.render(item, false)
			assert.is_true(execute.failed(item))
			assert.equals(1, #result.lines)
			contains(text(result), "✗")
			assert.is_nil(text(result):find("multiline error", 1, true))
			assert.is_nil(text(result):find("handled failure", 1, true))
		end
		assert.is_false(execute.failed(part({ status = "completed", error = vim.NIL })))
		assert.is_false(execute.failed(nil))
	end)

	it("keeps folded streaming rows bounded and does not infer MCP calls from source", function()
		assert.is_nil(execute.render(nil, false))
		assert.is_nil(execute.render({ tool = "read" }, false))
		for _, status in ipairs({ "pending", "streaming", "running" }) do
			local item = part({ status = status, input = { code = "tools.guessed.call()" } })
			assert.is_true(execute.is_working(item))
			contains(text(execute.render(item, false)), "JavaScript")
			assert.is_nil(text(execute.render(item, false)):find("guessed", 1, true))
		end
		local item = part({ status = "running", metadata = { toolCalls = {
			{ tool = "server." .. string.rep("世界", 200) .. "\nother row", status = "running" },
			{ tool = "server.other", status = "completed" },
		} } })
		for _, width in ipairs({ 80, 24, 12 }) do
			vim.api.nvim_win_set_config(winid, { width = width })
			local result = execute.render(item, false)
			assert.equals(1, #result.lines)
			assert.is_true(vim.fn.strdisplaywidth(result.lines[1]) <= width)
			assert.is_truthy(text(result):match("[|/\\-]$"))
		end
		assert.is_false(execute.is_working(part({ status = "completed" })))
		assert.is_false(execute.is_working(nil))
	end)

	it("keeps large payloads hidden even with stale code expansion at narrow Unicode widths", function()
		local item = part({ status = "completed", input = { code = "return '" .. string.rep("世界", 6000) .. "';" },
			output = vim.json.encode({ title = "Пример", body = string.rep("世界", 15000) }),
			metadata = { toolCalls = { { tool = "server." .. string.rep("世界", 100), status = "completed" } } },
		})
		view.expanded_tools[execute.section_id(item.id, "code")] = true
		for _, width in ipairs({ 80, 24, 12 }) do
			vim.api.nvim_win_set_config(winid, { width = width })
			local result = execute.render_tool(item, true)
			assert.equals(2, #result.lines)
			assert.is_nil(result.children[execute.section_id(item.id, "result")])
			assert.is_nil(result.children[execute.section_id(item.id, "code")])
			for _, line in ipairs(result.lines) do
				assert.is_true(vim.fn.strdisplaywidth(line) <= width, "Overflow: " .. line)
			end
		end
	end)

	it("keeps cancellation and hidden child failures visible when folded", function()
		local calls = {}
		for i = 1, 8 do calls[i] = { tool = "server.call" .. i, status = i == 8 and "error" or "completed" } end
		local failed_child = execute.render_tool(part({ status = "completed", metadata = { toolCalls = calls }, output = "handled" }), false)
		contains(text(failed_child), "1 failed")
		contains(text(failed_child), "6 more calls")
		local cancelled = execute.render_tool(part({ status = "completed", metadata = { error = true }, output = "Execution cancelled." }), false)
		contains(text(cancelled), "✗ execute")
		assert.equals(1, #cancelled.lines)
		assert.is_nil(text(cancelled):find("Execution cancelled.", 1, true))
		assert.is_nil(text(cancelled):find("Full error", 1, true))
	end)

	it("preserves source data and tolerates missing metadata, nulls and streaming input", function()
		assert.is_nil(execute.render_tool(nil, false))
		assert.is_nil(execute.render_tool({ tool = "bash" }, false))
		for _, status in ipairs({ "pending", "streaming", "running", "completed", "error" }) do
			local item = part({ status = status, input = vim.NIL, output = vim.NIL, error = vim.NIL,
				metadata = { toolCalls = { vim.NIL, {}, { tool = false, status = "running" } } } })
			local original = vim.deepcopy(item)
			for _, expanded in ipairs({ false, true }) do
				local rendered = text(execute.render_tool(item, expanded))
				assert.is_nil(rendered:find("vim.NIL", 1, true))
				contains(rendered, "execute")
			end
			assert.same(original, item)
		end
	end)

	it("does not render output, errors, attachments or source beneath calls", function()
		local item = part({ status = "error", input = { code = "return privateSource;" },
			output = "private output", error = "private error",
			files = { { filename = "private-attachment.txt", url = "file:///private-attachment.txt" } },
			metadata = { toolCalls = { { tool = "any-server.any_tool", status = "error" } } },
		})
		local original = vim.deepcopy(item)
		view.expanded_tools[execute.section_id(item.id, "code")] = true
		syntax.highlight_text = function() error("Inline JavaScript should not be highlighted") end
		for _, expanded in ipairs({ false, true }) do
			local result = execute.render_tool(item, expanded)
			assert.equals(2, #result.lines)
			contains(text(result), "✗ execute")
			contains(text(result), "  ↳ ✗ any-server.any_tool")
			for _, lower in ipairs({ "Result", "Full result", "Full error", "Code", "private" }) do
				assert.is_nil(text(result):find(lower, 1, true))
			end
			assert.equals(1, vim.tbl_count(result.children))
			assert.equals("calls", result.children[execute.section_id(item.id, "calls")].execute_action)
		end
		assert.same(original, item)
	end)

	it("shows the header and calls with no frame or fill and right-aligned metadata", function()
		local item = part({ status = "completed", time = { start = 1000, ["end"] = 2400 },
			input = { code = "return value;" },
			output = vim.json.encode({ title = "A short title", main = "One\nTwo\nThree\nFour" }),
			metadata = { toolCalls = { { tool = "any-server.any_tool", status = "completed" } } },
		})
		local result = execute.render_tool(item, true)
		local content = text(result)
		assert.equals(2, #result.lines)
		contains(content, "  ↳ ✓ any-server.any_tool")
		assert.is_nil(content:find("Result", 1, true))
		assert.is_nil(content:find("A short title", 1, true))
		assert.is_nil(content:find("▏", 1, true))
		assert.is_nil(content:find("[Enter]", 1, true))
		assert.is_nil(content:find("title:", 1, true))
		assert.equals(80, vim.fn.strdisplaywidth(result.lines[1]))
		assert.is_truthy(result.lines[1]:match("1 tool · 1.4s$"))
		for _, name in ipairs({ "Output", "Muted", "Call", "Success", "Running", "Error" }) do
			assert.is_nil(vim.api.nvim_get_hl(0, { name = "OpenCodeExecute" .. name }).bg)
		end
		local compact = execute.render_tool(item, false)
		assert.equals(2, #compact.lines)
		assert.is_truthy(compact.lines[#compact.lines]:find("any-server.any_tool", 1, true))
	end)

	it("keeps result values untouched and renders only a header when no calls are recorded", function()
		for _, value in ipairs({ false, "", "plain result", '{"body":"content"}', vim.NIL }) do
			local item = part({ status = "completed", output = value })
			for _, expanded in ipairs({ false, true }) do
				local result = execute.render_tool(item, expanded)
				assert.equals(1, #result.lines)
				assert.same({}, result.children)
				assert.is_nil(text(result):find("Result", 1, true))
			end
			assert.same(value, item.state.output)
		end
	end)

	it("updates the header spinner without changing call rows", function()
		local animation = require("opencode.ui.chat.task_animation")
		view.visible, view.tools, view.tasks = true, {}, {}
		view.render_scheduled, view.render_in_progress = false, false
		for _, width in ipairs({ 80, 24, 12 }) do
			vim.api.nvim_win_set_config(winid, { width = width })
			view.task_anim_frame = 1
			local item = part({ status = "running", metadata = { toolCalls = { { tool = "server.path/", status = "running" } } } })
			local result = execute.render_tool(item, false)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result.lines)
			view.tools.exec = { start_line = 0, end_line = #result.lines - 1, tool_part = item }
			view.task_anim_frame = 3
			assert.is_true(animation.update_animation_frames_in_place())
			local marks = vim.api.nvim_buf_get_extmarks(bufnr, cs.chat_anim_ns, 0, -1, { details = true })
			assert.equals(1, #marks)
			assert.equals(0, marks[1][2])
			assert.same(result.lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		end
	end)
end)
