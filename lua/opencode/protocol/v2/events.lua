-- Pure envelope decoding. SSE framing, scheduling and deduplication stay in sse.
local M = {}

function M.decode(value)
	if type(value) ~= "table" or type(value.type) ~= "string" or type(value.data) ~= "table" then
		return nil, "Invalid v2 event envelope"
	end
	if value.id ~= nil and type(value.id) ~= "string" then return nil, "Invalid v2 event ID" end
	if value.durable ~= nil and (type(value.durable) ~= "table"
		or type(value.durable.aggregateID) ~= "string" or type(value.durable.seq) ~= "number"
		or type(value.durable.version) ~= "number") then return nil, "Invalid durable event metadata" end
	local envelope = vim.deepcopy(value)
	local payload = vim.deepcopy(value.data)
	payload._directory = type(value.location) == "table" and value.location.directory or nil
	payload._v2_envelope = envelope
	return { type = value.type, id = value.id, payload = payload, location = value.location }
end

return M
