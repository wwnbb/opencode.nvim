-- Versioned preference file. Preserve files without a supported version.
local M = {}
function M.open(path)
	local uv = vim.uv or vim.loop
	local existed = uv.fs_lstat(path) ~= nil
	local file = io.open(path, "rb")
	local original = file and file:read("*a") or nil
	if file then file:close() end
	local ok, data = pcall(vim.json.decode, original or (not existed and '{"version":2}' or ''))
	local writable = (not existed or original ~= nil) and ok and type(data) == "table" and data.version == 2
	if not writable then
		local reason = ok and type(data) == "table" and data.version == nil and "uses the old versionless format"
			or "has an unsupported or unreadable format"
		vim.notify("OpenCode: preferences file " .. path .. " " .. reason .. "; copy wanted values into a version 2 JSON file before saving preferences", vim.log.levels.WARN)
		data = {}
	end
	local owner = { data = data }
	function owner.save(values)
		if not writable then return false end
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		local next_data = vim.tbl_extend("force", data, values, { version = 2 })
		local encoded = vim.json.encode(next_data)
		local temporary = path .. "." .. tostring(uv.hrtime()) .. ".tmp"
		local fd = uv.fs_open(temporary, "wx", 384)
		if not fd then return false end
		local written = uv.fs_write(fd, encoded, 0); uv.fs_close(fd)
		if written ~= #encoded or not uv.fs_rename(temporary, path) then uv.fs_unlink(temporary); return false end
		data, owner.data = next_data, next_data
		return true
	end
	return owner
end
return M
