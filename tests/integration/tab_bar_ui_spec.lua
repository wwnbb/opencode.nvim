describe("native OpenCode layout tabline", function()
	local editor, rows
	before_each(function()
		rows = {}
		editor = require("tests.helpers.embedded_editor").new({ on_notification = function(method, args)
			if method ~= "redraw" then return end
			for _, event in ipairs(args) do
				if event[1] == "grid_line" then
					for index = 2, #event do
						local line = event[index]
						if line[1] == 1 then
							local row, column = line[2], line[3]
							rows[row] = rows[row] or {}
							for _, cell in ipairs(line[4]) do
								for _ = 1, (cell[3] or 1) do
									rows[row][column], column = cell[1], column + 1
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

	local function open(tabline, showtabline)
		editor.lua([[
			vim.o.tabline, vim.o.showtabline = ...
			_G.editor_tab = vim.api.nvim_get_current_tabpage()
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab" } })
			require("opencode.client").get_messages = function(_, _, cb) cb(nil, {}) end
			local sessions = require("opencode.session")
			_G.chat, _G.workspace = require("opencode.ui.chat"), require("opencode.ui.chat.workspace")
			_G.bar = require("opencode.ui.chat.workspace_bar")
			_G.seed = function(id)
				local session = { id = id, title = id }; sessions.remember(session); return session
			end
			_G.bar_text = function()
				return vim.api.nvim_eval_statusline(vim.o.tabline, { use_tabline = true, maxwidth = vim.o.columns }).str
			end
			seed("native-a"); sessions.set_active("native-a", "native-a"); chat.open()
			_G.first = chat.get_view()
		]], { tabline or "", showtabline == nil and 1 or showtabline })
	end

	local function top_row()
		editor.lua("vim.cmd('redraw!')")
		local cells = {}
		for column = 0, 99 do cells[#cells + 1] = rows[0] and rows[0][column] or " " end
		return table.concat(cells)
	end

	it("replaces editor labels with one row and no header window or pane winbars", function()
		open("Editor tabs")
		local panes = editor.lua([[
			local second = chat.create_split(first, seed("native-b"), "vertical")
			chat.focus_view(second)
			local result = {}
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				if vim.api.nvim_win_get_config(win).relative == "" then
					result[#result + 1] = { row = vim.api.nvim_win_get_position(win)[1], winbar = vim.wo[win].winbar }
				end
			end
			return result
		]])
		assert.equals(2, #panes)
		for _, pane in ipairs(panes) do assert.equals(1, pane.row); assert.equals("", pane.winbar) end
		local text = top_row()
		assert.is_truthy(text:find("native-a", 1, true))
		assert.is_nil(text:find("Editor tabs", 1, true))
		assert.is_nil(text:find("opencode [tabs]", 1, true))
	end)

	for _, visibility in ipairs({ 0, 1, 2 }) do
		it("restores editor options through toggle and captures later changes (showtabline=" .. visibility .. ")", function()
			local custom = "%#TabLineSel#My custom tabs%#TabLineFill#"
			open(custom, visibility)
			assert.equals(2, editor.lua("return vim.o.showtabline"))
			assert.is_truthy(top_row():find("native-a", 1, true))
			local original = editor.lua([[
				chat.toggle()
				local result = { vim.o.tabline, vim.o.showtabline }
				assert(vim.api.nvim_get_current_tabpage() == editor_tab)
				vim.o.tabline, vim.o.showtabline = "Updated editor tabs", 0
				chat.toggle()
				assert(bar_text():find("native-a", 1, true) and vim.o.showtabline == 2)
				chat.toggle()
				assert(vim.o.tabline == "Updated editor tabs" and vim.o.showtabline == 0)
				return result
			]])
			assert.same({ custom, visibility }, original)
		end)
	end

	it("supports counted selection and configured navigation from the chat pane", function()
		open()
		local target = editor.lua([[
			chat.create_layout(seed("native-b")); chat.create_layout(seed("native-c"))
			local target = workspace.current().id
			workspace.select(workspace.list()[1].id)
			local state = require("opencode.state")
			local config = vim.deepcopy(state.get_config())
			config.chat.keymaps.next_session = "]t"; state.set_config(config)
			return target
		]])
		editor.feed("3]t")
		assert.is_true(vim.wait(1000, function() return editor.lua("return workspace.current().id") == target end, 10))
	end)

	it("fits Unicode and literal percent titles while keeping the active layout visible", function()
		open()
		editor.lua([[
			for index = 1, 5 do
				local session = seed("unicode-" .. index)
				session.title = "界é\n%" .. string.rep("界", 18) .. index
				require("opencode.session").remember(session); chat.create_layout(session)
			end
			workspace.select(workspace.list()[3].id)
			chat.get_view().config.session_tabs.separator = " ····· "
		]])
		for _, width in ipairs({ 80, 28, 12 }) do
			editor.request("nvim_ui_try_resize", { width, 30 })
			local result = editor.lua([[
				bar.update()
				local value = vim.api.nvim_eval_statusline(vim.o.tabline,
					{ use_tabline = true, maxwidth = vim.o.columns, highlights = true })
				local active = false
				for _, highlight in ipairs(value.highlights) do
					if highlight.group == "OpenCodeWinbarCurrent" then active = true end
				end
				return { width = value.width, text = value.str, active = active }
			]])
			assert.is_true(result.active)
			assert.is_true(result.width <= width)
			assert.is_truthy(result.text:find("%", 1, true))
			assert.is_nil(result.text:find("[%c]"))
		end
	end)

	it("parses an AUTO max_tabs case-insensitively like the session tabs", function()
		open()
		local text = editor.lua([[
			for index = 1, 4 do chat.create_layout(seed("auto-" .. index)) end
			workspace.select(workspace.list()[3].id)
			chat.get_view().config.session_tabs.max_tabs = "AUTO"
			bar.update()
			return bar_text()
		]])
		for _, id in ipairs({ "native-a", "auto-1", "auto-2", "auto-3", "auto-4" }) do
			assert.is_truthy(text:find(id, 1, true), id)
		end
		assert.is_nil(text:find("‹", 1, true))
		assert.is_nil(text:find("›", 1, true))
	end)

	it("fills the screen below the tabline after resize and nested layout switching", function()
		editor.lua("vim.o.laststatus = 3")
		open()
		local layouts = editor.lua([[
			local ids = { workspace.current().id }
			chat.create_layout(seed("native-b")); ids[2] = workspace.current().id
			local split = chat.create_split(chat.get_view(), seed("native-c"), "vertical")
			chat.create_split(split, seed("native-nested"), "horizontal")
			chat.create_layout(seed("native-d")); ids[3] = workspace.current().id
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
					local top, bottom, count = math.huge, 0, 0
					for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
						if vim.api.nvim_win_get_config(win).relative == "" then
							local row = vim.api.nvim_win_get_position(win)[1]
							top, bottom = math.min(top, row), math.max(bottom, row + vim.api.nvim_win_get_height(win))
							assert(not vim.wo[win].winfixheight and vim.wo[win].winbar == "")
							count = count + 1
						end
					end
					return { top = top, bottom = bottom, count = count, expected_bottom = vim.o.lines - vim.o.cmdheight - 1 }
				]])
				assert.equals(1, geometry.top)
				assert.equals(step[3], geometry.count)
				assert.equals(geometry.expected_bottom, geometry.bottom)
			end
		end
	end)

	it("keeps the original theme foreground and background despite reverse and preserves overrides", function()
		editor.lua([[
			vim.api.nvim_set_hl(0, "Normal", { fg = 0x657b83, bg = 0xfdf6e3 })
			vim.api.nvim_set_hl(0, "TabLine", { fg = 0x93a1a1, bg = 0xeee8d5, reverse = true })
			vim.api.nvim_set_hl(0, "TabLineSel", { fg = 0x657b83, bg = 0xfdf6e3, reverse = true })
		]])
		open()
		assert.is_true(editor.lua([[
			local function highlight(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
			local inactive, active, idle = highlight("OpenCodeWinbar"), highlight("OpenCodeWinbarCurrent"), highlight("OpenCodeWinbarCurrentIdle")
			assert(inactive.fg == 0x93a1a1 and inactive.bg == 0xeee8d5 and not inactive.reverse)
			assert(active.fg == 0x657b83 and active.bg == 0xfdf6e3 and not active.reverse)
			assert(idle.fg == 0x657b83 and idle.bg == 0xfdf6e3)
			first.config.session_tabs.colors = { active_bg = "#e4dfc8", active_fg = "#112233",
				inactive_fg = "#445566", inactive_bg = "#778899" }; bar.update()
			assert(highlight("OpenCodeWinbarCurrent").bg == 0xe4dfc8 and highlight("OpenCodeWinbarCurrent").fg == 0x112233)
			assert(highlight("OpenCodeWinbar").bg == 0x778899 and highlight("OpenCodeWinbar").fg == 0x445566)
			assert(highlight("OpenCodeWinbarCurrentIdle").fg == 0x657b83)
			first.config.session_tabs.colors.active_idle_fg = "#abcdef"; bar.update()
			return highlight("OpenCodeWinbarCurrentIdle").fg == 0xabcdef
				and highlight("OpenCodeWinbarCurrentIdle").bg == 0xe4dfc8
		]]))
	end)
end)
