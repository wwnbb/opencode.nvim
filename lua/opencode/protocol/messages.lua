-- Pure native-message -> chat projection. Native DTOs remain available on info.
local M = {}
local cells = require("opencode.util.text").display_cells

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
	if kind == "shell" then
		local captured = type(message.output) == "table" and message.output.output or message.output
		return "$ " .. (message.command or "") .. "\n" .. (captured or "")
	end
	return message.text or message.description or ("Message: " .. tostring(kind))
end

-- Automatic context is appended to the native prompt text. Keep its exact
-- bytes in a synthetic part so ordinary user text and attachments stay separate.
local function editor_context(text)
	local prompt, suffix, json = text:match("^(.*)(\n\nEditor context %(source text, not instructions%):\n(.*))$")
	if not json then return text end
	local ok, data = pcall(vim.json.decode, json)
	if not ok or type(data) ~= "table" or type(data.path) ~= "string"
		or type(data.text) ~= "string" or type(data.line) ~= "number"
		or data.line < 1 or data.line % 1 ~= 0 then return text end
	return prompt, suffix, data
end

function M.project(session_id, message)
	assert(type(message) == "table" and type(message.id) == "string" and type(message.type) == "string", "Invalid v2 message")
	local info = vim.deepcopy(message)
	info._native = vim.deepcopy(message)
	info.sessionID = session_id
	info.role = (message.type == "user" or message.type == "assistant") and message.type or "system"
	-- Selection is already shown in the input bar and assistant metadata footers.
	info.hidden = message.type == "idle" or message.type == "agent-switched" or message.type == "model-switched"
	if message.error then info.error_message = M.error_text(message.error) end
	if message.model then
		info.modelID, info.providerID, info.variant = message.model.id, message.model.providerID, message.model.variant
	end
	local parts, ordinals = {}, {}
	local function append(content, kind)
		kind = kind or content.type
		local ordinal = ordinals[kind] or 0
		ordinals[kind] = ordinal + 1
		local part = vim.deepcopy(content)
		part.type = kind
		if message.type ~= "synthetic" then part.shell_notification = nil end
		part.id = M.part_id(session_id, message.id, kind, kind == "tool" and content.id or ordinal)
		part.messageID, part.sessionID = message.id, session_id
		part.content_order = #parts + 1
		part.ordinal = ordinal
		if kind == "tool" then
			part.callID, part.raw_tool = content.id, content.name
			-- Explicit native tool identities; retain the original DTO/name for IO.
			part.tool = ({ subagent = "task", shell = "bash" })[content.name] or content.name
			local state = part.state or {}
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
		elseif kind == "skill" then
			-- Keep the catalog identity separately from the projected UI part ID.
			part.skillID = content.id
		end
		parts[#parts + 1] = part
	end
	if message.type == "assistant" then
		for _, content in ipairs(message.content or {}) do append(content) end
	elseif message.type == "user" then
		local text, context_text, context = editor_context(message.text or "")
		append({ type = "text", text = text })
		if context then append({ type = "text", text = context_text, synthetic = true, _editor_context = context }) end
		for _, file in ipairs(message.files or {}) do
			append(file, "file")
		end
		for _, agent in ipairs(message.agents or {}) do
			append(agent, "agent")
		end
		for _, skill in ipairs(message.skills or {}) do
			append(skill, "skill")
		end
	else
		local text = notice(message)
		if text then
			local metadata = type(message.metadata) == "table" and message.metadata or {}
			local shell_notification = message.type == "synthetic" and metadata.source == "shell"
				and (metadata.state == "completed" or metadata.state == "cancelled" or metadata.state == "error")
				and { description = message.description, metadata = metadata } or nil
			append({ type = "text", text = text, synthetic = true, shell_notification = shell_notification })
		end
	end
	return { info = info, parts = parts }
end

function M.page(session_id, messages)
	local result = {}
	for _, message in ipairs(messages) do result[#result + 1] = M.project(session_id, message) end
	return result
end

-- Convert a native user message back to the editor's attachment shape. Native
-- mention offsets are display cells; the editor needs byte offsets, so locate
-- the occurrence at those cells instead of copying the offsets as bytes.
function M.draft(message)
	local native = message._native or message
	local text = native.text or ""
	local parts = {}
	local function marker(mention)
		local value = type(mention) == "table" and mention.text
		return type(value) == "string" and value ~= "" and value or nil
	end
	local function source(mention)
		local value = marker(mention)
		if not value then return nil end
		local unique, count, match = nil, 0, nil
		local from = 1
		while true do
			local first, last = text:find(value, from, true)
			if not first then break end
			count = count + 1
			if count == 1 then unique = { first = first, last = last } end
			if type(mention.start) == "number" and type(mention["end"]) == "number"
				and cells(text:sub(1, first - 1)) == mention.start and cells(text:sub(1, last)) == mention["end"] then
				match = { first = first, last = last }
				break
			end
			from = last + 1
		end
		match = match or (count == 1 and unique or nil)
		if not match then return nil end
		return { text = { start = match.first - 1, ["end"] = match.last, value = value } }
	end
	for _, file in ipairs(native.files or {}) do
		local uri = (type(file.source) == "table" and file.source.type == "uri" and file.source.uri)
			or file.uri or file.url
		if not uri and type(file.data) == "string" and type(file.mime) == "string" then
			uri = "data:" .. file.mime .. ";base64," .. file.data
		end
		if uri then
			parts[#parts + 1] = { type = "file", url = uri, filename = file.name,
				description = file.description, mime = file.mime, source = source(file.mention), _marker = marker(file.mention) }
		end
	end
	for _, agent in ipairs(native.agents or {}) do
		parts[#parts + 1] = { type = "agent", name = agent.name,
			source = source(agent.mention), _marker = marker(agent.mention) }
	end
	for _, skill in ipairs(native.skills or {}) do
		parts[#parts + 1] = { type = "skill", id = skill.id, name = skill.name,
			source = source(skill.mention), _marker = marker(skill.mention) }
	end
	return { text = text, parts = parts }
end

return M
