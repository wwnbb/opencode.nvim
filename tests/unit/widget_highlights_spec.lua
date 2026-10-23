local panel = require("opencode.ui.panel")
local highlights = require("opencode.ui.highlights")
local cs = require("opencode.ui.chat.state")
local bash = require("opencode.ui.chat.bash")
local tool_style = require("opencode.ui.chat.tool_style")
local edit_widget = require("opencode.ui.edit_widget")

describe("global widget highlight colors", function()
	local saved, winhighlight, view, set_hl
	local groups = {
		"Normal", "CursorLine", "DiffAdd", "DiffDelete", "OpenCodeWidgetTestWinbar",
		"OpenCodeWidgetTestAlias", "OpenCodeWidgetTestLink",
	}
	local function raw(name)
		return vim.api.nvim_get_hl(0, { name = name, link = true })
	end
	local function remap_window()
		vim.api.nvim_set_hl(0, "OpenCodeWidgetTestWinbar", { fg = 0xeee8d5, bg = 0x93a1a1 })
		vim.wo.winhighlight = "Normal:OpenCodeWidgetTestWinbar,CursorLine:OpenCodeWidgetTestWinbar"
		-- Activate the window's highlight namespace, as a real tab-bar redraw does.
		vim.cmd("redraw")
	end

	before_each(function()
		saved, winhighlight = {}, vim.wo.winhighlight
		set_hl = vim.api.nvim_set_hl
		for _, name in ipairs(groups) do saved[name] = raw(name) end
	end)

	after_each(function()
		vim.api.nvim_set_hl = set_hl
		if view then cs.remove(view); view = nil end
		vim.wo.winhighlight = winhighlight
		for name, value in pairs(saved) do vim.api.nvim_set_hl(0, name, value) end
		vim.cmd("redraw")
		highlights.refresh()
	end)

	it("ignores tab-bar colors during widget initialization and theme refresh", function()
		local function check(fg, bg)
			for _, name in ipairs({ "OpenCodeBashOutput", "OpenCodeExploreOutput" }) do
				local hl = raw(name)
				assert.equals(fg, hl.fg, name .. " must use the global Normal foreground")
				assert.equals(bg, hl.bg, name .. " must use the global CursorLine background")
			end
			assert.equals("Normal:OpenCodeWidgetTestWinbar,CursorLine:OpenCodeWidgetTestWinbar", vim.wo.winhighlight)
		end
		vim.api.nvim_set_hl(0, "Normal", { fg = 0x586e75, bg = 0xfdf6e3 })
		vim.api.nvim_set_hl(0, "CursorLine", { bg = 0xeee8d5 })
		remap_window()
		view = cs.new()
		bash.for_view(view)
		tool_style.for_view(view)
		check(0x586e75, 0xeee8d5)

		vim.api.nvim_set_hl(0, "Normal", { fg = 0x839496, bg = 0x002b36 })
		vim.api.nvim_set_hl(0, "CursorLine", { bg = 0x073642 })
		highlights.refresh()
		check(0x839496, 0x073642)
		vim.api.nvim_exec_autocmds("ColorScheme", {})
		check(0x839496, 0x073642)
	end)

	it("resolves global link chains and stops at cycles", function()
		vim.api.nvim_set_hl(0, "Normal", { fg = 0x586e75, bg = 0xfdf6e3 })
		vim.api.nvim_set_hl(0, "OpenCodeWidgetTestAlias", { link = "OpenCodeWidgetTestLink" })
		vim.api.nvim_set_hl(0, "OpenCodeWidgetTestLink", { link = "Normal" })
		remap_window()
		assert.same(raw("Normal"), panel.get_hl("OpenCodeWidgetTestAlias"))
		vim.api.nvim_set_hl(0, "OpenCodeWidgetTestLink", { link = "OpenCodeWidgetTestAlias" })
		assert.same({}, panel.get_hl("OpenCodeWidgetTestAlias"))
	end)

	local function render_diff(resolved)
		local edit = { expanded_files = { true }, files = {
			{ filepath = "file.txt", diff_lines = { "@@ -1 +1 @@", "-before", "+after" } },
		} }
		return (resolved and edit_widget.get_resolved_lines or edit_widget.get_lines_for_edit)("colors", edit, { width = 60 })
	end

	it("keeps diff rows distinct when light and dark themes only color the foreground", function()
		for _, colors in ipairs({
			{ normal = 0xfdf6e3, panel = 0xeee8d5, add = 0xd9d8aa, delete = 0xeac4b4 },
			{ normal = 0x002b36, panel = 0x073642, add = 0x204a35, delete = 0x32353e },
		}) do
			vim.api.nvim_set_hl(0, "Normal", { fg = 0x586e75, bg = colors.normal })
			vim.api.nvim_set_hl(0, "CursorLine", { bg = colors.panel })
			for _, source in ipairs({ {}, { bg = colors.panel }, { bg = colors.normal } }) do
				vim.api.nvim_set_hl(0, "DiffAdd", vim.tbl_extend("force", source, { fg = 0x859900 }))
				vim.api.nvim_set_hl(0, "DiffDelete", vim.tbl_extend("force", source, { fg = 0xdc322f }))
				render_diff()
				assert.equals(colors.add, raw("OpenCodeEditDiffAddBody").bg)
				assert.equals(colors.delete, raw("OpenCodeEditDiffDeleteBody").bg)
				assert.equals(0x586e75, raw("OpenCodeEditDiffAddBody").fg)
			end
		end
	end)

	it("picks up late diff overrides without rewriting unchanged highlight groups", function()
		vim.api.nvim_set_hl(0, "Normal", { fg = 0x586e75, bg = 0xfdf6e3 })
		vim.api.nvim_set_hl(0, "CursorLine", { bg = 0xeee8d5 })
		highlights.refresh()
		-- User FileType callbacks can override these after widget initialization.
		vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0xd0d9a4 })
		vim.api.nvim_set_hl(0, "DiffDelete", { bg = 0xf9cfbe })
		local writes = {}
		vim.api.nvim_set_hl = function(ns, name, opts)
			writes[#writes + 1] = name
			return set_hl(ns, name, opts)
		end
		render_diff(true)
		assert.equals(0xd0d9a4, raw("OpenCodeEditDiffAddBody").bg)
		assert.equals(0xf9cfbe, raw("OpenCodeEditDiffDeleteBody").bg)
		assert.same({ "OpenCodeEditDiffAddBody", "OpenCodeEditDiffDeleteBody" }, writes)
		render_diff()
		assert.equals(2, #writes)
	end)

	it("uses the displayed background of reversed diff highlights", function()
		vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0x228822, reverse = true })
		vim.api.nvim_set_hl(0, "DiffDelete", { fg = 0x882222, reverse = true })
		render_diff()
		assert.equals(0x228822, raw("OpenCodeEditDiffAddBody").bg)
		assert.equals(0x882222, raw("OpenCodeEditDiffDeleteBody").bg)
	end)
end)
