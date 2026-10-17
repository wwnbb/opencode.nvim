local cs = require("opencode.ui.chat.state")
return cs.factory("write", function(view)
local M = { animation_line = 0 }

local render = cs.module(view, require("opencode.ui.chat.render"))
local tool_panel = cs.module(view, require("opencode.ui.chat.tool_panel"))
local tool_group = cs.module(view, require("opencode.ui.chat.tool_group"))
local style = cs.module(view, require("opencode.ui.chat.tool_style"))
local syntax = require("opencode.ui.syntax")
local text = require("opencode.util.text")
local panel = style.panel

function M.render_tool(part, expanded)
	if type(part) ~= "table" or part.tool ~= "write" then return nil end
	local ctx = tool_panel.context(part)
	local input = type(ctx.input) == "table" and ctx.input or {}
	local filepath = text.first_string(input.path, input.filePath, input.filepath, input.file_path,
		ctx.metadata.target, ctx.metadata.filePath, ctx.metadata.filepath) or "unknown"
	local path = text.normalize_path(filepath)
	local failed = tool_group.execution_failed(part)
	local working = not failed and tool_group.is_working(part)
	local status = failed and "Failed" or ctx.status:gsub("^%l", string.upper)
	local spinner = working and (" " .. tool_panel.anim_frame()) or ""
	local width = math.max(1, render.get_chat_text_width() - 1)
	local prefix, suffix = tool_panel.fold_prefix(expanded) .. "Write ", " · " .. status
	local available = width - vim.fn.strdisplaywidth(prefix .. suffix .. spinner)
	local safe_path = render.expand_tabs(path, vim.fn.strdisplaywidth(prefix))
	local header = available > 0 and (prefix .. text.truncate(safe_path, available, "…") .. suffix)
		or text.truncate(prefix .. safe_path .. suffix, width - vim.fn.strdisplaywidth(spinner), "…")
	local result = panel.result()
	render.add_panel_line(result, header .. spinner, failed and style.error_hl or style.header_hl, { prefix = " " })
	if not expanded then return result end

	style.add_border(result)
	panel.add_line(result, "File: " .. path)
	panel.add_line(result, ctx.status == "completed" and not failed
		and "Content sent to write (before server formatting)" or "Proposed content", style.border_hl)
	if type(input.content) ~= "string" then
		panel.add_line(result, "Content unavailable", style.border_hl)
	elseif input.content == "" then
		panel.add_line(result, "(empty file)", style.border_hl)
	else
		tool_panel.add_raw_body(result, input.content, {
			panel = panel, prefix = style.prefix, language = syntax.language_for_path(filepath),
		})
	end
	if failed then
		panel.add_blank(result)
		local error = tool_panel.stringify_output(ctx.error)
		tool_panel.add_raw_body(result, error ~= "" and error or "Write failed", {
			panel = panel, prefix = style.prefix, hl_group = style.body_error_hl,
		})
	end
	local diagnostics = require("opencode.diagnostics").parse(ctx.metadata.diagnostics, filepath)
	if #diagnostics > 0 then
		panel.add_blank(result)
		for _, diagnostic in ipairs(diagnostics) do
			local label = ({ "Error", "Warning", "Info", "Hint" })[diagnostic.severity] or "Diagnostic"
			local location = diagnostic.path == filepath and "" or (text.normalize_path(diagnostic.path) .. " · ")
			panel.add_line(result, string.format("%s%s [%d:%d] %s", location, label, diagnostic.line,
				diagnostic.character + 1, diagnostic.message), diagnostic.severity == 1 and style.body_error_hl or style.border_hl)
		end
		panel.add_line(result, "/diagnostics: list and jump", style.border_hl)
	end
	style.add_border(result, true)
	style.contain_background(result)
	return result
end

return M

end)
