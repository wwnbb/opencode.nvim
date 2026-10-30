-- opencode.nvim - Permission widget module
-- Renders permission requests inline in the chat buffer, in one of three layouts:
--   * a standalone panel: header, the request, then its options or decision;
--   * continuing the "▏" panel of the bash row above it (`opts.tool_row`);
--   * indented under a compact list row (`opts.tool_row.compact`), decisions only.
-- What a request asks for comes from opencode.permission.request.

local M = {}

local panel = require("opencode.ui.panel")
local permission_request = require("opencode.permission.request")
local tool_panel = require("opencode.ui.chat.tool_panel")
local widget_base = require("opencode.ui.widget_base")

local PANEL_PREFIX = "▏  "
local PANEL_EMPTY = "▏"
-- The indent of a compact list row's own sub-lines ("↳ Loaded …").
local LIST_PREFIX = "     "

local icons = {
	pending = "△",
	approved = "✓",
	rejected = "✗",
	selected = "❯",
	unselected = " ",
}

local OPTION_LABELS = {
	"Allow once",
	"Always allow",
	"Reject",
}
local MAX_PERMISSION_COMMAND_HEAD_LINES = 8
local MAX_PERMISSION_COMMAND_TAIL_LINES = 4

local panel_helpers = panel.create_helpers({
	prefix = PANEL_PREFIX,
	blank_prefix = PANEL_EMPTY,
	border_hl = "OpenCodePermissionMuted",
	default_hl = "OpenCodePermissionOutput",
})
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank
local add_trailing_separator = panel_helpers.add_separator
local highlight_panel_text = panel_helpers.highlight_text

---Lines and highlight groups of one layout.
---@class OpenCodePermissionSurface
---@field lines OpenCodePanelHelpers
---@field approved string
---@field rejected string
---@field muted string
---@field output string
---@field path string

---@type OpenCodePermissionSurface
local PANEL = {
	lines = panel_helpers,
	approved = "OpenCodePermissionApproved",
	rejected = "OpenCodePermissionRejected",
	muted = "OpenCodePermissionMuted",
	output = "OpenCodePermissionOutput",
	path = "OpenCodePermissionPath",
}

-- A list row has no panel background, so neither do the lines under it.
---@type OpenCodePermissionSurface
local LIST = {
	lines = panel.create_helpers({ prefix = LIST_PREFIX, blank_prefix = "", default_hl = "OpenCodePermissionListMuted" }),
	approved = "OpenCodePermissionListApproved",
	rejected = "OpenCodePermissionListRejected",
	muted = "OpenCodePermissionListMuted",
	output = "OpenCodePermissionListMuted",
	path = "OpenCodePermissionListMuted",
}

---@param name string
---@param fg_source string
---@param fallback string
local function set_list_hl(name, fg_source, fallback)
	local fg = panel.get_hl(fg_source).fg or panel.get_hl(fallback).fg
	vim.api.nvim_set_hl(0, name, fg and { fg = fg } or { link = fallback })
end

local function ensure_highlights()
	local set_panel_hl = panel_helpers.set_hl
	set_panel_hl("OpenCodePermissionMuted", "Comment", "Normal")
	set_panel_hl("OpenCodePermissionHeader", "Title", "Normal", { bold = true })
	set_panel_hl("OpenCodePermissionTitle", "Label", "Title", { bold = true })
	set_panel_hl("OpenCodePermissionOutput", "Normal", nil)
	set_panel_hl("OpenCodePermissionSelected", "Normal", "CursorLine", { bold = true })
	set_panel_hl("OpenCodePermissionApproved", "String", "Normal")
	set_panel_hl("OpenCodePermissionRejected", "DiagnosticError", "ErrorMsg")
	set_panel_hl("OpenCodePermissionError", "DiagnosticError", "ErrorMsg")
	set_panel_hl("OpenCodePermissionPath", "String", "Normal", { bold = true })
	set_panel_hl("OpenCodePermissionCommand", "Special", "Normal")
	vim.api.nvim_set_hl(0, "OpenCodePermissionSelectedMarker", widget_base.selected_marker_hl(panel_helpers.get_hl))

	set_list_hl("OpenCodePermissionListApproved", "String", "Normal")
	set_list_hl("OpenCodePermissionListRejected", "DiagnosticError", "ErrorMsg")
	set_list_hl("OpenCodePermissionListMuted", "Comment", "Normal")
end

require("opencode.ui.highlights").register("opencode.ui.permission_widget", ensure_highlights)

---What the tool row rendered for the same call shows.
---@class OpenCodePermissionToolRow
---@field tool string Tool name of the row
---@field end_line integer Last buffer row of the row and the permissions attached to it so far
---@field command string Command the row shows, or ""
---@field folded boolean The row folds part of its command behind an overflow line
---@field compact boolean The row is a compact list row rather than a "▏" panel

---@param status string|nil
---@return boolean
local function is_resolved(status)
	return status == "approved" or status == "rejected"
end

---Shell command the tool row above shows in full, or nil when the widget
---must show the request itself.
---@param permission_type string|nil
---@param tool_row OpenCodePermissionToolRow|nil
---@return string|nil
local function tool_row_command(permission_type, tool_row)
	if type(tool_row) ~= "table" or tool_row.folded or not permission_request.is_shell(permission_type) then
		return nil
	end
	local command = vim.trim(type(tool_row.command) == "string" and tool_row.command or "")
	return command ~= "" and command or nil
end

-- ─── Request details ──────────────────────────────────────────────────────────

---@param text string
---@param fragment string
---@return boolean
local function contains(text, fragment)
	fragment = vim.trim(fragment)
	return fragment ~= "" and text:find(fragment, 1, true) ~= nil
end

---Requested resources the reader cannot already see: in the shown command
---(shell requests only) or among the shown values. Every other resource
---stays listed so no authorization scope is hidden.
---@param request OpenCodePermissionRequest
---@param shown_command string Command shown in full, or ""
---@param shown_values? string[]
---@return string[]
local function unshown_resources(request, shown_command, shown_values)
	local shown = {}
	for _, value in ipairs(shown_values or {}) do
		shown[value] = true
	end
	local resources = {}
	for _, resource in ipairs(request.resources) do
		if not shown[resource] and not (request.shell and contains(shown_command, resource)) then
			table.insert(resources, resource)
		end
	end
	return resources
end

---"Label: value", with continuation and wrapped rows aligned under the value.
---@param result table
---@param surface OpenCodePermissionSurface
---@param label string
---@param value string
local function append_detail(result, surface, label, value)
	local head = label .. ": "
	local indent = string.rep(" ", #head)
	local value_hl = label == "Path" and surface.path or surface.output
	for index, line in ipairs(vim.split(value, "\n", { plain = true })) do
		local _, _, rows = surface.lines.add_raw_line(result, line, value_hl, {
			body_prefix = index == 1 and head or indent,
			continuation_prefix = indent,
		})
		if index == 1 then
			surface.lines.highlight_text(result, rows, head, surface.muted)
		end
	end
end

---@param result table
---@param surface OpenCodePermissionSurface
---@param details OpenCodePermissionDetail[]
---@param resources string[]
---@param message string
local function append_details(result, surface, details, resources, message)
	for _, detail in ipairs(details) do
		append_detail(result, surface, detail.label, detail.value)
	end
	for _, resource in ipairs(resources) do
		append_detail(result, surface, "Resource", resource)
	end
	if message ~= "" then
		append_detail(result, surface, "Message", message)
	end
end

---@param result table
---@param lines string[]
---@param first boolean Lines start the command
---@param highlight boolean
local function append_command_lines(result, lines, first, highlight)
	tool_panel.add_command_lines(result, lines, {
		panel = panel_helpers,
		hl_group = "OpenCodePermissionCommand",
		prefix = PANEL_PREFIX,
		prompt = first,
		highlight = highlight,
	})
end

---Render a command the way the bash row does: "$ " prompt, indented
---continuation lines and shell syntax. A long command keeps its head and tail,
---unless a requested resource lies in the lines that would be hidden.
---@param result table
---@param command string
---@param resources string[]
local function append_command(result, command, resources)
	local lines = vim.split(command, "\n", { plain = true })
	local head_count, tail_count = MAX_PERMISSION_COMMAND_HEAD_LINES, MAX_PERMISSION_COMMAND_TAIL_LINES
	local head = vim.list_slice(lines, 1, head_count)
	local tail = vim.list_slice(lines, #lines - tail_count + 1)
	local fold = #lines > head_count + tail_count
	if fold then
		local head_text, tail_text = table.concat(head, "\n"), table.concat(tail, "\n")
		for _, resource in ipairs(resources) do
			if contains(command, resource) and not contains(head_text, resource) and not contains(tail_text, resource) then
				fold = false
				break
			end
		end
	end
	if not fold then
		append_command_lines(result, lines, true, true)
		return
	end

	append_command_lines(result, head, true, true)
	local hidden = #lines - head_count - tail_count
	add_panel_line(result, "  … (" .. tostring(hidden) .. " command lines hidden)", "OpenCodePermissionMuted")
	-- A tail fragment can start inside a quote; it keeps the plain command colour.
	append_command_lines(result, tail, false, false)
end

---The request in full: title, command, details and every unshown resource.
---The header already names the tool, so its own permission has no title line.
---@param result table
---@param request OpenCodePermissionRequest
---@return boolean added
local function append_request(result, request)
	local count = #result.lines
	if not request.own and request.title ~= "" then
		local _, _, title_rows = add_panel_line(result, request.title, "OpenCodePermissionTitle")
		highlight_panel_text(result, title_rows, request.title, "OpenCodePermissionTitle")
	end

	local shown_values = vim.tbl_map(function(detail) return detail.value end, request.details)
	local resources = unshown_resources(request, request.command, shown_values)
	if request.command ~= "" then
		if #result.lines > count then
			add_panel_blank(result)
		end
		append_command(result, request.command, request.resources)
		if #request.details + #resources > 0 or request.message ~= "" then
			add_panel_blank(result)
		end
	end
	append_details(result, PANEL, request.details, resources, request.message)
	return #result.lines > count
end

-- ─── Standalone panel ─────────────────────────────────────────────────────────

---@param result table
---@param request OpenCodePermissionRequest
---@param status "pending"|"approved"|"rejected"
---@param suffix string|nil
local function add_header(result, request, status, suffix)
	local header, hl_group = "# Permission required", "OpenCodePermissionHeader"
	if status == "approved" then
		header, hl_group = "# Permission allowed", "OpenCodePermissionApproved"
	elseif status == "rejected" then
		header, hl_group = "# Permission rejected", "OpenCodePermissionRejected"
	end
	-- Only the tool name takes the title highlight.
	if request.tool ~= "" then
		header = header .. " for"
	end
	widget_base.add_status_header(panel_helpers, result, header, request.tool, suffix, hl_group, "OpenCodePermissionTitle")
end

---Header and request of a standalone panel, between blank panel rows.
---@param result table
---@param request OpenCodePermissionRequest
---@param status "pending"|"approved"|"rejected"
---@param suffix string|nil
local function append_panel_request(result, request, status, suffix)
	add_panel_blank(result)
	add_header(result, request, status, suffix)
	add_panel_blank(result)
	if append_request(result, request) then
		add_panel_blank(result)
	end
end

-- ─── Pending options ──────────────────────────────────────────────────────────

---The options, then what "Always allow" saves while it is selected.
---@param result table
---@param perm_state table
---@param request OpenCodePermissionRequest
---@return integer first_option_line
---@return integer option_count
---@return table<integer, integer> option_lines
---@return table<integer, integer> option_end_lines
local function append_options(result, perm_state, request)
	local first_option_line = #result.lines
	local selected = perm_state.selected_option or 1
	local can_save = #(perm_state.always or {}) > 0
	local options = can_save and OPTION_LABELS or { OPTION_LABELS[1], OPTION_LABELS[3] }

	local option_lines, option_end_lines = widget_base.append_options(result, options, function(i)
		return i == selected
	end, function(_, is_selected)
		return is_selected and icons.selected or icons.unselected
	end, {
		add_raw_line = add_panel_raw_line,
		highlight_text = highlight_panel_text,
		selected_hl = "OpenCodePermissionSelected",
		option_hl = "OpenCodePermissionOutput",
		marker_hl = "OpenCodePermissionSelectedMarker",
	})
	add_panel_blank(result)

	if can_save and selected == 2 then
		local save = request.always
		if #save == 1 and save[1] == "*" then
			add_panel_line(result, "This will always allow " .. request.title .. " for this project.", "OpenCodePermissionMuted")
		else
			add_panel_line(result, "This will always allow the following patterns for this project.", "OpenCodePermissionMuted")
			for _, pattern in ipairs(save) do
				add_panel_line(result, "- " .. pattern, "OpenCodePermissionOutput")
			end
		end
		add_panel_blank(result)
	end
	return first_option_line, #options, option_lines, option_end_lines
end

---The error line, then the key hint, then a closing blank row when either was shown.
---@param result table
---@param perm_state table
---@param option_count number
local function append_tail(result, perm_state, option_count)
	local tail_start = #result.lines
	if perm_state.error then
		add_panel_line(result, perm_state.error.message or "Unable to confirm decision", "OpenCodePermissionError")
	end
	local keymaps = require("opencode.util.keymap")
	local keys = (require("opencode.ui.chat.state").state.config or {}).keymaps
	local function key(action) return keymaps.label("chat", action, keys) end
	local select_item, move_item = widget_base.selection_hint(option_count, keys)
	local hint = keymaps.hint({ select_item, move_item, { key("confirm"), "confirm" }, { key("widget_message"), "message" } },
		{ omit_disabled = true })
	if hint then
		add_panel_line(result, hint, "OpenCodePermissionMuted")
	end
	if #result.lines > tail_start then
		add_panel_blank(result)
	end
end

-- Get formatted lines for a pending permission
---@param _permission_id string Unused; kept for the public signature
---@param perm_state table Permission state from permission/state.lua
---@param opts? table { width?: number, render?: table, tool_row?: OpenCodePermissionToolRow }
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.get_lines_for_permission(_permission_id, perm_state, opts)
	local result = widget_base.new_result(opts)
	local request = permission_request.describe(perm_state)
	local row_command = tool_row_command(request.type, opts and opts.tool_row)
	-- Below a bash row that shows the command, the question continues its panel
	-- and keeps only what the row does not show.
	local attached = row_command ~= nil

	if row_command then
		add_panel_line(result, icons.pending .. " Allow this command?", "OpenCodePermissionHeader")
		append_details(result, PANEL, {}, unshown_resources(request, row_command), request.message)
	else
		append_panel_request(result, request, "pending", perm_state.submitting and "(submitting)" or nil)
	end

	if perm_state.status == "unavailable" or perm_state.submitting then
		add_panel_line(result, perm_state.submitting and "Sending decision…" or "Request is no longer pending", "OpenCodePermissionMuted")
		add_panel_blank(result)
		if not attached then
			add_trailing_separator(result)
		end
		return result.lines, result.highlights, widget_base.make_meta({ attached = attached or nil })
	end

	local first_option_line, option_count, option_lines, option_end_lines = append_options(result, perm_state, request)
	append_tail(result, perm_state, option_count)
	if not attached then
		add_trailing_separator(result)
	end

	return result.lines,
		result.highlights,
		widget_base.make_meta({
			interactive_count = option_count,
			first_interactive_line = first_option_line,
			option_lines = option_lines,
			option_end_lines = option_end_lines,
			selected_line = option_lines[perm_state.selected_option or 1],
			attached = attached or nil,
		})
end

-- ─── Decisions ────────────────────────────────────────────────────────────────

---The decision as one status line under the tool row: what was decided and the
---scope it covers, then whatever else the row does not show.
---@param result table
---@param surface OpenCodePermissionSurface
---@param perm_state table
---@param status "approved"|"rejected"
---@param tool_row OpenCodePermissionToolRow
---@param request OpenCodePermissionRequest
local function append_status(result, surface, perm_state, status, tool_row, request)
	local decision, saved = "allowed once", nil
	if status == "rejected" then
		decision = "rejected"
	elseif perm_state.reply == "always" and #request.always > 0 then
		decision, saved = "always allowed", request.always
	end
	local own = request.type == tool_row.tool or (request.shell and tool_row.tool == "bash")
	local text = own and (decision:sub(1, 1):upper() .. decision:sub(2)) or (request.title .. " " .. decision)

	-- An "always" reply covers its saved patterns; any other decision covers the
	-- requested resources. Requested resources outside the saved patterns stay listed.
	local row_command = type(tool_row.command) == "string" and tool_row.command or ""
	local scope, resources
	if saved then
		scope = not (#saved == 1 and saved[1] == "*") and saved or {}
		resources = unshown_resources(request, row_command, scope)
	else
		scope, resources = unshown_resources(request, row_command), {}
	end
	if #scope > 0 then
		text = text .. ": " .. table.concat(scope, ", ")
	end

	local icon = status == "rejected" and icons.rejected or icons.approved
	surface.lines.add_line(result, icon .. " " .. text, status == "rejected" and surface.rejected or surface.approved)
	append_details(result, surface, {}, resources, request.message)
end

---@param perm_state table
---@param status "approved"|"rejected"
---@param reply_suffix string|nil
---@param opts table|nil
---@return table lines, table highlights, boolean attached
local function render_resolved(perm_state, status, reply_suffix, opts)
	local result = widget_base.new_result(opts)
	local request = permission_request.describe(perm_state)
	local tool_row = opts and opts.tool_row
	if type(tool_row) == "table" then
		-- A list row keeps its own separator below the status; a panel closes with a blank row.
		append_status(result, tool_row.compact and LIST or PANEL, perm_state, status, tool_row, request)
		if not tool_row.compact then
			add_panel_blank(result)
		end
		return result.lines, result.highlights, true
	end

	append_panel_request(result, request, status, reply_suffix)
	add_trailing_separator(result)
	return result.lines, result.highlights, false
end

-- Compatibility entrypoints retain their existing signatures and reply suffixes.
---@param _permission_id string Unused; kept for the public signature
---@param perm_state table
---@param opts? table { width?: number, render?: table, tool_row?: OpenCodePermissionToolRow }
---@return table lines, table highlights, boolean attached One status line for the tool row above
function M.get_approved_lines(_permission_id, perm_state, opts)
	local saved = perm_state.reply == "always" and #(perm_state.always or {}) > 0
	return render_resolved(perm_state, "approved", saved and "(always)" or "(once)", opts)
end

---@param _permission_id string Unused; kept for the public signature
---@param perm_state table
---@param opts? table { width?: number, render?: table, tool_row?: OpenCodePermissionToolRow }
---@return table lines, table highlights, boolean attached One status line for the tool row above
function M.get_rejected_lines(_permission_id, perm_state, opts)
	return render_resolved(perm_state, "rejected", nil, opts)
end

-- ─── Public API ───────────────────────────────────────────────────────────────

---Whether a permission continues the tool row directly above it: a decided
---one as a status line, a pending shell request as a question on its panel.
---@param perm_state table
---@param tool_row OpenCodePermissionToolRow|nil
---@return boolean
function M.attaches(perm_state, tool_row)
	if type(tool_row) ~= "table" then
		return false
	end
	return is_resolved(perm_state.status) or tool_row_command(perm_state.permission_type, tool_row) ~= nil
end

---Render a permission for its current status; always returns meta.
---With `opts.tool_row`, a resolved permission is one status line under that
---row and a pending shell request is a question on the row's panel;
---`meta.attached` marks both.
---@param perm_state table Permission state from permission/state.lua
---@param opts? table { width?: number, render?: table, tool_row?: OpenCodePermissionToolRow }
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.render(perm_state, opts)
	local id = perm_state.permission_id
	local status = perm_state.status or "pending"
	if is_resolved(status) then
		local lines, highlights, attached = (status == "approved" and M.get_approved_lines or M.get_rejected_lines)(id, perm_state, opts)
		return lines, highlights, widget_base.make_meta(attached and { attached = true } or nil)
	end
	return M.get_lines_for_permission(id, perm_state, opts)
end

return M
