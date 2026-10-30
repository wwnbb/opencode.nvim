local M = {}

function M.text(result)
	return table.concat(result.lines, "\n")
end

function M.contains(value, expected)
	assert.is_truthy(value:find(expected, 1, true), "Missing " .. vim.inspect(expected) .. " in " .. vim.inspect(value))
end

function M.panel_text(result)
	local lines = {}
	for _, line in ipairs(result.lines) do
		if line:sub(1, #"   │") == "   │" then
			lines[#lines + 1] = line:gsub("^   │ ?", ""):gsub(" +$", "")
		end
	end
	return table.concat(lines, "\n")
end

---The spinner frame a row ends with, or nil (rows share tool_panel.ANIM_FRAMES).
---@param line string
---@return string|nil
function M.spinner(line)
	local trimmed = vim.trim(line or "")
	local last = vim.fn.strcharpart(trimmed, vim.fn.strchars(trimmed) - 1)
	return vim.tbl_contains(require("opencode.ui.chat.tool_panel").ANIM_FRAMES, last) and last or nil
end

return M
