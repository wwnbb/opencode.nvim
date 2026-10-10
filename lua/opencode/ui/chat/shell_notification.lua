-- Native shell completion notices share the existing expandable tool panels.
local M = {}
local tool_panel = require("opencode.ui.chat.tool_panel")
local render = require("opencode.ui.chat.render")
local panel = tool_panel.create_panel({ border_hl = "OpenCodeBashMuted", default_hl = "OpenCodeBashOutput" })
local MAX_PREVIEW_ROWS = 8

local function content(part)
	local notice = part.shell_notification
	local metadata, command, output = notice.metadata, notice.description, part.text or ""
	local id = metadata.jobID or metadata.shellID
	-- Commands and output are not XML escaped. Rebuild the exact native wrapper
	-- from metadata and description, so quotes, newlines and nested tags survive.
	if type(id) == "string" and type(command) == "string" then
		local opening = '<shell id="' .. id .. '" state="' .. metadata.state .. '" command="' .. command .. '">\n'
		local closing = "\n</shell>"
		if output:sub(1, #opening) == opening and output:sub(-#closing) == closing then
			output = output:sub(#opening + 1, -#closing - 1)
		end
	end
	return type(command) == "string" and command or "", output, metadata
end

function M.render_tool(part, expanded)
	local command, output, metadata = content(part)
	local exit = tool_panel.normalize_number(metadata.exit)
	local cancelled = metadata.state == "cancelled"
	local failed = metadata.state == "error" or metadata.timeout == true
		or type(metadata.signal) == "string" or (exit ~= nil and exit ~= 0)
	local status = cancelled and "cancelled" or failed and "failed" or "finished"
	local status_hl = cancelled and "DiagnosticWarn" or failed and "OpenCodeBashError" or "DiagnosticOk"
	local heading = "Shell " .. status
	if exit ~= nil and exit ~= 0 then heading = heading .. " · exit " .. tostring(exit) end
	if metadata.timeout == true then heading = heading .. " · timed out" end
	if type(metadata.signal) == "string" then heading = heading .. " · " .. metadata.signal end
	local result = panel.result()
	panel.add_line(result, tool_panel.header(heading, { fold = true, expanded = expanded }), status_hl)
	if command ~= "" then
		for index, line in ipairs(vim.split(command, "\n", { plain = true })) do
			panel.add_raw_line(result, (index == 1 and "$ " or "  ") .. render.expand_tabs(line, 5), "OpenCodeBashCommand")
		end
	end
	if output == "" or output == "(no output)" then
		panel.add_line(result, "No output", "OpenCodeBashMuted")
	else
		local rows = {}
		for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
			for _, row in ipairs(render.wrap_text(render.expand_tabs(line, 3), math.max(1, render.get_chat_text_width() - 3))) do
				rows[#rows + 1] = row
			end
		end
		for index = 1, expanded and #rows or math.min(MAX_PREVIEW_ROWS, #rows) do
			panel.add_raw_line(result, rows[index])
		end
		if not expanded and #rows > MAX_PREVIEW_ROWS then
			panel.add_line(result, "… " .. tostring(#rows - MAX_PREVIEW_ROWS) .. " more rows · Enter / O to expand", "OpenCodeBashMuted")
		end
	end
	if metadata.truncated == true then panel.add_line(result, "Output truncated by server", "DiagnosticWarn") end
	if expanded then
		if type(metadata.shellID) == "string" then panel.add_line(result, "Shell ID: " .. metadata.shellID, "OpenCodeBashMuted") end
		if type(metadata.jobID) == "string" and metadata.jobID ~= metadata.shellID then
			panel.add_line(result, "Job ID: " .. metadata.jobID, "OpenCodeBashMuted")
		end
	end
	return result
end

return M
