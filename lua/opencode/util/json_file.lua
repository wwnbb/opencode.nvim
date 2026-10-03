local M = {}

function M.read(path)
	local stat, err, code = (vim.uv or vim.loop).fs_stat(path)
	if not stat then return nil, code or err end
	if stat.type ~= "file" then return nil, "Not a regular file" end
	local file, open_err = io.open(path, "rb")
	if not file then return nil, open_err end
	local content = file:read("*a")
	local closed, close_err = file:close()
	if not closed then return nil, close_err end
	local ok, value = pcall(vim.json.decode, content)
	if ok then return value end
	return nil, value
end

-- Encode before touching disk; replace the destination only after a full write.
function M.write(path, value)
	local ok, encoded = pcall(vim.json.encode, value)
	if not ok then return false end
	path = vim.fn.resolve(path)
	local uv = vim.uv or vim.loop
	local stat = uv.fs_stat(path)
	if stat and stat.type ~= "file" then return false end
	if not pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p") then return false end
	local temporary = path .. "." .. tostring(uv.hrtime()) .. ".tmp"
	local fd = uv.fs_open(temporary, "wx", 384)
	if not fd then return false end
	local written = uv.fs_write(fd, encoded, 0)
	local closed = uv.fs_close(fd)
	if written ~= #encoded or not closed or not uv.fs_rename(temporary, path) then
		uv.fs_unlink(temporary)
		return false
	end
	return true
end

return M
