-- Versioned preference file. Preserve the original before changing ID semantics.
local M = {}
function M.open(path)
	local file = io.open(path, "rb")
	local original = file and file:read("*a") or nil
	if file then file:close() end
	local ok, data = pcall(vim.json.decode, original or "{}")
	local writable = ok and type(data) == "table" and (data.version == nil or data.version == 2)
	if not writable then
		vim.notify("OpenCode: preferences file is unreadable or newer; preserving " .. path, vim.log.levels.WARN)
		data = {}
	end
	local legacy = original and data.version == nil
	local owner = { data = data }
	function owner.save(values)
		if not writable then return false end
		vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
		local uv = vim.uv or vim.loop
		if legacy then
			local backup = path .. ".v1.bak"
			if not uv.fs_stat(backup) then
				local fd = uv.fs_open(backup, "wx", 384)
				if not fd then return false end
				local written = uv.fs_write(fd, original, 0); uv.fs_close(fd)
				if written ~= #original then return false end
			end
		end
		local next_data = vim.tbl_extend("force", data, values, { version = 2 })
		local encoded = vim.json.encode(next_data)
		local temporary = path .. "." .. tostring(uv.hrtime()) .. ".tmp"
		local fd = uv.fs_open(temporary, "wx", 384)
		if not fd then return false end
		local written = uv.fs_write(fd, encoded, 0); uv.fs_close(fd)
		if written ~= #encoded or not uv.fs_rename(temporary, path) then uv.fs_unlink(temporary); return false end
		data, legacy, owner.data = next_data, false, next_data
		return true
	end
	return owner
end

-- A legacy upstream ID may be converted only when its provider offers exactly
-- one matching logical ID. Ambiguous/unavailable records remain intact.
function M.canonical_model(model, provider)
	if type(model) ~= "table" or type(provider) ~= "table" or type(provider.models) ~= "table" then return model end
	if provider.models[model.modelID] then return model end
	local match
	for id, info in pairs(provider.models) do
		if info.upstream_model_id == model.modelID then
			if match then return model end
			match = id
		end
	end
	if match then return vim.tbl_extend("force", model, { modelID = match }) end
	return model
end
return M
