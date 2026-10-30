-- opencode.nvim - Display names for tool identifiers
-- One spelling per tool for every widget, permission and task row.

local M = {}

local NAMES = {
	apply_patch = "Apply Patch",
	bash = "Shell",
	codesearch = "Code Search",
	edit = "Edit",
	execute = "Execute",
	glob = "Glob",
	grep = "Grep",
	list = "List",
	neovim_edit = "Neovim Edit",
	neovim_patch = "Neovim Patch",
	patch = "Patch",
	question = "Question",
	read = "Read",
	rg = "Ripgrep",
	shell = "Shell",
	skill = "Skill",
	subagent = "Task",
	task = "Task",
	webfetch = "WebFetch",
	websearch = "WebSearch",
	write = "Write",
}

---Display name of a tool: its known spelling, else its identifier in title case
---("my_tool" and "myTool" become "My Tool"). "" for a missing name.
---@param tool any
---@return string
function M.display_name(tool)
	if type(tool) ~= "string" then
		return ""
	end
	local trimmed = vim.trim(tool)
	if trimmed == "" then
		return ""
	end
	local known = NAMES[trimmed:lower()]
	if known then
		return known
	end
	local spaced = trimmed:gsub("([a-z0-9])([A-Z])", "%1 %2"):gsub("[_%.-]+", " ")
	return (spaced:gsub("(%S)(%S*)", function(first, rest)
		return first:upper() .. rest
	end))
end

return M
