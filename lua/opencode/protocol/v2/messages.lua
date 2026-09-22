-- Pure native-message -> chat projection. Native DTOs remain available on info.
local M = {}

function M.error_text(err)
	if type(err) == "string" then return err end
	if type(err) ~= "table" then return "Unknown error" end
	return err.message or err.type or "Unknown error"
end

function M.part_id(session_id, message_id, kind, identity)
	-- Length prefixes avoid collisions when tool IDs contain separators.
	return table.concat({ "v2", #session_id, session_id, #message_id, message_id, kind, tostring(identity) }, ":")
end

local function output(content)
	local texts, files = {}, {}
	for _, item in ipairs(content or {}) do
		if item.type == "text" then texts[#texts + 1] = item.text or ""
		elseif item.type == "file" then files[#files + 1] = vim.deepcopy(item) end
	end
	return table.concat(texts, "\n"), files
end

local function notice(message)
	local kind = message.type
	if kind == "idle" then return nil end
	if kind == "agent-switched" then return "Agent: " .. (message.agent or "unknown") end
	if kind == "model-switched" then
		local model = message.model or {}
		return "Model: " .. (model.providerID or "") .. "/" .. (model.id or "default")
	end
	if kind == "location-switched" then return "Directory: " .. ((message.location or {}).directory or "unknown") end
	if kind == "compaction" then
		return "Compaction: " .. (message.status or "running") .. "\n" .. (message.summary or "")
	end
	if kind == "skill" then return "Skill: " .. (message.name or message.skillID or message.id) .. "\n" .. (message.text or "") end
	if kind == "shell" then return "$ " .. (message.command or "") .. "\n" .. (message.output or "") end
	return message.text or message.description or ("Message: " .. tostring(kind))
end

function M.project(session_id, message)
	assert(type(message) == "table" and type(message.id) == "string" and type(message.type) == "string", "Invalid v2 message")
	local info = vim.deepcopy(message)
	info._v2 = vim.deepcopy(message)
	info.protocol = "v2"
	info.sessionID = session_id
	info.role = (message.type == "user" or message.type == "assistant") and message.type or "system"
	info.hidden = message.type == "idle"
	if message.error then info.error_message = M.error_text(message.error) end
	if message.model then
		info.modelID, info.providerID, info.variant = message.model.id, message.model.providerID, message.model.variant
	end
	local parts, ordinals = {}, {}
	local function append(content)
		local kind = content.type
		local ordinal = ordinals[kind] or 0
		ordinals[kind] = ordinal + 1
		local part = vim.deepcopy(content)
		part.id = M.part_id(session_id, message.id, kind, kind == "tool" and content.id or ordinal)
		part.messageID, part.sessionID, part.protocol = message.id, session_id, "v2"
		part.content_order = #parts + 1
		part.ordinal = ordinal
		if kind == "tool" then
			part.callID, part.tool = content.id, content.name
			part.raw_tool = content.name
			-- Explicit native tool identities; retain the original DTO/name for IO.
			part.tool = ({ subagent = "task", shell = "bash" })[content.name] or content.name
			local state = vim.deepcopy(content.state or {})
			if type(state.input) == "table" then
				if content.name == "subagent" then state.input.subagent_type = state.input.agent end
				if content.name == "read" then state.input.filePath = state.input.path end
			end
			state.native_error = state.error
			if state.error then state.error = M.error_text(state.error) end
			state.output, state.files = output(state.content)
			state.time = { start = (content.time or {}).ran or (content.time or {}).created, ["end"] = (content.time or {}).completed }
			part.state = state
		elseif kind == "file" then
			part.url, part.filename = content.uri, content.name
		end
		parts[#parts + 1] = part
	end
	if message.type == "assistant" then
		for _, content in ipairs(message.content or {}) do append(content) end
	elseif message.type == "user" then
		append({ type = "text", text = message.text or "" })
		for _, file in ipairs(message.files or {}) do
			local part = vim.deepcopy(file); part.type = "file"; append(part)
		end
		for _, agent in ipairs(message.agents or {}) do
			local part = vim.deepcopy(agent); part.type = "agent"; append(part)
		end
		for _, skill in ipairs(message.skills or {}) do
			local part = vim.deepcopy(skill); part.type = "skill"; append(part)
		end
	else
		local text = notice(message)
		if text then append({ type = "text", text = text, synthetic = true }) end
	end
	return { info = info, parts = parts }
end

function M.page(session_id, messages)
	local result = {}
	for _, message in ipairs(messages) do result[#result + 1] = M.project(session_id, message) end
	return result
end

return M
