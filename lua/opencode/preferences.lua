-- Versioned preference file. Preserve files without a supported version.
local M = {}
function M.open(path)
	local uv = vim.uv or vim.loop
	local existed = uv.fs_lstat(path) ~= nil
	local data, read_err = require("opencode.util.json_file").read(path)
	if not existed and read_err == "ENOENT" then data = { version = 2 } end
	local writable = type(data) == "table" and data.version == 2
	if not writable then
		local reason = type(data) == "table" and data.version == nil and "uses the old versionless format"
			or "has an unsupported or unreadable format"
		vim.notify("OpenCode: preferences file " .. path .. " " .. reason .. "; copy wanted values into a version 2 JSON file before saving preferences", vim.log.levels.WARN)
		data = {}
	end
	local owner = { data = data }
	function owner.save(values)
		if not writable then return false end
		local next_data = vim.tbl_extend("force", data, values, { version = 2 })
		if not require("opencode.util.json_file").write(path, next_data) then return false end
		data, owner.data = next_data, next_data
		return true
	end
	return owner
end
return M
