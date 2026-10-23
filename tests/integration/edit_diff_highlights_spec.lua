describe("inline edit diff screen colors", function()
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
		editor.request("nvim_ui_attach", { 80, 30, { rgb = true, ext_linegrid = true } })
	end)
	after_each(function() if editor then editor.close() end end)

	for _, theme in ipairs({
		{ "light", 0xfdf6e3, 0xeee8d5, 0x657b83 },
		{ "dark", 0x002b36, 0x073642, 0x839496 },
	}) do
		it("keeps changed rows distinct with Solarized " .. theme[1] .. " and late custom diff backgrounds", function()
			local result = editor.lua([[
				local theme = ...
				vim.o.background = theme[1]
				vim.wo.number, vim.wo.relativenumber, vim.wo.cursorline, vim.wo.wrap = false, false, false, false
				vim.wo.signcolumn = "no"
				vim.api.nvim_set_hl(0, "Normal", { fg = theme[4], bg = theme[2] })
				vim.api.nvim_set_hl(0, "CursorLine", { bg = theme[3] })
				vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0x859900, bg = theme[3] })
				vim.api.nvim_set_hl(0, "DiffDelete", { fg = 0xdc322f, bg = theme[3] })
				vim.api.nvim_set_hl(0, "@keyword.lua", { fg = 0x268bd2, bg = 0xff00ff })
				vim.treesitter.query.set("lua", "highlights", '"local" @keyword')
				require("opencode.state").set_config({ syntax = { min_bytes = 0 } })
				local widget = require("opencode.ui.edit_widget")
				local edit = { expanded_files = { true }, files = { {
					filepath = "colors.lua", status = "pending", stats = { added = 3, removed = 2 },
					diff_lines = { "@@ -1,3 +1,4 @@", " local context = 0", "-local removed = 1", "+local added = 2", "-", "+",
						'+local wrapped = "' .. string.rep("long_value_", 8) .. '"' },
				} } }
				local buffer, namespace = vim.api.nvim_get_current_buf(), vim.api.nvim_create_namespace("edit-diff-screen")
				local function snapshot(resolved)
					local render = resolved and widget.get_resolved_lines or widget.get_lines_for_edit
					local lines, highlights = render("screen", edit, { width = 48 })
					vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
					vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
					require("opencode.ui.chat.highlights").apply_extmark_highlights(buffer, namespace, highlights, 0)
					vim.api.nvim_win_set_cursor(0, { 1, 0 })
					vim.cmd("normal! zt")
					vim.cmd("redraw!")
					local rows, body_column = {}, nil
					for row, line in ipairs(lines) do
						for _, name in ipairs({ "context", "removed", "added", "wrapped" }) do
							local column = line:find("local " .. name, 1, true)
							if column then rows[name], body_column = row, column end
						end
					end
					assert(rows.context and rows.removed and rows.added and rows.wrapped, "diff rows missing")
					local function sample(row)
						local position = vim.fn.screenpos(0, row, body_column)
						return { code = vim.fn.screenattr(position.row, position.col),
							fill = vim.fn.screenattr(position.row, 48) }
					end
					local wrapped = {}
					for row = rows.wrapped, #lines - 2 do wrapped[#wrapped + 1] = sample(row) end
					return { context = sample(rows.context), removed = sample(rows.removed), added = sample(rows.added),
						blank_removed = sample(rows.added + 1), blank_added = sample(rows.added + 2), wrapped = wrapped }
				end
				local fallback = snapshot(false)
				vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0x859900, bg = 0x123456 })
				vim.api.nvim_set_hl(0, "DiffDelete", { fg = 0xdc322f, bg = 0x654321 })
				return { fallback = fallback, pending_custom = snapshot(false), resolved_custom = snapshot(true) }
			]], { theme })
			local function background(id) return attributes[id].background or default_background end
			local function red_minus_green(color) return math.floor(color / 65536) - math.floor(color / 256) % 256 end
			local function green_minus_blue(color) return math.floor(color / 256) % 256 - color % 256 end
			local added, removed = background(result.fallback.added.code), background(result.fallback.removed.code)
			assert.is_not.equals(added, removed)
			assert.is_true(red_minus_green(removed) > red_minus_green(theme[3]), "removed row must gain a red tint")
			assert.is_true(green_minus_blue(added) > green_minus_blue(theme[3]), "added row must gain a green tint")
			for _, case in ipairs({ { result.fallback, added, removed },
				{ result.pending_custom, 0x123456, 0x654321 }, { result.resolved_custom, 0x123456, 0x654321 } }) do
				local screen, add_bg, delete_bg = unpack(case)
				assert.equals(theme[3], background(screen.context.code))
				assert.equals(theme[3], background(screen.context.fill))
				for _, name in ipairs({ "context", "removed", "added" }) do
					assert.equals(0x268bd2, attributes[screen[name].code].foreground, name .. " must retain Lua syntax color")
				end
				for _, entry in ipairs({ { screen.removed, delete_bg }, { screen.blank_removed, delete_bg },
					{ screen.added, add_bg }, { screen.blank_added, add_bg } }) do
					assert.equals(entry[2], background(entry[1].code))
					assert.equals(entry[2], background(entry[1].fill), "changed background must reach trailing padding")
				end
				assert.is_true(#screen.wrapped > 1, "long changed line must wrap")
				for _, row in ipairs(screen.wrapped) do
					assert.equals(add_bg, background(row.code))
					assert.equals(add_bg, background(row.fill))
				end
			end
		end)
	end
end)
