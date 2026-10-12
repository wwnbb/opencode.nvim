local render = require("opencode.ui.chat.render")
local chat_tasks = require("opencode.ui.chat.tasks")
local search = require("opencode.ui.chat.search")
local rg = require("opencode.ui.chat.rg")
local function render_text(result) return table.concat(result.lines, "\n") end
local function assert_no_buffer_newlines(lines, message)
	for _, line in ipairs(lines) do
		assert.is_nil(line:find("\n", 1, true), message)
		assert.is_nil(line:find("\r", 1, true), message)
	end
end

describe("tool and panel rendering contracts", function()
	before_each(function()
		require("opencode.sync").clear_all()
		require("opencode.state").reset()
		require("opencode.ui.chat.render_state").reset_chat_surface({ reset_expansions = true })
	end)
	after_each(function()
		require("opencode.permission.state").clear_all()
		require("opencode.question.state").clear_all()
		require("opencode.edit.state").clear_all()
		require("opencode.artifact.changes").clear()
		require("opencode.sync").clear_all()
	end)

	it("preserves colon-containing grep paths and rg context lines", function()
		local grep_render = search.render_tool({
			tool = "grep",
			state = {
				status = "completed",
				input = { pattern = "local" },
				output = "path:with:colon/file.lua:12:3:local x = 1",
			},
			metadata = { matches = 1 },
		}, true)
		assert(render_text(grep_render):find("path:with:colon/file.lua:12:3:local x = 1", 1, true), "grep widget should render colon-containing paths")

		local rg_render = rg.render_tool({
			tool = "rg",
			state = {
				status = "completed",
				input = { pattern = "local" },
				output = "path:with:colon/file.lua-12-local x = 1",
			},
			metadata = { matches = 1 },
		}, true)
		assert(render_text(rg_render):find("path:with:colon/file.lua-12-local x = 1", 1, true), "rg widget should render context lines with colon-containing paths")
	end)

	it("sanitizes binary and multiline panel input", function()
		local binary_line = "PAR1" .. string.char(0) .. "data"
		assert(render.sanitize_buffer_line(binary_line) == "PAR1<NUL>data", "NUL byte was not sanitized")
		assert(render.sanitize_buffer_line("one\ntwo\r\nthree") == "one ↵ two ↵ three", "newlines were not sanitized")
		local wrapped_binary = render.wrap_text_with_ranges(binary_line, 80)
		assert(wrapped_binary[1].text == "PAR1<NUL>data", "binary line did not wrap as sanitized text")
		local panel_result = { lines = {}, highlights = {} }
		assert(
			pcall(render.add_panel_line, panel_result, binary_line, "Normal", { width = 40 }),
			"panel line render failed on binary text"
		)
		assert(not panel_result.lines[1]:find(string.char(0), 1, true), "panel line kept a raw NUL byte")
	end)

	it("keeps combining marks with their base characters and byte ranges", function()
		local source = "éé界́a"
		local chunks = render.wrap_text_with_ranges(source, 2)
		assert.same({
			{ text = "éé", byte_start = 0, byte_end = 6 },
			{ text = "界́", byte_start = 6, byte_end = 11 },
			{ text = "a", byte_start = 11, byte_end = 12 },
		}, chunks)
		for _, chunk in ipairs(chunks) do
			assert.equals(chunk.text, source:sub(chunk.byte_start + 1, chunk.byte_end))
		end
		local tabstop = vim.bo.tabstop
		vim.bo.tabstop = 8
		local expanded = render.expand_tabs("é\tx", 0)
		vim.bo.tabstop = tabstop
		assert.equals("é" .. string.rep(" ", 7) .. "x", expanded)
	end)

	it("sanitizes task descriptions and summary titles", function()
		local multiline_task = chat_tasks.render_task_tool({
			id = "task_newline",
			tool = "task",
			state = {
				status = "running",
				input = {
					subagent_type = "build",
					description = "Investigate\nnewline crash",
				},
				metadata = {
					summary = {
						{
							id = "1",
							tool = "bash",
							state = {
								status = "running",
								title = "Run\nchecks",
								input = {},
							},
						},
					},
				},
			},
		}, false)
		assert_no_buffer_newlines(multiline_task.lines, "task renderer")
		assert(multiline_task.lines[1]:find("Investigate ↵ newline crash", 1, true), "task description was not sanitized")
		assert(multiline_task.lines[2]:find("Run ↵ checks", 1, true), "task summary title was not sanitized")
	end)

	it("labels running read summaries and native tool counts", function()
		local running_read_task = chat_tasks.render_task_tool({
			id = "task_running_read",
			tool = "task",
			state = {
				status = "running",
				input = {
					subagent_type = "build",
					description = "Inspect file",
				},
				metadata = {
					tool_calls = 3,
					summary = {
						{
							id = "1",
							tool = "read",
							state = {
								status = "running",
								title = "",
								input = { filePath = "/tmp/config.lua" },
							},
						},
					},
				},
			},
		}, false)
		assert(running_read_task.lines[2]:find("Read /tmp/config.lua", 1, true), "running task did not label current read")
		assert(running_read_task.lines[2]:find("3 toolcalls", 1, true), "running task did not parse snake_case count")

		local running_count_task = chat_tasks.render_task_tool({
			id = "task_toolcall_count",
			tool = "task",
			state = {
				status = "running",
				input = {
					subagent_type = "build",
					description = "Count tools",
				},
				metadata = {
					toolCallCount = "2",
				},
			},
		}, false)
		assert(running_count_task.lines[2]:find("2 toolcalls", 1, true), "running task did not parse toolCallCount")
	end)

	it("sanitizes generic tool headers and body lines", function()
		local generic_tool = render.render_tool_line({
			tool = "custom",
			state = {
				status = "running",
				input = {
					description = "Generated\nheader",
					payload = "body\nvalue",
				},
				output = "output\r\nvalue",
				error = "error\nvalue",
			},
		}, true)
		assert_no_buffer_newlines(generic_tool.lines, "generic tool renderer")
		assert(generic_tool.lines[1]:find("Generated ↵ header", 1, true), "generic tool header was not sanitized")
	end)

	it("wraps panel helpers and preserves prefix, blank and text highlights", function()
		local panel = require("opencode.ui.panel")
		local helpers = panel.create_helpers({
			prefix = "| ",
			blank_prefix = "|",
			border_hl = "PanelBorderTest",
			default_hl = "PanelDefaultTest",
		})
		local result = { lines = {}, highlights = {} }
		local _, _, wrapped_rows = helpers.add_line(result, "wrapped words for panel factory", nil, { width = 14 })
		assert(#wrapped_rows > 1, "panel factory add_line should preserve wrapping")
		for _, row in ipairs(wrapped_rows) do
			assert(row.line:sub(1, 2) == "| ", "panel factory wrapped rows should keep prefix")
		end
		local _, _, raw_rows = helpers.add_raw_line(result, "raw words stay together", "PanelRawTest", {
			width = 14,
			wrap = false,
		})
		assert(#raw_rows == 1, "panel factory raw lines should preserve wrap=false")
		helpers.add_blank(result)
		assert(result.lines[#result.lines]:sub(1, 1) == "|", "panel factory blank line should keep blank prefix")
		helpers.add_separator(result)
		assert(result.lines[#result.lines] == "", "panel factory separator should append a trailing blank line")
		helpers.highlight_text(result, wrapped_rows, "wrapped", "PanelWrappedTextTest")
		local saw_text_highlight = false
		local saw_prefix_highlight = false
		for _, hl in ipairs(result.highlights) do
			saw_text_highlight = saw_text_highlight or hl.hl_group == "PanelWrappedTextTest"
			saw_prefix_highlight = saw_prefix_highlight or hl.hl_group == "PanelBorderTest"
		end
		assert(saw_text_highlight, "panel factory highlight_text should add text highlights")
		assert(saw_prefix_highlight, "panel factory should preserve border prefix highlights")
	end)

	it("reads bash input, output and errors only from canonical state", function()
		local bash = require("opencode.ui.chat.bash")

		local bash_result = bash.render_tool({
			tool = "bash",
			input = { command = "echo stale" },
			output = "stale",
			state = {
				status = "completed",
				input = { command = "echo hi" },
				output = "hi",
			},
		}, false)
		assert(bash_result and table.concat(bash_result.lines, "\n"):find("Shell", 1, true), "bash widget should render")
		assert(not render_text(bash_result):find("stale", 1, true), "bash widget should only use canonical state fields")

		local bash_error = bash.render_tool({
			tool = "bash",
			state = {
				status = "error",
				input = { command = "false" },
				error = "boom",
			},
		}, false)
		assert(render_text(bash_error):find("boom", 1, true), "bash widget should render canonical state.error")
	end)

	it("shows the read path and limits only collapsed output", function()
		local read = require("opencode.ui.chat.read")
		local read_output = {}
		for i = 1, 12 do
			table.insert(read_output, tostring(i) .. ": local value_" .. tostring(i) .. " = " .. tostring(i))
		end
		local read_collapsed = read.render_tool({
			tool = "read",
			state = {
				status = "completed",
				input = { path = "lua/opencode/init.lua" },
				output = table.concat(read_output, "\n"),
			},
		}, false)
		local read_expanded = read.render_tool({
			tool = "read",
			state = {
				status = "completed",
				input = { path = "lua/opencode/init.lua" },
				output = table.concat(read_output, "\n"),
			},
		}, true)
		assert(render_text(read_collapsed):find("Read lua/opencode/init.lua", 1, true), "read widget should render native state.input.path")
		assert(render_text(read_collapsed):find("more lines", 1, true), "read widget should show collapsed overflow")
		assert(not render_text(read_expanded):find("more lines", 1, true), "read widget should hide overflow when expanded")
	end)

end)
