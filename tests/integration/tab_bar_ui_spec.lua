describe("native tab labels for OpenCode layouts", function()
	local editor, rows, highlights, window_heights, flushed_heights, tracked_header
	before_each(function()
		rows, highlights, window_heights, flushed_heights, tracked_header = {}, {}, {}, {}, nil
		editor = require("tests.helpers.embedded_editor").new({ on_notification = function(method, args)
			if method ~= "redraw" then return end
			for _, event in ipairs(args) do
				if event[1] == "hl_attr_define" then
					for index = 2, #event do highlights[event[index][1]] = event[index][2] end
				elseif event[1] == "win_pos" then
					for index = 2, #event do window_heights[vim.mpack.decode(event[index][2])] = event[index][6] end
				elseif event[1] == "flush" and tracked_header then
					flushed_heights[#flushed_heights + 1] = window_heights[tracked_header]
				elseif event[1] == "grid_line" then
					for index = 2, #event do
						local line = event[index]
						if line[1] == 1 then
							local row, column, highlight = line[2], line[3], 0
							rows[row] = rows[row] or {}
							for _, cell in ipairs(line[4]) do
								highlight = cell[2] or highlight
								for _ = 1, (cell[3] or 1) do
									rows[row][column] = { text = cell[1], highlight = highlight }
									column = column + 1
								end
							end
						end
					end
				end
			end
		end })
		editor.request("nvim_ui_attach", { 100, 30, { rgb = true, ext_linegrid = true } })
	end)
	after_each(function() if editor then editor.close() end end)

	local function open(tabline)
		editor.lua([[
			vim.o.tabline = ...
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab", session_tabs = { persist = false } } })
			require("opencode.client").get_messages = function(_, _, cb) cb(nil, {}) end
			local sessions = require("opencode.session")
			_G.chat, _G.workspace = require("opencode.ui.chat"), require("opencode.ui.chat.workspace")
			_G.seed = function(id)
				local session = { id = id, title = id }
				sessions.remember(session)
				return session
			end
			seed("native-a"); sessions.set_active("native-a", "native-a")
			chat.open()
			_G.first = chat.get_view()
		]], { tabline or "" })
	end

	local function native_label()
		editor.lua("vim.cmd('redraw!')")
		local cells = {}
		for column = 0, 99 do cells[#cells + 1] = rows[0] and rows[0][column] and rows[0][column].text or " " end
		return table.concat(cells)
	end

	it("shows readable labels when focusing a split or the shared tabbar", function()
		open()
		assert.equals("opencode", editor.lua("return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(first.bufnr), ':t')"))
		local expected = editor.lua([[
			local second = chat.create_split(first, seed("native-b"), "vertical")
			chat.focus_view(second)
			local expected = "opencode [" .. second.id .. "]"
			assert(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(second.bufnr), ":t") == expected)
			return expected
		]])
		local label = native_label()
		assert.is_truthy(label:find(expected, 1, true))
		assert.is_nil(label:find("o//c", 1, true))
		editor.lua("vim.api.nvim_set_current_win(require('opencode.ui.chat.workspace_bar').winid())")
		assert.is_truthy(native_label():find("opencode [tabs]", 1, true))
	end)

	it("supports numbered selection while the shared header has focus", function()
		open()
		local target = editor.lua([[
			chat.create_layout(seed("native-b"))
			chat.create_layout(seed("native-c"))
			local target = workspace.current().id
			workspace.select(workspace.list()[1].id)
			vim.api.nvim_set_current_win(require("opencode.ui.chat.workspace_bar").winid())
			return target
		]])
		editor.feed("3gt")
		assert.is_true(vim.wait(1000, function() return editor.lua("return workspace.current().id") == target end, 10))
	end)

	it("fits Unicode titles and custom separators while keeping the active layout visible", function()
		editor.request("nvim_ui_try_resize", { 80, 30 })
		open()
		local result = editor.lua([[
			local title = string.rep("界", 18)
			for index = 1, 5 do
				local session = seed("unicode-" .. index)
				session.title = title .. index
				require("opencode.session").remember(session)
				chat.create_layout(session)
			end
			workspace.select(workspace.list()[3].id)
			chat.get_view().config.session_tabs.separator = " ····· "
			local bar = require("opencode.ui.chat.workspace_bar")
			bar.update()
			local buf = vim.api.nvim_win_get_buf(bar.winid())
			local text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
			local active = false
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
				if mark[4].hl_group == "OpenCodeWinbarCurrent" then
					active = vim.fn.strdisplaywidth(text:sub(1, mark[3])) < 80
				end
			end
			return { width = vim.fn.strdisplaywidth(text), active = active }
		]])
		assert.is_true(result.active)
		assert.is_true(result.width <= 80)
	end)

	it("preserves a custom tabline while opening, splitting, switching and closing", function()
		local custom = "%#TabLineSel#My custom tabs%#TabLineFill#"
		open(custom)
		assert.equals(custom, editor.lua("return vim.o.tabline"))
		editor.lua([[
			local original = workspace.current().id
			chat.create_split(first, seed("native-b"), "vertical")
			chat.create_layout(seed("native-c"))
			workspace.select(original)
			workspace.close_current()
		]])
		assert.equals(custom, editor.lua("return vim.o.tabline"))
		assert.is_truthy(native_label():find("My custom tabs", 1, true))
		editor.lua("workspace.close_current()")
		assert.equals(custom, editor.lua("return vim.o.tabline"))
	end)

	it("keeps a one-line header when resizing and cycling empty and split layouts with gt and gT", function()
		editor.lua("vim.o.laststatus = 3")
		open()
		local layouts = editor.lua([[
			local ids = { workspace.current().id }
			chat.create_layout(seed("native-b"))
			ids[2] = workspace.current().id
			local split = chat.create_split(chat.get_view(), seed("native-c"), "vertical")
			chat.create_split(split, seed("native-nested"), "horizontal")
			chat.create_layout(seed("native-d"))
			ids[3] = workspace.current().id
			return ids
		]])
		for _, height in ipairs({ 50, 24, 38 }) do
			editor.request("nvim_ui_try_resize", { 100, height })
			for _, step in ipairs({ { "gt", 1, 1 }, { "gt", 2, 3 }, { "gT", 1, 1 }, { "gT", 3, 1 } }) do
				editor.feed(step[1])
				assert.is_true(vim.wait(2000, function()
					return editor.lua("return workspace.current().id == ...", { layouts[step[2]] })
				end, 10))
				local geometry = editor.lua([[
					local bar = require("opencode.ui.chat.workspace_bar").winid()
					local panes = {}
					for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
						if win ~= bar and vim.api.nvim_win_get_config(win).relative == "" then
							panes[#panes + 1] = { row = vim.api.nvim_win_get_position(win)[1],
								height = vim.api.nvim_win_get_height(win), fixed = vim.wo[win].winfixheight }
						end
					end
					return { header = vim.api.nvim_win_get_height(bar), top = vim.api.nvim_win_get_position(bar)[1],
						bottom = vim.o.lines - vim.o.cmdheight - 1, panes = panes,
						labels = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(bar), 0, 1, false)[1] }
				]])
				assert.equals(1, geometry.header, "layout switching must shrink the surviving header back to one line")
				assert.equals(step[3], #geometry.panes)
				local top, bottom = math.huge, 0
				for _, pane in ipairs(geometry.panes) do
					top, bottom = math.min(top, pane.row), math.max(bottom, pane.row + pane.height)
					assert.is_false(pane.fixed, "chat panes must not inherit the header's fixed height")
				end
				assert.equals(geometry.top + 2, top)
				assert.equals(geometry.bottom, bottom, "content fills the space below the header")
				for _, title in ipairs({ "native-a", "native-b", "native-d" }) do
					assert.is_truthy(geometry.labels:find(title, 1, true))
				end
			end
		end
	end)

	it("never flushes an expanded header to the GUI while switching layouts", function()
		editor.request("nvim_ui_detach", {})
		editor.request("nvim_ui_attach", { 100, 30, { rgb = true, ext_linegrid = true, ext_multigrid = true } })
		editor.lua("vim.o.laststatus = 3")
		open()
		local original = editor.lua([[
			local id = workspace.current().id
			chat.create_layout(seed("native-b"))
			return id
		]])
		editor.request("nvim_ui_try_resize", { 100, 50 })
		editor.lua("vim.cmd('redraw!')")
		tracked_header = editor.lua("return require('opencode.ui.chat.workspace_bar').winid()")
		editor.feed("gt")
		assert.is_true(vim.wait(2000, function()
			return editor.lua("return workspace.current().id == ...", { original })
		end, 10))
		editor.lua("vim.cmd('redraw!')")
		assert.is_true(#flushed_heights > 0, "the GUI must receive the completed layout")
		for _, height in ipairs(flushed_heights) do assert.equals(1, height, "every displayed frame keeps the header at one line") end
	end)

	it("keeps the header separator continuous where split panes meet", function()
		editor.lua([[
			vim.o.laststatus = 3
			vim.api.nvim_set_hl(0, "Normal", { fg = "#ffffff", bg = "#101010" })
			vim.api.nvim_set_hl(0, "WinSeparator", { link = "Normal" })
			vim.api.nvim_set_hl(0, "TabLine", { fg = "#00ff00", bg = "#303030" })
			vim.api.nvim_set_hl(0, "TabLineSel", { fg = "#000000", bg = "#40ff40" })
		]])
		open()
		local position = editor.lua([[
			local second = chat.create_split(first, seed("native-b"), "vertical")
			local bar = require("opencode.ui.chat.workspace_bar").winid()
			local pane = vim.api.nvim_win_get_position(second.winid)
			return { header = vim.api.nvim_win_get_position(bar)[1], separator = pane[1] - 1,
				content = pane[1], junction = pane[2] - 1 }
		]])
		editor.lua("vim.cmd('redraw!')")
		local function background(row, column)
			return highlights[rows[row][column].highlight].background
		end
		assert.equals(0x303030, background(position.header, 99), "header retains its tab background")
		for _, column in ipairs({ position.junction - 1, position.junction, position.junction + 1 }) do
			assert.equals(0x101010, background(position.separator, column), "separator background must match at the junction")
		end
		assert.equals(0x101010, background(position.content, position.junction), "lower vertical rail retains native styling")
	end)

	it("inherits reversed theme colors while preserving explicit color overrides", function()
		editor.lua([[
			vim.api.nvim_set_hl(0, "Normal", { fg = 0x657b83, bg = 0xfdf6e3 })
			vim.api.nvim_set_hl(0, "TabLine", { fg = 0x93a1a1, bg = 0xeee8d5, reverse = true })
			vim.api.nvim_set_hl(0, "TabLineSel", { fg = 0x657b83, bg = 0xfdf6e3, reverse = true })
		]])
		open()
		local function colors()
			return editor.lua([[
				return {
					inactive = vim.api.nvim_get_hl(0, { name = "OpenCodeWinbar", link = false }),
					active = vim.api.nvim_get_hl(0, { name = "OpenCodeWinbarCurrent", link = false }),
					idle = vim.api.nvim_get_hl(0, { name = "OpenCodeWinbarCurrentIdle", link = false }),
				}
			]])
		end
		local inherited = colors()
		assert.equals(0x93a1a1, inherited.inactive.bg)
		assert.equals(0x657b83, inherited.active.bg)
		assert.equals(0xfdf6e3, inherited.idle.fg)
		editor.lua([[
			first.config.session_tabs.colors = { active_bg = "#e4dfc8" }
			require("opencode.ui.chat.workspace_bar").update()
		]])
		local overridden = colors()
		assert.equals(0xe4dfc8, overridden.active.bg)
		assert.equals(0x657b83, overridden.active.fg)
	end)
end)
