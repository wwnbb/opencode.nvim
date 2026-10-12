local chat_surface = require("tests.helpers.chat_surface")
local app = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local chat_state = require("opencode.ui.chat.state")
local state = chat_state.state
local tasks = require("opencode.ui.chat.tasks")
local tree = require("opencode.ui.chat.widget_tree")
local projection = require("opencode.protocol.messages")

describe("native shell completion notifications", function()
	local surface, columns, serial
	local session_id = "shell-notifications"

	before_each(function()
		columns, serial = vim.o.columns, 0
		vim.o.columns = 160
		surface = chat_surface.setup()
		state.config = vim.deepcopy(app.get_config().chat)
		state.config.session_tabs.enabled = false
		app.set_session(session_id, "Shell notifications")
		app.set_session_status(session_id, { type = "idle" })
		require("opencode.ui.chat.keymaps").setup_buffer(surface.bufnr)
	end)

	after_each(function()
		chat_surface.restore(surface)
		vim.o.columns = columns
	end)

	local function notification(command, output, metadata)
		serial = serial + 1
		metadata = vim.tbl_extend("force", {
			source = "shell", state = "completed", exit = 0,
			shellID = "shell-long-identity-0123456789", jobID = "job-long-identity-9876543210",
		}, metadata or {})
		-- This is the native format: neither command nor output is XML escaped.
		return {
			id = "shell-notice-" .. serial, type = "synthetic", time = { created = serial },
			description = command, metadata = metadata,
			text = '<shell id="' .. (metadata.jobID or metadata.shellID) .. '" state="'
				.. metadata.state .. '" command="' .. command .. '">\n' .. output .. "\n</shell>",
		}
	end

	local function show(native)
		local projected = projection.project(session_id, native)
		sync.clear_session_messages(session_id)
		sync.handle_session_messages(session_id, { projected })
		chat.do_render()
		return projected.parts[1].id, projected
	end

	local function block_lines(id)
		local position = assert(tree.find(state.tools, id), "notification must be a navigable tool leaf")
		return vim.api.nvim_buf_get_lines(surface.bufnr, position.start_line, position.end_line + 1, false)
	end

	local function block_text(id)
		return table.concat(block_lines(id), "\n")
	end

	local function contains(text, value)
		assert.is_truthy(text:find(value, 1, true), "missing literal text: " .. value)
	end

	local function absent(text, value)
		assert.is_nil(text:find(value, 1, true), "unexpected text: " .. value)
	end

	local function panel_line(lines, value)
		local expected = "▏  " .. value
		for _, line in ipairs(lines) do
			if line:sub(1, #expected) == expected and line:sub(#expected + 1):match("^ *$") then return end
		end
		error("output line changed: " .. value .. "\n" .. vim.inspect(lines))
	end

	local function focus(id)
		local position = assert(tree.find(state.tools, id))
		vim.api.nvim_set_current_win(surface.winid)
		vim.api.nvim_win_set_cursor(surface.winid, { position.start_line + 1, 0 })
		assert.equals(id, tasks.get_tool_at_cursor())
	end

	local function key(id, lhs)
		focus(id)
		local mapping = vim.fn.maparg(lhs, "n", false, true)
		assert.equals(1, mapping.buffer)
		assert.is_function(mapping.callback)
		mapping.callback()
	end

	local function header_highlight(id, group)
		local position = assert(tree.find(state.tools, id))
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(surface.bufnr, chat_state.chat_hl_ns,
			{ position.start_line, 0 }, { position.start_line, -1 }, { details = true })) do
			if mark[4].hl_group == group then return end
		end
		error("notification header is missing " .. group)
	end

	it("renders an empty completion as a compact panel while preserving the native text and DTO", function()
		for _, output in ipairs({ "", "(no output)" }) do
			local native = notification("sleep 60", output)
			local original = vim.deepcopy(native)
			local id, projected = show(native)
			local text = block_text(id)
			contains(text, "Shell finished")
			contains(text, "$ sleep 60")
			contains(text, "No output")
			absent(text, "<shell")
			absent(text, "</shell>")
			absent(text, native.metadata.shellID)
			absent(text, native.metadata.jobID)
			assert.equals("tool", tree.find(state.tools, id).kind)
			assert.equals("text", projected.parts[1].type)
			assert.is_false(tasks.is_animating_tool_part(projected.parts[1]))
			assert.equals(native.text, projected.parts[1].text)
			assert.same(original, projected.info._native)
			assert.same(original, native)
			assert.is_not.equals(native.metadata, projected.parts[1].shell_notification.metadata)
			header_highlight(id, "DiagnosticOk")
		end
	end)

	it("expands with the leaf toggle, O and Enter, and retains expansion after a full render", function()
		local rows = {}
		for index = 1, 14 do rows[index] = string.format("output-row-%02d", index) end
		local native = notification("printf result", table.concat(rows, "\n"))
		local id = show(native)
		contains(block_text(id), rows[8])
		absent(block_text(id), rows[9])
		contains(block_text(id), "6 more rows")
		tasks.handle_tool_toggle(id)
		assert.is_true(state.expanded_tools[id])
		contains(block_text(id), rows[14])
		contains(block_text(id), "Shell ID: " .. native.metadata.shellID)
		contains(block_text(id), "Job ID: " .. native.metadata.jobID)
		chat.do_render()
		assert.is_true(state.expanded_tools[id])
		contains(block_text(id), rows[14])
		key(id, "O")
		assert.is_nil(state.expanded_tools[id])
		absent(block_text(id), rows[9])
		key(id, "<CR>")
		assert.is_true(state.expanded_tools[id])
		contains(block_text(id), rows[14])
		key(id, "<CR>")
		assert.is_nil(state.expanded_tools[id])
		absent(block_text(id), "Shell ID:")
	end)

	it("shows native failure and cancellation states with their matching header colors", function()
		local cases = {
			{ metadata = { exit = 0 }, heading = "Shell finished", highlight = "DiagnosticOk" },
			{ metadata = { exit = 2 }, heading = "Shell failed · exit 2", highlight = "OpenCodeBashError" },
			{ metadata = { state = "error" }, heading = "Shell failed", highlight = "OpenCodeBashError" },
			{ metadata = { timeout = true }, heading = "Shell failed · timed out", highlight = "OpenCodeBashError" },
			{ metadata = { signal = "SIGTERM" }, heading = "Shell failed · SIGTERM", highlight = "OpenCodeBashError" },
			{ metadata = { state = "cancelled" }, heading = "Shell cancelled", highlight = "DiagnosticWarn" },
		}
		for _, case in ipairs(cases) do
			local id = show(notification("sleep 60", "literal result", case.metadata))
			contains(block_text(id), case.heading)
			contains(block_text(id), "literal result")
			header_highlight(id, case.highlight)
		end
		local id = show(notification("printf result", "partial result", { truncated = true }))
		contains(block_text(id), "Output truncated by server")
	end)

	it("preserves quotes, multiline commands, closing tags and literal wrapper delimiters", function()
		local command = 'printf "%s" "quote"\nprintf ">\n"\nlast-command'
		local output = 'literal </shell>\n<shell id="inner" state="error" command="fake">\n">\ninner output\n</shell>\nlast output'
		local native = notification(command, output)
		local original = vim.deepcopy(native)
		local id, projected = show(native)
		tasks.handle_tool_toggle(id)
		local lines = block_lines(id)
		for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
			panel_line(lines, line)
		end
		contains(block_text(id), '$ printf "%s" "quote"')
		contains(block_text(id), '  printf ">')
		contains(block_text(id), "  last-command")
		absent(block_text(id), '<shell id="' .. native.metadata.jobID .. '"')
		assert.equals(original.text, projected.parts[1].text)
		assert.same(original, projected.info._native)
		assert.same(original, native)
	end)

	it("limits preview by wrapped output rows and keeps panels within the chat width", function()
		vim.o.columns = 42
		local output = string.rep("x", 400)
		local id = show(notification("printf " .. string.rep("z", 60), output))
		local preview_rows = 0
		for _, line in ipairs(block_lines(id)) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(surface.winid))
			if line:match("^▏  x+$") then preview_rows = preview_rows + 1 end
		end
		assert.equals(8, preview_rows)
		contains(block_text(id), "more rows")
		tasks.handle_tool_toggle(id)
		local expanded = block_lines(id)
		local reconstructed = {}
		for _, line in ipairs(expanded) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(surface.winid))
			local body = line:match("^▏  (x+) *$")
			if body then reconstructed[#reconstructed + 1] = body end
		end
		assert.equals(output, table.concat(reconstructed), vim.inspect(expanded))
		assert.is_true(#reconstructed > 8)
		chat.do_render()
		assert.is_true(state.expanded_tools[id])
		local rerendered = {}
		for _, line in ipairs(block_lines(id)) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(surface.winid))
			local body = line:match("^▏  (x+) *$")
			if body then rerendered[#rerendered + 1] = body end
		end
		assert.equals(output, table.concat(rerendered))
	end)

	it("keeps malformed or mismatched wrappers and native raw failure notices readable", function()
		local valid = notification("printf safe", "literal body", { shellID = "shell", jobID = "job" })
		local cases = {}
		for _, mismatch in ipairs({
			{ from = 'id="job"', to = 'id="other"' },
			{ from = 'state="completed"', to = 'state="error"' },
			{ from = 'command="printf safe"', to = 'command="other"' },
			{ from = "\n</shell>", to = "\n</shell" },
		}) do
			local native = vim.deepcopy(valid)
			local first, last = assert(native.text:find(mismatch.from, 1, true))
			native.text = native.text:sub(1, first - 1) .. mismatch.to .. native.text:sub(last + 1)
			cases[#cases + 1] = native
		end
		local user_shell = vim.deepcopy(valid)
		user_shell.description = nil
		user_shell.text = "The following shell command was executed by the user:\n" .. user_shell.text
		cases[#cases + 1] = user_shell
		cases[#cases + 1] = {
			id = "failed-start", type = "synthetic", time = { created = 1 }, description = "missing-command",
			text = "User shell command failed to start:\nmissing-command\n\nExecutable not found",
			metadata = { source = "shell", state = "error" },
		}
		for index, native in ipairs(cases) do
			native.id = "fallback-" .. index
			local original = vim.deepcopy(native)
			local id, projected = show(native)
			tasks.handle_tool_toggle(id)
			local lines = block_lines(id)
			for _, line in ipairs(vim.split(native.text, "\n", { plain = true })) do
				panel_line(lines, line)
			end
			assert.equals(original.text, projected.parts[1].text)
			assert.same(original, projected.info._native)
		end
	end)

	it("does not interpret XML from ordinary user or assistant messages or an unfinished shell", function()
		local shell = notification("sleep 60", "literal body")
		local cases = {
			{ id = "plain-user", type = "user", text = shell.text, metadata = shell.metadata },
			{ id = "plain-assistant", type = "assistant", content = { { type = "text", text = shell.text,
				shell_notification = { description = shell.description, metadata = shell.metadata } } }, metadata = shell.metadata },
			{ id = "unfinished", type = "synthetic", text = shell.text, description = shell.description,
				metadata = { source = "shell", state = "running" } },
		}
		for _, native in ipairs(cases) do
			local id, projected = show(native)
			assert.is_nil(projected.parts[1].shell_notification)
			assert.is_nil(tree.find(state.tools, id))
			assert.equals(shell.text, projected.parts[1].text)
			local text = table.concat(vim.api.nvim_buf_get_lines(surface.bufnr, 0, -1, false), "\n")
			absent(text, "Shell finished")
			contains(text, "literal body")
		end
	end)
end)
