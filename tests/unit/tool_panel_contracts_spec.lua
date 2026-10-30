local render = require("opencode.ui.chat.render")
local chat_tasks = require("opencode.ui.chat.tasks")
local function render_text(result) return table.concat(result.lines, "\n") end
local function assert_no_buffer_newlines(lines)
	for _, line in ipairs(lines) do
		assert.is_nil(line:find("[\r\n]"))
	end
end

describe("tool and panel rendering contracts", function()
	before_each(function()
		require("opencode.sync").clear_all()
		require("opencode.state").reset()
		require("opencode.ui.chat.render_state").reset_chat_surface({ reset_expansions = true })
	end)
	after_each(function() require("opencode.sync").clear_all() end)

	it("preserves colon-containing grep paths and rg context lines", function()
		for _, case in ipairs({
			{ "search", "grep", "path:with:colon/file.lua:12:3:local x = 1" },
			{ "rg", "rg", "path:with:colon/file.lua-12-local x = 1" },
		}) do
			local result = require("opencode.ui.chat." .. case[1]).render_tool({ tool = case[2],
				state = { status = "completed", input = { pattern = "local" }, output = case[3] } }, true)
			assert.is_truthy(render_text(result):find(case[3], 1, true))
		end
	end)

	it("sanitizes binary and multiline text in panels, tasks and generic tools", function()
		local binary_line = "PAR1" .. string.char(0) .. "data"
		assert.equals("PAR1<NUL>data", render.sanitize_buffer_line(binary_line))
		assert.equals("one ↵ two ↵ three", render.sanitize_buffer_line("one\ntwo\r\nthree"))
		local panel_result = { lines = {}, highlights = {} }
		render.add_panel_line(panel_result, binary_line, "Normal", { width = 40 })
		assert.is_nil(panel_result.lines[1]:find(string.char(0), 1, true))
		local task = chat_tasks.render_task_tool({ id = "task_newline", tool = "task", state = {
			status = "running", input = { subagent_type = "build", description = "Investigate\nnewline crash" },
			metadata = { summary = { { id = "1", tool = "bash", state = { status = "running", title = "Run\nchecks", input = {} } } } },
		} }, false)
		assert_no_buffer_newlines(task.lines)
		assert.is_truthy(task.lines[1]:find("Investigate ↵ newline crash", 1, true))
		assert.is_truthy(task.lines[2]:find("Run ↵ checks", 1, true))
		local generic = render.render_tool_line({ tool = "custom", state = { status = "running",
			input = { description = "Generated\nheader", payload = "body\nvalue" }, output = "output\r\nvalue", error = "error\nvalue" } }, true)
		assert_no_buffer_newlines(generic.lines)
		assert.is_truthy(generic.lines[1]:find("Generated ↵ header", 1, true))
	end)

	it("keeps combining marks with their base characters and byte ranges", function()
		local mark = "\u{0301}"
		local chunks = render.wrap_text_with_ranges("e" .. mark .. "e" .. mark .. "界" .. mark .. "a", 2)
		assert.same({
			{ text = "e" .. mark .. "e" .. mark, byte_start = 0, byte_end = 6 },
			{ text = "界" .. mark, byte_start = 6, byte_end = 11 },
			{ text = "a", byte_start = 11, byte_end = 12 },
		}, chunks)
	end)

	it("labels running read summaries and native tool counts", function()
		local function task(metadata)
			return chat_tasks.render_task_tool({ id = "task", tool = "task", state = { status = "running",
				input = { subagent_type = "build", description = "Inspect" }, metadata = metadata } }, false)
		end
		local running = task({ tool_calls = 3, summary = { { id = "1", tool = "read",
			state = { status = "running", title = "", input = { filePath = "/tmp/config.lua" } } } } })
		assert.is_truthy(running.lines[2]:find("Read /tmp/config.lua", 1, true))
		assert.is_truthy(running.lines[2]:find("3 tool calls", 1, true))
		assert.is_truthy(task({ toolCallCount = "2" }).lines[2]:find("2 tool calls", 1, true))
	end)

	it("labels native shell summaries from commands while preserving description and title priority", function()
		local labels = require("opencode.ui.chat.tool_labels")
		for _, case in ipairs({
			{ input = { command = "echo one\r\necho two" }, label = "Shell echo one ↵ echo two" },
			{ input = { command = "echo command", description = "Run checks" }, label = "Shell Run checks" },
			{ input = { command = "echo command", description = "Run checks" }, title = "Native title", label = "Shell Native title" },
		}) do
			local projected = require("opencode.protocol.messages").project("child", {
				id = "assistant", type = "assistant", content = { {
					type = "tool", id = "shell-call", name = "shell",
					state = { status = "running", input = case.input, title = case.title },
				} },
			})
			local part = projected.parts[1]
			assert.equals("bash", part.tool)
			assert.equals(case.label, labels.format_summary_item_label(part))
		end
	end)

	it("wraps panel helper lines with their prefix and highlights", function()
		local helpers = require("opencode.ui.panel").create_helpers({
			prefix = "| ", blank_prefix = "|", border_hl = "PanelBorderTest", default_hl = "PanelDefaultTest",
		})
		local result = { lines = {}, highlights = {} }
		local _, _, wrapped_rows = helpers.add_line(result, "wrapped words for panel factory", nil, { width = 14 })
		assert.is_true(#wrapped_rows > 1)
		for _, row in ipairs(wrapped_rows) do assert.equals("| ", row.line:sub(1, 2)) end
		local _, _, raw_rows = helpers.add_raw_line(result, "raw words stay together", "PanelRawTest", { width = 14, wrap = false })
		assert.equals(1, #raw_rows)
		helpers.highlight_text(result, wrapped_rows, "wrapped", "PanelWrappedTextTest")
		local groups = {}
		for _, hl in ipairs(result.highlights) do groups[hl.hl_group] = true end
		assert.is_true(groups.PanelWrappedTextTest)
		assert.is_true(groups.PanelBorderTest)
	end)

	it("reads bash input, output and errors only from canonical state", function()
		local bash = require("opencode.ui.chat.bash")
		local result = bash.render_tool({ tool = "bash", input = { command = "echo stale" }, output = "stale",
			state = { status = "completed", input = { command = "echo hi" }, output = "hi" } }, false)
		assert.is_nil(render_text(result):find("stale", 1, true))
		local failed = bash.render_tool({ tool = "bash", state = { status = "error", input = { command = "false" }, error = "boom" } }, false)
		assert.is_truthy(render_text(failed):find("boom", 1, true))
	end)

	it("shows the read path and limits only collapsed output", function()
		local read = require("opencode.ui.chat.read")
		local output = {}
		for i = 1, 12 do output[i] = i .. ": local value_" .. i .. " = " .. i end
		local function render_read(expanded)
			return render_text(read.render_tool({ tool = "read", state = { status = "completed",
				input = { path = "lua/opencode/init.lua" }, output = table.concat(output, "\n") } }, expanded))
		end
		assert.is_truthy(render_read(false):find("Read lua/opencode/init.lua", 1, true))
		assert.is_truthy(render_read(false):find("more lines", 1, true))
		assert.is_nil(render_read(true):find("more lines", 1, true))
	end)

	it("fits headers and extracts panel durations", function()
		local panel = require("opencode.ui.chat.tool_panel")
		assert.equals("1m 2s", panel.duration({ start = 1000, ["end"] = 63000 }))
		assert.equals("10.0s", panel.duration({ created = 0, start = 5000, ["end"] = 15000, completed = 99 }, true))
		assert.is_nil(panel.duration({ start = 2, ["end"] = 1 }))
		local function cut(value, width) return require("opencode.util.text").truncate(value, width, "…") end
		local base = { prefix = "→ Get ", target = "example.com/path", suffix = " · Done · 2s", short_suffix = " · Done", spinner = "", truncate = cut }
		assert.equals("→ Get example.com/path · Done · 2s", panel.fit_header(vim.tbl_extend("force", base, { width = 60 })))
		assert.equals("→ Get example.com/pa… · Done", panel.fit_header(vim.tbl_extend("force", base, { width = 28 })))
		assert.equals("→ G…", panel.fit_header(vim.tbl_extend("force", base, { width = 4 })))
	end)
end)
