local M = {}
function M.valid(record, session_id, directory)
	if type(record) ~= "table" or record.protocolVersion ~= 1 or record.sessionID ~= session_id
		or type(record.location) ~= "table" or record.location.directory ~= directory
		or type(record.revision) ~= "number" or record.revision < 0 or record.revision % 1 ~= 0
		or type(record.todos) ~= "table" or not vim.islist(record.todos) then return false end
	local ids = {}
	for _, item in ipairs(record.todos) do
		if type(item) ~= "table" or type(item.id) ~= "string" or item.id == "" or ids[item.id]
			or type(item.content) ~= "string" or item.content == ""
			or not vim.tbl_contains({ "pending", "in_progress", "completed", "cancelled" }, item.status)
			or (item.priority ~= nil and not vim.tbl_contains({ "high", "medium", "low" }, item.priority)) then return false end
		ids[item.id] = true
	end
	return true
end
return M
