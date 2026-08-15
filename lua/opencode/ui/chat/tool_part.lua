-- Resolve the current version of a tool part from the sync store.
local M = {}

---@param position table|nil
---@return table|nil
function M.resolve(position)
	if type(position) ~= "table" then
		return nil
	end

	local fallback = type(position.tool_part) == "table" and position.tool_part or position
	local message_id = position.message_id or fallback.messageID
	local part_id = position.part_id or fallback.id
	if message_id and part_id then
		local ok_sync, sync = pcall(require, "opencode.sync")
		if ok_sync and type(sync.get_part) == "function" then
			local ok_part, current = pcall(sync.get_part, message_id, part_id)
			if ok_part and type(current) == "table" then
				return current
			end
		end
	end

	return fallback
end

return M
