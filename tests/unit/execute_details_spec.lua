local function press(popup, key)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(popup.bufnr, "n")) do
		if mapping.lhs == key then
			return mapping.callback()
		end
	end
	error("Missing execute details mapping: " .. key)
end

local function text(popup)
	return table.concat(vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false), "\n")
end

describe("execute details inspector", function()
	local details
	local previous
	local columns

	before_each(function()
		details = require("opencode.ui.chat.execute_details")
		previous = vim.api.nvim_get_current_win()
		columns = vim.o.columns
	end)

	after_each(function()
		details.close()
		vim.o.columns = columns
		vim.wait(20)
	end)

	it("switches readable result, exact raw output, original code, and all MCP calls", function()
		local calls = {}
		for index = 1, 20 do
			calls[index] = { tool = "server.action_" .. index, status = "completed", input = { index = index } }
		end
		local raw = '{"text":"first\\nsecond","value":1}\n\nLogs:\nfinished\n'
		local code = 'return await tools["server"].action({ value: 1 });\n'
		local popup = details.open({ state = { status = "completed", output = raw,
			input = { code = code }, metadata = { toolCalls = calls } } })
		assert(popup.view == "result")
		assert(text(popup):find("first\n", 1, true), "result should decode escaped newlines")
		assert(text(popup):find("Logs:", 1, true), "result should keep logs")
		assert(vim.bo[popup.bufnr].filetype == "opencode_execute_details")
		assert(not vim.bo[popup.bufnr].modifiable and vim.bo[popup.bufnr].readonly)
		press(popup, "2")
		assert(text(popup) == raw, "raw must retain every byte including trailing newlines")
		press(popup, "3")
		assert(text(popup) == code, "code should contain the script without its JSON wrapper")
		press(popup, "4")
		assert(text(popup):find("server.action_20", 1, true), "calls should not stop at the preview limit")
		assert(text(popup):find("Input", 1, true), "call inputs should be inspectable")
		assert(text(popup):find("✓ server.action_1\ncompleted\n", 1, true), "calls should lead with their name and status")
		press(popup, "1")
		assert(popup.view == "result")
	end)

	it("keeps scrolling and yanking available and restores focus on close", function()
		local raw = table.concat(vim.fn.range(1, 100), "\n")
		local popup = details.open({ state = { status = "completed", output = raw } })
		local win = popup.winid
		local wins = details.get_winids()
		assert(wins[1] == win)
		vim.api.nvim_feedkeys("G", "xt", false)
		assert(vim.api.nvim_win_get_cursor(win)[1] == 100, "normal scroll must reach full output")
		vim.api.nvim_feedkeys('"zyy', "xt", false)
		assert(vim.fn.getreg("z") == "100\n", "normal yank must remain available")
		press(popup, "3")
		press(popup, "1")
		assert(vim.api.nvim_win_get_cursor(win)[1] == 100, "each view should retain its cursor")
		press(popup, "q")
		assert(vim.api.nvim_win_is_valid(win), "closing details must retain the original chat window")
		assert(not vim.api.nvim_buf_is_valid(popup.bufnr), "closing should dispose the scratch result buffer")
		assert(not details.is_open())
		assert(vim.api.nvim_get_current_win() == previous)
		assert.same({}, details.get_winids())
	end)

	it("reuses the chat window and restores its buffer, options and scroll position", function()
		local chat_state = require("opencode.ui.chat.state").state
		local saved = { visible = chat_state.visible, winid = chat_state.winid }
		chat_state.visible, chat_state.winid = true, previous
		local original_buf = vim.api.nvim_win_get_buf(previous)
		local original_bar, original_wrap = vim.wo[previous].winbar, vim.wo[previous].wrap
		local windows = vim.api.nvim_list_wins()
		local popup = details.open({ state = { output = '{"title":"Page title","main":"first\\nsecond"}' } })
		chat_state.visible, chat_state.winid = saved.visible, saved.winid
		assert(popup.winid == previous, "details should reuse the actual chat window")
		assert.same(windows, vim.api.nvim_list_wins(), "details should not add shadow-casting floats")
		assert(vim.api.nvim_win_get_buf(previous) == popup.bufnr)
		local bar = vim.api.nvim_eval_statusline(vim.wo[previous].winbar, { winid = previous, use_winbar = true }).str
		assert(bar:find("← Back", 1, true) and bar:find("Result", 1, true))
		assert(text(popup):find("title\nPage title", 1, true), "field keys should be headings above their values")
		assert(text(popup):find("main\nfirst\nsecond", 1, true))
		press(popup, "3")
		assert(popup.view == "code")
		press(popup, "<S-Tab>")
		assert(popup.view == "raw")
		press(popup, "<Tab>")
		assert(popup.view == "code")
		local click_id = popup.bufnr * 10 + 2
		details.click_tab(click_id, 1, "l")
		assert(popup.view == "raw")
		press(popup, "<BS>")
		assert(not details.is_open())
		assert(vim.api.nvim_win_get_buf(previous) == original_buf)
		assert(vim.wo[previous].winbar == original_bar and vim.wo[previous].wrap == original_wrap)
		details.click_tab(click_id, 1, "l")
		assert(not details.is_open(), "stale clicks must do nothing after close")
	end)

	it("keeps the chat float open while its inspector has focus", function()
		local chat_state = require("opencode.ui.chat.state").state
		local focus = require("opencode.ui.chat.float_focus")
		local saved = { visible = chat_state.visible, config = chat_state.config,
			winid = chat_state.winid, tabpage = chat_state.tabpage }
		chat_state.visible = true
		chat_state.config = { layout = "float" }
		chat_state.winid = previous
		chat_state.tabpage = vim.api.nvim_get_current_tabpage()
		local closed = false
		focus.setup({ close = function() closed = true end })
		local popup = details.open({ state = { output = "inspect" } })
		vim.wait(20)
		focus.clear()
		chat_state.visible, chat_state.config = saved.visible, saved.config
		chat_state.winid, chat_state.tabpage = saved.winid, saved.tabpage
		assert(not closed, "related filetype should protect the parent chat float")
		popup:unmount()
	end)

	it("keeps readable paragraphs bounded while Raw retains the full source", function()
		local raw = string.rep("long paragraph ", 30)
		local popup = details.open({ state = { output = vim.json.encode({ body = raw }) } })
		for _, line in ipairs(vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)) do
			assert(vim.fn.strdisplaywidth(line) <= math.min(100, vim.api.nvim_win_get_width(popup.winid)))
		end
		press(popup, "2")
		assert(text(popup) == vim.json.encode({ body = raw }))
	end)

	it("survives streaming input and preserves error and cancellation output", function()
		local popup = details.open({ state = { status = "running", input = '{"code":"return await' } }, { view = "code" })
		assert(text(popup) == "Code is still being received.")
		press(popup, "4")
		assert(text(popup) == "No MCP calls recorded yet.")
		popup = details.open({ state = { status = "error", output = "", error = "Failed to call remote tool" } })
		assert(text(popup):find("Failed to call remote tool", 1, true))
		press(popup, "2")
		assert(text(popup) == "Failed to call remote tool")
		popup = details.open({ state = { status = "completed", output = "Execution cancelled.",
			metadata = { error = true } } })
		assert(text(popup) == "Execution cancelled.")
	end)

	it("shows attachment names, MIME types and resource URIs without binary data", function()
		local popup = details.open({ state = { output = "Saved result", files = {
			{ filename = "capture.png", mime = "image/png", url = "data:image/png;base64,SECRET_BINARY" },
		}, content = {
			{ type = "image", filename = "capture.png", mimeType = "image/png", data = "SECRET_BINARY" },
		} } })
		local result = text(popup)
		assert(result:find("capture.png (image/png)", 1, true))
		local _, copies = result:gsub("capture%.png", "")
		assert(copies == 1, "projected files also in content must only appear once")
		assert(not result:find("SECRET_BINARY", 1, true))
		press(popup, "2")
		assert(text(popup) == "Saved result", "attachments must not change the raw tool output")
		popup = details.open({ state = { content = {
			{ type = "resource", resource = { uri = "mcp://server/report", mimeType = "text/plain" } },
			{ type = "image", mimeType = "image/jpeg", data = "SECRET_BINARY" },
		} } })
		assert(text(popup):find("mcp://server/report", 1, true), "content should be available without projected files")
		assert(not text(popup):find("SECRET_BINARY", 1, true))
	end)

	it("shows errors alongside partial output without changing original Raw", function()
		local popup = details.open({ state = { status = "error", output = "Partial progress\r\n",
			error = { message = "Remote tool disconnected" } } })
		assert(text(popup):find("Remote tool disconnected", 1, true))
		assert(text(popup):find("Partial progress", 1, true))
		press(popup, "2")
		assert(text(popup) == "Partial progress\r\n")
	end)

	it("treats absent native output as pending and displays NUL visibly", function()
		local popup = details.open({ state = { status = "streaming", output = vim.NIL, error = vim.NIL } })
		assert(text(popup) == "No output yet.")
		press(popup, "3")
		assert(text(popup) == "Code is still being received.")
		press(popup, "2")
		assert(text(popup) == "", "absent output should not become the text null")
		popup = details.open({ state = { output = "before\0after\r\n" } }, { view = "raw" })
		assert(text(popup) == "before<NUL>after\r\n", "NUL must be visible while other original bytes remain intact")
	end)

	it("resizes into a narrow viewport and cleans up after the window is closed", function()
		vim.cmd("vnew")
		local popup = details.open({ state = { output = "A long line that can wrap naturally in a narrow viewport." } })
		local win = popup.winid
		vim.o.columns = 32
		vim.api.nvim_exec_autocmds("VimResized", {})
		local pos = vim.api.nvim_win_get_position(win)
		assert(pos[1] >= 0 and pos[2] >= 0)
		assert(pos[2] + vim.api.nvim_win_get_width(win) <= vim.o.columns)
		assert(pos[1] + vim.api.nvim_win_get_height(win) <= vim.o.lines - vim.o.cmdheight)
		assert(vim.wo[win].wrap)
		vim.api.nvim_win_close(win, true)
		vim.wait(20)
		assert(not details.is_open())
	end)

	it("cleanup can close without stealing focus from the active window", function()
		local popup = details.open({ state = { output = "done" } })
		local win = popup.winid
		vim.api.nvim_set_current_win(previous)
		vim.cmd("vnew")
		local next_win = vim.api.nvim_get_current_win()
		details.close({ restore_focus = false })
		assert(vim.api.nvim_get_current_win() == next_win)
		assert(vim.api.nvim_win_is_valid(win), "cleanup must keep the reused window")
		assert(not vim.api.nvim_buf_is_valid(popup.bufnr))
		vim.api.nvim_win_close(next_win, true)
		details.close()
	end)
end)
