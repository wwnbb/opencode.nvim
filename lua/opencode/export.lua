-- Pure formatters for the native session export response. The server owns
-- completeness and sanitization; callers pass its { info, messages } payload.
local M = {}
local fence_code = require("opencode.util.text").fence_code

local function pretty_json(value)
	local encoded = vim.json.encode(value)
	local result, depth, in_string, escaped = {}, 0, false, false
	local function append(value) result[#result + 1] = value end
	local function newline() append("\n" .. string.rep("  ", depth)) end
	local index = 1
	while index <= #encoded do
		local char = encoded:sub(index, index)
		if in_string then
			append(char)
			if escaped then escaped = false
			elseif char == "\\" then escaped = true
			elseif char == '"' then in_string = false end
		elseif char == '"' then
			in_string = true
			append(char)
		elseif char == "{" or char == "[" then
			local close = char == "{" and "}" or "]"
			if encoded:sub(index + 1, index + 1) == close then
				append(char .. close)
				index = index + 1
			else
				append(char)
				depth = depth + 1
				newline()
			end
		elseif char == "}" or char == "]" then
			depth = depth - 1
			newline()
			append(char)
		elseif char == "," then
			append(char)
			newline()
		elseif char == ":" then
			append(": ")
		else
			append(char)
		end
		index = index + 1
	end
	return table.concat(result)
end

function M.json(transcript)
	assert(type(transcript) == "table", "Expected session export payload")
	return pretty_json(transcript) .. "\n"
end

local function date_string(value)
	if type(value) == "string" then return value end
	if type(value) ~= "number" then return "Unknown" end
	local ok, formatted = pcall(os.date, "%Y-%m-%d %H:%M:%S", math.floor(value / 1000))
	return ok and formatted or "Unknown"
end

local function title(info)
	if type(info.title) == "string" then return info.title end
	local prefix = info.parentID and "Child session" or "New session"
	local created = type(info.time) == "table" and info.time.created
	if type(created) ~= "number" then return prefix end
	local ok, utc = pcall(os.date, "!%Y-%m-%dT%H:%M:%S", math.floor(created / 1000))
	if not ok then return prefix end
	return string.format("%s - %s.%03dZ", prefix, utc, created % 1000)
end

local function tool_output(state)
	if state.status == "error" then
		local err = state.error
		return type(err) == "table" and (err.message or "") or (type(err) == "string" and err or "")
	end
	if state.status == "streaming" or state.status == "running" then return "" end
	local entries = {}
	for _, content in ipairs(state.content or {}) do
		if content.type == "text" then
			entries[#entries + 1] = content.text or ""
		elseif content.type == "file" then
			entries[#entries + 1] = content.name or content.uri or ""
		end
	end
	return table.concat(entries, "\n")
end

local function tool_text(item)
	local state = type(item.state) == "table" and item.state or {}
	local input = state.input
	if type(input) ~= "string" then input = pretty_json(input == nil and vim.NIL or input) end
	return string.format("**Tool: %s**\n\n**Input:**\n%s\n\n%s", item.name or "unknown", fence_code(input, "json"), tool_output(state))
end

local function shell_text(message)
	local output = type(message.output) == "table" and message.output.output or ""
	return "## Shell\n\n" .. fence_code("$ " .. (message.command or "") .. "\n" .. (output or ""))
end

function M.markdown(transcript, opts)
	assert(type(transcript) == "table", "Expected session export payload")
	opts = opts or {}
	local info = type(transcript.info) == "table" and transcript.info or {}
	local time = type(info.time) == "table" and info.time or {}
	local sections = {}
	for _, message in ipairs(transcript.messages or {}) do
		if message.type == "user" then
			sections[#sections + 1] = "## User\n\n" .. (message.text or "")
		elseif message.type == "shell" then
			sections[#sections + 1] = shell_text(message)
		elseif message.type == "assistant" then
			local parts = {}
			for _, item in ipairs(message.content or {}) do
				if item.type == "text" then
					parts[#parts + 1] = item.text or ""
				elseif item.type == "reasoning" and opts.thinking then
					parts[#parts + 1] = "_Thinking:_\n\n" .. (item.text or "")
				elseif item.type == "tool" and opts.tools ~= false then
					parts[#parts + 1] = tool_text(item)
				end
			end
			if #parts > 0 then sections[#sections + 1] = "## Assistant\n\n" .. table.concat(parts, "\n\n") end
		end
	end
	return string.format("# %s\n\n**Session ID:** %s\n**Created:** %s\n**Updated:** %s\n\n---\n\n%s\n",
		title(info), info.id or "", date_string(time.created), date_string(time.updated),
		table.concat(sections, "\n\n---\n\n"))
end

return M
