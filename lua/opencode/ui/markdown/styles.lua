local M = {}
local default_styles = {}
local composites = {}
local function apply_composite(group, names)
	local attrs = {}
	for _, name in ipairs(names) do attrs = vim.tbl_extend("force", attrs, vim.api.nvim_get_hl(0, { name = name, link = false })) end
	vim.api.nvim_set_hl(0, group, attrs)
end
require("opencode.ui.highlights").register("markdown", function()
	local styles = {
		Heading = { "Function", bold = true }, Heading1 = { "Function", bold = true, underline = true },
		Strong = { "Special", bold = true }, Emphasis = { "Type", italic = true },
		Strike = { "Comment" }, Code = { "String" },
		Link = { "Underlined", underline = true }, LinkText = { "Identifier", underline = true },
		Quote = { "Comment", italic = true }, Border = { "Comment" }, List = { "Function" },
		Punctuation = { "Delimiter" }, Escape = { "SpecialChar" }, Entity = { "String" }, Text = { "Normal" },
	}
	for name, spec in pairs(styles) do
		local source = vim.api.nvim_get_hl(0, { name = spec[1], link = false })
		local attrs = { fg = source.fg, ctermfg = source.ctermfg, default = true }
		for key, value in pairs(spec) do if type(key) == "string" then attrs[key] = value end end
		local group = "OpenCodeMarkdown" .. name
		local current = vim.api.nvim_get_hl(0, { name = group, link = false })
		-- Refresh generated defaults on ColorScheme, retaining user overrides.
		if next(current) == nil or vim.deep_equal(current, default_styles[group]) then
			attrs.default = nil
			vim.api.nvim_set_hl(0, group, attrs)
			default_styles[group] = vim.api.nvim_get_hl(0, { name = group, link = false })
		end
	end
	for group, names in pairs(composites) do
		apply_composite(group, names)
	end
end)

local captures = {
	["markup.heading"] = "Heading", ["markup.heading.1"] = "Heading1",
	["markup.strong"] = "Strong", ["markup.italic"] = "Emphasis", ["markup.strikethrough"] = "Strike",
	["markup.raw"] = "Code", ["markup.raw.block"] = "Code", ["markup.link"] = "Link",
	["markup.link.url"] = "Link", ["markup.link.label"] = "LinkText", ["markup.quote"] = "Quote",
	["markup.list"] = "List", ["punctuation.special"] = "Punctuation", ["string.escape"] = "Escape",
	["character.special"] = "Entity", ["label"] = "LinkText", ["spell"] = "Text", ["nospell"] = "Text",
}
for level = 2, 6 do captures["markup.heading." .. level] = "Heading" end

function M.capture(name)
	return captures[name] and "OpenCodeMarkdown" .. captures[name] or nil
end

function M.combine(names)
	local unique = {}
	for _, name in ipairs(names) do
		if unique[#unique] ~= name then unique[#unique + 1] = name end
	end
	if #unique < 2 then return unique[1] end
	local group = "OpenCodeMarkdownCombined" .. table.concat(unique, "_"):gsub("OpenCodeMarkdown", "")
	if not composites[group] then
		composites[group] = unique
		apply_composite(group, unique)
	end
	return group
end

return M
