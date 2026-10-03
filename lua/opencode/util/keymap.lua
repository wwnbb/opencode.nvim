-- Temporary buffer mappings restore the previous owner only while still ours.
local M = {}

local function keycode(key)
	return vim.api.nvim_replace_termcodes(key, true, false, true)
end

local function local_mapping(mode, bufnr, key)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
		if keycode(mapping.lhs) == key then return mapping end
	end
end

function M.install(mode, bufnr, key, callback, opts)
	local resolved = keycode(key)
	local mapping = { mode = mode, bufnr = bufnr, key = resolved, callback = callback,
		previous = local_mapping(mode, bufnr, resolved) }
	vim.keymap.set(mode, key, callback, vim.tbl_extend("force", opts or {}, { buffer = bufnr }))
	return mapping
end

function M.restore(mapping)
	if not mapping or not vim.api.nvim_buf_is_valid(mapping.bufnr) then return end
	local current = local_mapping(mapping.mode, mapping.bufnr, mapping.key)
	if not current or current.callback ~= mapping.callback then return end
	vim.keymap.del(mapping.mode, current.lhs, { buffer = mapping.bufnr })
	if mapping.previous then
		vim.api.nvim_buf_call(mapping.bufnr, function()
			vim.fn.mapset(mapping.mode, false, mapping.previous)
		end)
	end
end

return M
