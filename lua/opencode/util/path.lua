local M = {}

-- Check server paths without resolving them against the editor's local cwd.
function M.is_absolute(path)
	return type(path) == "string" and not path:find("[%z\r\n]")
		and (path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\")
end

-- Normalize comparison paths without erasing filesystem roots.
function M.normalize(path)
	if not path or path == "" then return nil end
	local windows = path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\"
	local normalized = vim.fs.normalize(path, { win = windows or nil })
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
