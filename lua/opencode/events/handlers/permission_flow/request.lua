local M = {}

local sync = require("opencode.sync")

local function nonempty(value)
	return type(value) == "string" and value ~= "" and value or nil
end

local function matching_tool_part(request)
	if not request.message_id or not request.call_id then return nil end
	for _, part in ipairs(sync.get_parts(request.message_id)) do
		if part.callID == request.call_id and part.type == "tool" then return part end
	end
	return nil
end

function M.resolve_tool_input(request)
	local part = matching_tool_part(request)
	if part and type(part.state) == "table" and type(part.state.input) == "table" then
		return part.state.input
	end
	local metadata = request.metadata
	if type(metadata.input) == "table" then return metadata.input end
	return {}
end

function M.resolve_tool_name(request)
	local part = matching_tool_part(request)
	if part then return nonempty(part.tool) or "" end
	return nonempty(request.metadata.tool) or ""
end

---@param data table|nil Native v2 permission request
---@return table|nil, string|nil
function M.decode(data)
	if type(data) ~= "table" then return nil, "permission payload must be a table" end
	local id = nonempty(data.id)
	if not id then return nil, "permission payload missing id" end
	local action = nonempty(data.action)
	if not action then return nil, "permission payload missing action" end
	local session_id = nonempty(data.sessionID)
	if not session_id then return nil, "permission payload missing sessionID" end
	local source = type(data.source) == "table" and data.source or {}
	local message_id = source.type == "tool" and nonempty(source.messageID) or nil
	-- Runtime 2.0.11 emits source.id; later native events may use source.callID.
	local call_id = source.type == "tool" and (nonempty(source.callID) or nonempty(source.id)) or nil
	if not message_id and call_id then message_id = sync.find_message_id_by_call_id(session_id, call_id) end
	local metadata = type(data.metadata) == "table" and data.metadata or {}
	return {
		id = id,
		type = action,
		session_id = session_id,
		message_id = message_id,
		call_id = call_id,
		timestamp = type(data.time) == "table" and type(data.time.created) == "number" and data.time.created / 1000 or nil,
		metadata = metadata,
		kind = "permission",
		location = data._location,
		patterns = type(data.resources) == "table" and data.resources or {},
		always = type(data.save) == "table" and data.save or {},
	}, nil
end

function M.decode_reply(data)
	if type(data) ~= "table" then return nil end
	local id = nonempty(data.requestID)
	if not id then return nil end
	return { id = id, reply = data.reply, session_id = nonempty(data.sessionID), data = data }
end

return M
