-- Regression checks for the setup-level border of shared popup windows.
-- Run with: ./tests/run.sh tests/unit/popup_border_config_spec.lua

local config = require("opencode.config")
local state = require("opencode.state")
local Popup = require("opencode.ui.popup")

local function set_border(border)
	state.set_config(config.merge({ popup = { border = border } }))
end

local function root_border(popup)
	return (popup.frame or popup.content or popup.input).border
end

local function assert_inside_screen(component, border_enabled)
	local border = component.border
	local outer = border.winid and vim.api.nvim_win_is_valid(border.winid) and border.winid or component.winid
	local layout = vim.api.nvim_win_get_config(outer)
	local border_size = border_enabled and not border.winid and 2 or 0
	assert.is_true(layout.row >= 0)
	assert.is_true(layout.col >= 0)
	assert.is_true(layout.row + layout.height + border_size <= vim.o.lines - vim.o.cmdheight)
	assert.is_true(layout.col + layout.width + border_size <= vim.o.columns)
end

describe("configured shared popup borders", function()
	local old_config, old_columns, old_lines, old_win
	local opened

	before_each(function()
		old_config = state.get_config()
		old_columns, old_lines = vim.o.columns, vim.o.lines
		old_win = vim.api.nvim_get_current_win()
		opened = {}
	end)

	after_each(function()
		for _, popup in ipairs(opened) do popup:close({ restore_focus = false }) end
		state.set_config(old_config)
		vim.o.columns, vim.o.lines = old_columns, old_lines
		if vim.api.nvim_win_is_valid(old_win) then vim.api.nvim_set_current_win(old_win) end
	end)

	local function open(spec)
		local popup = Popup.new(spec)
		table.insert(opened, popup)
		popup:mount()
		return popup
	end

	it("defaults to solid and overrides a local root style", function()
		local merged = config.merge({})
		assert.equals("solid", merged.popup.border)
		state.set_config(merged)
		local popup = open({
			relative = "editor", size = { width = 20, height = 4 }, border = "rounded",
		})
		assert.equals("solid", root_border(popup)._.style)
		assert.is_not_nil(vim.api.nvim_win_get_config(popup.winid).border)
	end)

	for _, style in ipairs({ "none", "single", "double", "rounded", "solid" }) do
		it("applies " .. style .. " to a single popup and only the outer frame of a composite popup", function()
			set_border(style)
			local single = open({
				relative = "editor", size = { width = 24, height = 5 },
				border = { style = "rounded", text = { top = " Details ", bottom = " Close " } },
			})
			assert.equals(style, root_border(single)._.style)
			if style == "none" then
				assert.is_nil(root_border(single)._.text)
				assert.is_nil(root_border(single).winid)
			else
				assert.is_not_nil(root_border(single)._.text)
				assert.is_true(vim.api.nvim_win_is_valid(root_border(single).winid))
			end

			local composite = open({
				frame = {
					relative = "editor", size = { width = 30, height = 9 },
					border = { style = "rounded", text = { top = " Switch Session " } },
				},
				content = {
					position = { row = 3, col = 1 }, size = { width = 28, height = 3 },
					border = "double",
				},
				input = {
					kind = "popup", position = { row = 2, col = 2 }, size = { width = 22, height = 1 },
					border = "single",
				},
			})
			assert.equals(style, root_border(composite)._.style)
			assert.equals("none", composite.content.border._.style)
			assert.equals("none", composite.input.border._.style)
			assert.equals("none", vim.api.nvim_win_get_config(composite.content.winid).border)
			assert.equals("none", vim.api.nvim_win_get_config(composite.input.winid).border)
			assert.equals(composite.frame.winid, vim.api.nvim_win_get_config(composite.content.winid).win)
			assert.equals(composite.frame.winid, vim.api.nvim_win_get_config(composite.input.winid).win)
			if style == "none" then
				assert.is_nil(root_border(composite)._.text)
				assert.is_nil(root_border(composite).winid)
			else
				assert.is_not_nil(root_border(composite)._.text)
				assert.is_true(vim.api.nvim_win_is_valid(root_border(composite).winid))
			end
		end)
	end

	it("accepts a Nui character table for single and composite popup roots", function()
		local custom = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" }
		set_border(custom)
		local single = open({ relative = "editor", size = { width = 18, height = 4 }, border = "rounded" })
		local composite = open({
			frame = { relative = "editor", size = { width = 24, height = 7 }, border = "rounded" },
			content = { position = { row = 1, col = 1 }, size = { width = 22, height = 4 }, border = "single" },
		})
		assert.equals("╔", root_border(single)._.char.top_left:content())
		assert.equals("╔", root_border(composite)._.char.top_left:content())
		assert.equals("none", composite.content.border._.style)
		assert.equals("╔", vim.api.nvim_win_get_config(single.winid).border[1][1])
		set_border({
			top_left = "╭", top = "─", top_right = "╮", right = "│",
			bottom_right = "╯", bottom = "─", bottom_left = "╰", left = "│",
		})
		local named = open({ relative = "editor", size = { width = 18, height = 4 }, border = "single" })
		assert.equals("╭", root_border(named)._.char.top_left:content())
	end)

	it("uses the configured border on an input-only popup", function()
		local function make_input()
			return open({
				input_only = true,
				input = {
					kind = "popup", relative = "editor", size = { width = 20, height = 1 },
					border = { style = "rounded", text = { top = " Prompt ", bottom = " Enter " } },
				},
			})
		end
		set_border("double")
		local bordered = make_input()
		assert.equals("double", bordered.input.border._.style)
		assert.is_true(vim.api.nvim_win_is_valid(bordered.input.border.winid))
		set_border("none")
		local plain = make_input()
		assert.equals("none", plain.input.border._.style)
		assert.is_nil(plain.input.border._.text)
		assert.equals("none", vim.api.nvim_win_get_config(plain.input.winid).border)
	end)

	it("keeps both border footprints and inner windows inside a smaller screen", function()
		set_border("double")
		vim.o.columns, vim.o.lines = 48, 21
		local single = open({
			relative = "editor", position = { row = 100, col = 100 },
			size = { width = 90, height = 30 }, border = { style = "rounded", text = { top = " Help " } },
		})
		local composite = open({
			frame = {
				relative = "editor", position = { row = 100, col = 100 },
				size = { width = 90, height = 30 }, border = "none",
			},
			content = { position = { row = 3, col = 1 }, size = { width = 80, height = 20 }, border = "none" },
			input = { kind = "popup", position = { row = 2, col = 2 }, size = { width = 70, height = 1 }, border = "none" },
		})
		local function assert_layout()
			assert_inside_screen(single.content, true)
			assert_inside_screen(composite.frame, true)
			local frame_config = vim.api.nvim_win_get_config(composite.frame.winid)
			for _, child in ipairs({ composite.content, composite.input }) do
				local child_config = vim.api.nvim_win_get_config(child.winid)
				assert.equals(composite.frame.winid, child_config.win)
				assert.is_true(child_config.row + child_config.height <= frame_config.height)
				assert.is_true(child_config.col + child_config.width <= frame_config.width)
			end
		end
		assert_layout()
		vim.o.columns, vim.o.lines = 32, 14
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert_layout()
	end)
end)
