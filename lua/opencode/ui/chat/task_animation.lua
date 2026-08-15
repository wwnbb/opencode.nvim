-- Task animation engine for the chat buffer.
-- Extracted from tasks.lua: braille task frames, regular-tool spinners,
-- frame overlay updates, and the animation timer lifecycle.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_anim_ns = cs.chat_anim_ns
local widget_support = require("opencode.ui.chat.widget_support")
local edit_state = require("opencode.edit.state")

local function chat_tasks()
	return require("opencode.ui.chat.tasks")
end

-- ─── Animation ────────────────────────────────────────────────────────────────

local TASK_ANIM_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local TASK_COMPLETE_ICON = "✓"
local TASK_CANCELLED_ICON = "✕"
local TASK_ERROR_ICON = "✗"
local TASK_HIGHLIGHT_PRIORITY = 4200
local TASK_ANIMATION_PRIORITY = TASK_HIGHLIGHT_PRIORITY + 50
local MAX_REGULAR_TOOL_ANIMATION_RENDER_LINES = 120

M.TASK_HIGHLIGHT_PRIORITY = TASK_HIGHLIGHT_PRIORITY
M.MAX_REGULAR_TOOL_ANIMATION_RENDER_LINES = MAX_REGULAR_TOOL_ANIMATION_RENDER_LINES

local function frame_at(frames, index)
	local count = type(frames) == "table" and #frames or 0
	if count == 0 then
		return ""
	end
	index = tonumber(index) or 1
	return frames[((index - 1) % count) + 1] or frames[1] or ""
end

function M.get_task_anim_frame()
	return frame_at(TASK_ANIM_FRAMES, state.task_anim_frame)
end

---@param status string
---@return boolean
function M.is_task_working(status)
	return status == "pending" or status == "running"
end

---@param status string
---@return boolean
local function is_task_cancelled(status)
	return status == "cancelled" or status == "canceled" or status == "interrupted" or status == "aborted"
end

---@param status string
---@return string icon
function M.get_task_status_icon(status)
	if M.is_task_working(status) then
		return M.get_task_anim_frame()
	end
	if status == "error" then
		return TASK_ERROR_ICON
	end
	if is_task_cancelled(status) then
		return TASK_CANCELLED_ICON
	end
	return TASK_COMPLETE_ICON
end

local function tick_task_anim_frame()
	state.task_anim_frame = state.task_anim_frame + 1
	if state.task_anim_frame > #TASK_ANIM_FRAMES then
		state.task_anim_frame = 1
	end
end

---@param tool_name string|nil
---@return boolean
local function is_animated_regular_tool(tool_name)
	return tool_name == "bash"
		or tool_name == "read"
		or tool_name == "skill"
		or tool_name == "glob"
		or tool_name == "grep"
end

---@param tool_part table|nil
---@return boolean
function M.is_animating_tool_part(tool_part)
	tool_part = chat_tasks().resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" then
		return false
	end
	local status = tool_part.state and tool_part.state.status or "pending"
	if tool_part.tool == "task" then
		return M.is_task_working(status)
	end
	return is_animated_regular_tool(tool_part.tool) and M.is_task_working(status)
end

function M.stop_task_animation_timer()
	if not state.task_anim_timer then
		return
	end
	if vim.uv.is_closing(state.task_anim_timer) then
		state.task_anim_timer = nil
		return
	end
	state.task_anim_timer:stop()
	state.task_anim_timer:close()
	state.task_anim_timer = nil
	widget_support.clear_animation_extmarks()
end

function M.has_active_task_rows()
	for _, pos in pairs(state.tasks) do
		if M.is_animating_tool_part(chat_tasks().resolve_tool_part(pos)) then
			return true
		end
	end
	for _, pos in pairs(state.tools) do
		if M.is_animating_tool_part(chat_tasks().resolve_tool_part(pos)) then
			return true
		end
	end
	return false
end

function M.start_task_animation_timer()
	if state.task_anim_timer then
		return
	end

	local timer = vim.uv.new_timer()
	if not timer then
		return
	end

	state.task_anim_timer = timer
	timer:start(
		120,
		120,
		vim.schedule_wrap(function()
			if not state.visible then
				return
			end

			if edit_state.has_pending_edits() then
				return
			end

			if widget_support.in_place_updates_blocked() then
				return
			end

			if not M.has_active_task_rows() then
				M.stop_task_animation_timer()
				return
			end

			tick_task_anim_frame()
			if not M.update_animation_frames_in_place() then
				M.update_active_animations_in_place()
			end
		end)
	)
end

-- ─── In-place widget rendering ────────────────────────────────────────────────

---@return boolean updated
function M.update_active_animations_in_place()
	if not state.visible or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return false
	end
	if widget_support.in_place_updates_blocked() then
		return false
	end
	local top_line, bottom_line = widget_support.get_visible_line_range()
	local tasks_updated = widget_support.update_animating_blocks(state.tasks, top_line, bottom_line, {
		resolve = chat_tasks().resolve_tool_part,
		is_animating = M.is_animating_tool_part,
		render = function(part_id, pos, tool_part)
			return chat_tasks().render_task_tool(tool_part, state.expanded_tasks[part_id] or false)
		end,
		rerender = chat_tasks().rerender_task,
	})

	local tools_updated = widget_support.update_animating_blocks(state.tools, top_line, bottom_line, {
		resolve = chat_tasks().resolve_tool_part,
		is_animating = M.is_animating_tool_part,
		render = function(part_id, pos, tool_part)
			if (pos.end_line - pos.start_line + 1) > MAX_REGULAR_TOOL_ANIMATION_RENDER_LINES then
				return nil
			end
			return chat_tasks().render_regular_tool(tool_part, state.expanded_tools[part_id] or false)
		end,
		rerender = chat_tasks().rerender_tool,
	})

	local updated = tasks_updated or tools_updated
	return updated
end

-- ─── Frame-only animation update (fast path) ──────────────────────────────────

local function is_animation_frame(char, frames)
	for _, frame in ipairs(frames) do
		if char == frame then
			return true
		end
	end
	return false
end

local function set_frame_overlay(bufnr, line_nr, byte_col, frame, hl_group)
	local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, chat_anim_ns, line_nr, byte_col, {
		virt_text = { { frame, hl_group or "Comment" } },
		virt_text_pos = "overlay",
		hl_mode = "combine",
		priority = TASK_ANIMATION_PRIORITY,
		right_gravity = false,
	})
	return ok
end

---Update spinner frames with overlay extmarks.
---Avoids mutating buffer text, which can disturb highlight extmarks on the task row.
---Falls back to update_active_animations_in_place() when frame positions cannot be found.
---@return boolean true if any frame character was updated
function M.update_animation_frames_in_place()
	if not state.visible or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return false
	end
	if widget_support.in_place_updates_blocked() then
		return false
	end

	local top_line, bottom_line = widget_support.get_visible_line_range()
	if top_line == nil or bottom_line == nil then
		return false
	end

	local updated = false
	local task_frame = frame_at(TASK_ANIM_FRAMES, state.task_anim_frame)
	local classic_frames = { "|", "/", "-", "\\" }
	local classic_frame = frame_at(classic_frames, state.task_anim_frame)

	local bufnr = state.bufnr
	local buf_lines = vim.api.nvim_buf_line_count(bufnr)

	widget_support.clear_animation_extmarks(bufnr)

	-- Update task blocks: header frame at col 0, and "  ↳ " summary frames
	for _, pos in pairs(state.tasks) do
		local tool_part = chat_tasks().resolve_tool_part(pos)
		if
			pos
			and M.is_animating_tool_part(tool_part)
			and widget_support.position_generation_is_current(pos)
			and widget_support.block_is_visible(pos, top_line, bottom_line)
			and pos.start_line >= 0
			and pos.start_line < buf_lines
		then
			local line_text = vim.api.nvim_buf_get_lines(bufnr, pos.start_line, pos.start_line + 1, false)[1]
			if line_text and #line_text > 0 then
				local first_char = vim.fn.strcharpart(line_text, 0, 1)
				if is_animation_frame(first_char, TASK_ANIM_FRAMES) then
					updated = set_frame_overlay(bufnr, pos.start_line, 0, task_frame, "Comment") or updated
				end
			end

			-- Scan summary lines for "  ↳ " prefix with task frame
			for line_nr = pos.start_line + 1, math.min(pos.end_line, buf_lines - 1) do
				local line = vim.api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1]
				if line and #line > 0 then
					local prefix_chars = vim.fn.strcharpart(line, 0, 4)
					if prefix_chars == "  ↳ " then
						local fifth_char = vim.fn.strcharpart(line, 4, 1)
						if is_animation_frame(fifth_char, TASK_ANIM_FRAMES) then
							local byte_offset = #vim.fn.strcharpart(line, 0, 4)
							updated = set_frame_overlay(bufnr, line_nr, byte_offset, task_frame, "Comment") or updated
						end
					end
				end
			end
		end
	end

	-- Update regular tool blocks: classic spinner at end of header line
	for _, pos in pairs(state.tools) do
		local tool_part = chat_tasks().resolve_tool_part(pos)
		if
			pos
			and M.is_animating_tool_part(tool_part)
			and widget_support.position_generation_is_current(pos)
			and widget_support.block_is_visible(pos, top_line, bottom_line)
		then
			local block_updated = false
			local candidates = { pos.start_line + 1, pos.start_line }
			for _, line_nr in ipairs(candidates) do
				if block_updated then
					break
				end
				if line_nr >= 0 and line_nr < buf_lines then
					local line = vim.api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1]
					if line and #line > 0 then
						local trimmed = line:gsub("%s+$", "")
						local char_count = vim.fn.strchars(trimmed)
						if char_count > 0 then
							local last_char = vim.fn.strcharpart(trimmed, char_count - 1, 1)
							if is_animation_frame(last_char, classic_frames) then
								local byte_offset = #vim.fn.strcharpart(trimmed, 0, char_count - 1)
								block_updated = set_frame_overlay(bufnr, line_nr, byte_offset, classic_frame, "Comment")
								updated = block_updated or updated
							end
						end
					end
				end
			end
		end
	end

	return updated
end

return M
