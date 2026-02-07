-- opencode.nvim - Edit widget module
-- Renders fugitive-style file review widget inline in chat buffer

local M = {}

local icons = {
	pending = "←",
	accepted = "✓",
	rejected = "✗",
	selected = "❯",
	unselected = " ",
}

--- Get formatted lines for a pending (interactive) edit widget
---@param permission_id string
---@param edit_state table Edit state from edit/state.lua
---@return table lines, table highlights, number file_count, number first_file_line
function M.get_lines_for_edit(permission_id, edit_state)
	local lines = {}
	local highlights = {}
	local line_num = 0

	-- Header: icon + short permission ID + timestamp
	local id_short = permission_id:sub(1, 8)
	local time_str = os.date("%H:%M", edit_state.timestamp or os.time())
	local header = string.format(
		"%s Edit [%s] %s%s",
		icons.pending,
		id_short,
		string.rep(" ", math.max(0, 50 - 10 - #id_short - #time_str)),
		time_str
	)
	table.insert(lines, header)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #header,
		hl_group = "Title",
	})
	line_num = line_num + 1

	-- Separator
	table.insert(lines, string.rep("─", 60))
	line_num = line_num + 1

	-- File list
	local first_file_line = line_num
	local selected = edit_state.selected_file or 1

	for i, file in ipairs(edit_state.files) do
		local is_selected = (i == selected)

		-- Status prefix
		local prefix
		if file.status == "accepted" then
			prefix = " " .. icons.accepted
		elseif file.status == "rejected" then
			prefix = " " .. icons.rejected
		elseif is_selected then
			prefix = " " .. icons.selected
		else
			prefix = "  "
		end

		-- Stats
		local stats_str = string.format("+%d -%d", file.stats.added, file.stats.removed)
		local path = file.relative_path or file.filepath or ""

		-- Build file line with right-aligned stats
		local padding = math.max(1, 50 - #prefix - #path - #stats_str)
		local file_line = string.format("%s %s%s%s", prefix, path, string.rep(" ", padding), stats_str)
		table.insert(lines, file_line)

		-- Highlights for file line
		local prefix_len = #prefix + 1 -- +1 for the space after prefix
		local path_end = prefix_len + #path

		if file.status == "accepted" then
			-- Green for accepted
			table.insert(highlights, {
				line = line_num,
				col_start = 0,
				col_end = prefix_len,
				hl_group = "String",
			})
			table.insert(highlights, {
				line = line_num,
				col_start = prefix_len,
				col_end = path_end,
				hl_group = "String",
			})
		elseif file.status == "rejected" then
			-- Red for rejected
			table.insert(highlights, {
				line = line_num,
				col_start = 0,
				col_end = prefix_len,
				hl_group = "ErrorMsg",
			})
			table.insert(highlights, {
				line = line_num,
				col_start = prefix_len,
				col_end = path_end,
				hl_group = "ErrorMsg",
			})
		elseif is_selected then
			-- Cursor line highlight for selected
			table.insert(highlights, {
				line = line_num,
				col_start = 0,
				col_end = #file_line,
				hl_group = "CursorLine",
			})
		end

		-- Stats highlights (always)
		local stats_start = #file_line - #stats_str
		local plus_end = stats_start + 1 + #tostring(file.stats.added)
		table.insert(highlights, {
			line = line_num,
			col_start = stats_start,
			col_end = plus_end,
			hl_group = "DiffAdd",
		})
		table.insert(highlights, {
			line = line_num,
			col_start = plus_end + 1,
			col_end = #file_line,
			hl_group = "DiffDelete",
		})

		line_num = line_num + 1

		-- Inline diff expansion (if toggled)
		if edit_state.expanded_files[i] and file.diff_lines and #file.diff_lines > 0 then
			for _, diff_line in ipairs(file.diff_lines) do
				local indented = "  " .. diff_line
				table.insert(lines, indented)

				-- Highlight based on diff line prefix
				local hl_group = "Comment" -- context lines
				local first_char = diff_line:sub(1, 1)
				if first_char == "+" then
					hl_group = "DiffAdd"
				elseif first_char == "-" then
					hl_group = "DiffDelete"
				elseif diff_line:match("^@@") then
					hl_group = "Title"
				end

				table.insert(highlights, {
					line = line_num,
					col_start = 0,
					col_end = #indented,
					hl_group = hl_group,
				})

				line_num = line_num + 1
			end
		end
	end

	-- Blank line before hints
	table.insert(lines, "")
	line_num = line_num + 1

	-- Keybinding hint line
	local hint = "<C-a> accept  <C-x> reject  = inline diff  dv diff split  dt diff tab"
	table.insert(lines, hint)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #hint,
		hl_group = "Comment",
	})
	line_num = line_num + 1

	local hint2 = "Enter open  A accept all  X reject all  1-9 jump to file"
	table.insert(lines, hint2)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #hint2,
		hl_group = "Comment",
	})
	line_num = line_num + 1

	-- Trailing blank line
	table.insert(lines, "")

	return lines, highlights, #edit_state.files, first_file_line
end

--- Get formatted lines for a resolved edit (all files accepted/rejected, reply sent)
---@param permission_id string
---@param edit_state table Edit state from edit/state.lua
---@return table lines, table highlights
function M.get_resolved_lines(permission_id, edit_state)
	local lines = {}
	local highlights = {}
	local line_num = 0

	local edit_state_mod = require("opencode.edit.state")
	local resolution = edit_state_mod.get_resolution(permission_id)

	-- Header with resolution status
	local id_short = permission_id:sub(1, 8)
	local time_str = os.date("%H:%M", edit_state.resolved_at or edit_state.timestamp or os.time())
	local resolution_label
	if resolution == "all_accepted" then
		resolution_label = "Approved"
	elseif resolution == "all_rejected" then
		resolution_label = "Rejected"
	else
		resolution_label = "Partial"
	end

	local header = string.format(
		"%s Edit [%s] %s%s  %s",
		icons.pending,
		id_short,
		string.rep(" ", math.max(0, 44 - 10 - #id_short - #time_str - #resolution_label)),
		time_str,
		resolution_label
	)
	table.insert(lines, header)

	-- Header highlight
	local hl_group = "Comment"
	if resolution == "all_accepted" then
		hl_group = "String"
	elseif resolution == "all_rejected" then
		hl_group = "ErrorMsg"
	end
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #header,
		hl_group = hl_group,
	})
	line_num = line_num + 1

	-- Separator
	table.insert(lines, string.rep("─", 60))
	line_num = line_num + 1

	-- Compact file list with status
	for _, file in ipairs(edit_state.files) do
		local status_icon = file.status == "accepted" and icons.accepted or icons.rejected
		local path = file.relative_path or file.filepath or ""
		local stats_str = string.format("+%d -%d", file.stats.added, file.stats.removed)
		local padding = math.max(1, 50 - 2 - #path - #stats_str)
		local file_line = string.format(" %s %s%s%s", status_icon, path, string.rep(" ", padding), stats_str)
		table.insert(lines, file_line)

		local file_hl = file.status == "accepted" and "String" or "ErrorMsg"
		table.insert(highlights, {
			line = line_num,
			col_start = 0,
			col_end = 4, -- icon area
			hl_group = file_hl,
		})
		table.insert(highlights, {
			line = line_num,
			col_start = 4,
			col_end = 4 + #path,
			hl_group = "Comment",
		})

		-- Stats
		local stats_start = #file_line - #stats_str
		local plus_end = stats_start + 1 + #tostring(file.stats.added)
		table.insert(highlights, {
			line = line_num,
			col_start = stats_start,
			col_end = plus_end,
			hl_group = "DiffAdd",
		})
		table.insert(highlights, {
			line = line_num,
			col_start = plus_end + 1,
			col_end = #file_line,
			hl_group = "DiffDelete",
		})

		line_num = line_num + 1
	end

	-- Trailing blank line
	table.insert(lines, "")

	return lines, highlights
end

return M
