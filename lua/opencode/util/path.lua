local M = {}

-- Normalize comparison paths without erasing filesystem roots.
function M.normalize(path)
	if not path or path == "" then return nil end
	local normalized = vim.fs and vim.fs.normalize and vim.fs.normalize(path) or path
	if normalized == "/" or normalized:match("^%a:/$") then return normalized end
	return (normalized:gsub("/+$", ""))
end

function M.absolute(path)
	return M.normalize(vim.fn.fnamemodify(path, ":p"))
end

function M.within(path, root)
	local prefix = root:sub(-1) == "/" and root or root .. "/"
	return path == root or path:sub(1, #prefix) == prefix
end

return M
