-- Every tool row follows the compact-row rules in the widget skill: header at
-- column 1, " · " between parts, status words only when a call did not simply
-- complete, sub-lines at five spaces, and one blank row at the end.
local render = require("opencode.ui.chat.render")
local tasks = require("opencode.ui.chat.tasks")
local bash = require("opencode.ui.chat.bash")
local exploration = require("opencode.ui.chat.exploration_tool")
local file_edits = require("opencode.ui.chat.file_edit_results")
local spinner = require("tests.helpers.tool_render").spinner

local function lines(result)
	return vim.tbl_map(function(line) return (line:gsub("%s+$", "")) end, result.lines)
end

describe("tool row vocabulary", function()
	it("renders tools without a widget as compact rows", function()
		local item = { tool = "github_create_issue", state = { status = "error",
			input = { description = "Open an issue" }, error = "Bad credentials\nCheck the token" } }
		assert.same({ " ▸ Github Create Issue · Open an issue · Failed", "     Bad credentials", "     Check the token", "" },
			lines(render.render_tool_line(item, false)))
		local opened = lines(render.render_tool_line(item, true))
		assert.equals(" ▾ Github Create Issue · Open an issue · Failed", opened[1])
		assert.is_truthy(opened[2]:find("   ┌", 1, true))
		assert.is_true(vim.tbl_contains(opened, "   │ Error"))
		assert.equals("", opened[#opened])
		local running = lines(render.render_tool_line({ tool = "custom", state = { status = "running" } }, false))
		assert.is_truthy(running[1]:find("^ Custom · Running "))
		assert.is_not_nil(spinner(running[1]))
		assert.same({ " Custom · 1.5s", "" },
			lines(render.render_tool_line({ tool = "custom", state = { status = "completed", time = { start = 0, ["end"] = 1500 } } }, false)))
	end)

	it("renders file edit results as compact rows with the fold marker beside their status", function()
		local item = { tool = "edit", state = { status = "completed", title = "Edit applied",
			input = { filePath = vim.fn.getcwd() .. "/notes.txt", oldString = "a", newString = "b" },
			metadata = { diff = "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-a\n+b\n",
				filediff = { file = vim.fn.getcwd() .. "/notes.txt", additions = 1, deletions = 1 } } } }
		assert.same({ " ▸ ✓ Edit applied · 1 file · +1 -1", "     ✓ M notes.txt · +1 -1", "" },
			lines(file_edits.render_tool(item, false)))
		local opened = lines(file_edits.render_tool(item, true))
		assert.equals(" ▾ ✓ Edit applied · 1 file · +1 -1", opened[1])
		assert.equals("   │ ✓ modified notes.txt", opened[3])
		local pending = lines(file_edits.render_tool({ tool = "edit", state = { status = "running", input = {} } }, false))
		assert.equals(2, #pending)
		assert.is_truthy(pending[1]:find("^ ~ Preparing file changes… "))
		assert.is_not_nil(spinner(pending[1]))
	end)

	it("counts glob files, spins standalone exploration rows and leaves the spinner to groups", function()
		local glob = { tool = "glob", state = { status = "completed", input = { pattern = "*.lua" }, metadata = { count = 1 } } }
		assert.equals(' ● Glob "*.lua" (1 file)', lines(exploration.render(glob, false))[1])
		local read = { tool = "read", state = { status = "running", input = { path = vim.fn.getcwd() .. "/lua/x.lua" } } }
		local standalone = lines(exploration.render(read, false))[1]
		assert.is_truthy(standalone:find("^ → Read lua/x.lua "))
		assert.is_not_nil(spinner(standalone))
		assert.equals(" → Read lua/x.lua", lines(exploration.render(read, false, { grouped = true }))[1])
	end)

	it("separates task header parts with a dot and ends every task with a blank row", function()
		local done = lines(tasks.render_task_tool({ id = "t", tool = "task", state = { status = "completed",
			input = { subagent_type = "explore", description = "Find stuff" },
			metadata = { tool_calls = 2 }, time = { start = 0, ["end"] = 62000 } } }, false))
		assert.same({ "✓ Explore Task · Find stuff", "  ↳ 2 tool calls · 1m 2s", "" }, done)
		local pending = lines(tasks.render_task_tool({ id = "p", tool = "task", state = { status = "running", input = {} } }, false))
		assert.equals(2, #pending)
		assert.is_truthy(pending[1]:find(" Delegating…$"))
		assert.equals("", pending[2])
	end)

	it("puts the bash exit code after a dot and shortens its working directory", function()
		local result = bash.render_tool({ tool = "bash", state = { status = "completed",
			input = { command = "false", description = "Fail", workdir = vim.fn.getcwd() .. "/lua" },
			output = "boom", metadata = { exit = 1 } } }, false)
		assert.is_true(vim.tbl_contains(lines(result), "▏  # Fail in lua · exit 1"))
		local here = bash.render_tool({ tool = "bash", state = { status = "completed",
			input = { command = "true", description = "Here", workdir = vim.fn.getcwd() }, output = "ok", metadata = { exit = 0 } } }, false)
		assert.is_true(vim.tbl_contains(lines(here), "▏  # Here"))
	end)
end)
