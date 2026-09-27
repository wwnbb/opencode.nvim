-- Pure prompt and selection conversion; transport/state are handled by callers.
local M = {}

local function mention(text, part)
	local source = type(part.source) == "table" and (part.source.text or part.source)
	if type(source) ~= "table" or type(source.value) ~= "string" or source.value == "" then return nil end
	local first, last = source.start, source["end"]
	if type(first) ~= "number" or type(last) ~= "number" or first < 0 or last < first
		or text:sub(first + 1, last) ~= source.value then
		-- Clipboard markers move with the input; attach a range only for a unique
		-- exact occurrence. Agent extmarks already provide verified byte offsets.
		if part.type ~= "file" then return nil end
		local a, b = text:find(source.value, 1, true)
		if not a or text:find(source.value, b + 1, true) then return nil end
		first, last = a - 1, b
	end
	local prefix = text:sub(1, last)
	-- TUI 2.0.11 uses grapheme display cells, not JS string indices. Tab stops
	-- and compound emoji differ between renderers; ranges are optional for them.
	if prefix:find("\t", 1, true) or prefix:find("‍", 1, true) or prefix:find("️", 1, true) then return nil end
	for character in prefix:gmatch("[\240-\244][\128-\191][\128-\191][\128-\191]") do
		local code = vim.fn.char2nr(character)
		if code >= 0x1f1e6 and code <= 0x1f1ff then return nil end
	end
	local function cells(value)
		local lines = vim.split(value, "\n", { plain = true })
		local width = #lines - 1
		for _, line in ipairs(lines) do width = width + vim.fn.strdisplaywidth(line) end
		return width
	end
	return { start = cells(text:sub(1, first)), ["end"] = cells(prefix), text = source.value }
end

function M.model(ref, variant)
	if type(ref) ~= "table" or type(ref.providerID) ~= "string" or type(ref.id or ref.modelID) ~= "string" then
		return nil, "A model with providerID and catalog id is required"
	end
	local selected_variant = variant or ref.variant
	if selected_variant == "default" then selected_variant = nil end
	return { providerID = ref.providerID, id = ref.id or ref.modelID, variant = selected_variant }
end

function M.prompt(text, opts, id)
	opts = opts or {}
	if type(text) ~= "string" then return nil, "Prompt text must be a string" end
	for _, field in ipairs({ "noReply", "system", "tools" }) do
		if opts[field] ~= nil then return nil, "V2 prompts do not support " .. field end
	end
	if opts.delivery ~= nil and opts.delivery ~= "queue" and opts.delivery ~= "steer" then
		return nil, "Prompt delivery must be queue or steer"
	end
	local body = { id = id, text = text, delivery = opts.delivery or "queue", resume = opts.resume, metadata = opts.metadata }
	local function append(key, value)
		body[key] = body[key] or {}; body[key][#body[key] + 1] = value
	end
	for _, group in ipairs({ opts.context or {}, opts.parts or {} }) do
		for _, part in ipairs(group) do
			if part.type == "text" then
				body.text = body.text .. "\n\n" .. (part.text or "")
			elseif part.type == "file" then
				local uri = part.uri or part.url
				if type(uri) ~= "string" or not uri:match("^%a[%w+.-]*:") then return nil, "File attachment requires a URI" end
				append("files", { uri = uri, name = part.name or part.filename, description = part.description, mention = mention(text, part) })
			elseif part.type == "agent" then
				if type(part.name) ~= "string" then return nil, "Agent attachment requires a name" end
				append("agents", { name = part.name, mention = mention(text, part) })
			elseif part.type == "skill" then
				if type(part.skillID or part.id) ~= "string" then return nil, "Skill attachment requires a catalog id" end
				append("skills", { id = part.skillID or part.id, mention = mention(text, part) })
			else return nil, "Unsupported prompt part: " .. tostring(part.type) end
		end
	end
	return body
end

return M
