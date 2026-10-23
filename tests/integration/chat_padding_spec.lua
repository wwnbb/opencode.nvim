describe("chat content gutters", function()
	local editor, attributes, default_background
	before_each(function()
		attributes = { [0] = {} }
		editor = require("tests.helpers.embedded_editor").new({ on_notification = function(event, changes)
			if event ~= "redraw" then return end
			for _, change in ipairs(changes) do
				for index = 2, #change do
					local args = change[index]
					if change[1] == "hl_attr_define" then attributes[args[1]] = args[2]
					elseif change[1] == "default_colors_set" then default_background = args[2] end
				end
			end
		end })
		editor.request("nvim_ui_attach", { 120, 40, { rgb = true, ext_linegrid = true } })
	end)
	after_each(function() if editor then editor.close() end end)

	for _, case in ipairs({ { "tab" }, { "vertical" }, { "horizontal" }, { "float" },
		{ "tab", "inactive" }, { "float", "inactive" }, { "tab", "mapped" }, { "float", "mapped" } }) do
		it("keeps text and panel backgrounds off both edges in " .. table.concat(case, " "), function()
			local result = editor.lua([[
				local layout, variant = ...
				require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
					chat = { layout = layout, width = 60, height = 20, close_on_focus_lost = false,
						session_tabs = { enabled = false } } })
				vim.api.nvim_set_hl(0, "Normal", { fg = "#eeeeee", bg = "#112233" })
				vim.api.nvim_set_hl(0, "SignColumn", { bg = "#aabbcc" })
				vim.api.nvim_set_hl(0, "LineNr", { bg = "#aabbcc" })
				vim.api.nvim_set_hl(0, "NormalNC", { bg = "#445566" })
				vim.api.nvim_set_hl(0, "CursorLine", { bg = "#334455" })
				local sessions, sync = require("opencode.session"), require("opencode.sync")
				sessions.remember({ id = "padding", title = "Padding" })
				sessions.set_active("padding", "Padding")
				sync.handle_session_messages("padding", require("opencode.protocol.messages").page("padding", {
					{ id = "prompt", type = "user", text = "Edge 世界 " .. string.rep("word ", 25), time = { created = 1 } },
				}))
				local chat = require("opencode.ui.chat")
				chat.open()
				local view = chat.get_view()
				chat.for_view(view).do_render()
				vim.api.nvim_win_set_cursor(view.winid, { 1, 0 })
				vim.cmd("normal! zt")
				if variant == "inactive" then vim.cmd("botright new")
				elseif variant == "mapped" then
					vim.api.nvim_set_hl(0, "PaddingNormal", { bg = "#778899" })
					vim.api.nvim_win_call(view.winid, function()
						vim.opt_local.winhighlight:append({ Normal = "PaddingNormal", NormalFloat = "PaddingNormal" })
					end)
				end
				vim.cmd("redraw!")
				local width = vim.api.nvim_win_get_width(view.winid)
				local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
				local row
				for i, line in ipairs(lines) do
					assert(vim.fn.strdisplaywidth(line) <= width - 4, "content exceeded padded width")
					if line:find("Edge", 1, true) then row = i end
				end
				assert(row, "prompt must be rendered")
				local position = vim.api.nvim_win_get_position(view.winid)
				local screen = vim.fn.screenpos(view.winid, row, 1)
				local left, right = position[2] + 1, position[2] + width - 1
				local function cell(col) return vim.fn.screenstring(screen.row, col) end
				local function attr(col) return vim.fn.screenattr(screen.row, col) end
				return { left = { cell(left), cell(left + 1) }, right = { cell(right), cell(right + 1) },
					border = cell(left + 2), offset = screen.col - left,
					gutters = { attr(left), attr(left + 1), attr(right), attr(right + 1) },
					panel = attr(left + 3), prefix = lines[row]:sub(1, #"┃  ") }
			]], case)
			assert.same({ " ", " " }, result.left)
			assert.same({ " ", " " }, result.right)
			assert.equals("┃", result.border)
			assert.equals(2, result.offset)
			assert.equals("┃  ", result.prefix, "gutter must not change buffer or highlight columns")
			local function background(attr) return attributes[attr].background or default_background end
			for _, attr in ipairs(result.gutters) do
				assert.equals(background(result.gutters[1]), background(attr), "both margins must use the same background")
				assert.is_not.equals(background(result.panel), background(attr), "panel background must stop before the margin")
			end
		end)
	end
end)
