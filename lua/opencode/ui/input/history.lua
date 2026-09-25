-- opencode.nvim - Input history and drafts

local M = {}

local store = {
	entries = {},
	index = 1,
	max_entries = 100,
	history_file = vim.fn.stdpath("data") .. "/opencode_input_history.json",
	loaded = false,
	loaded_file = nil,
	pending = nil,
	pending_parts = nil,
}

local function positive_int(value, fallback)
	local number = tonumber(value)
	if not number or number < 1 then
		return fallback
	end
	return math.floor(number)
end

---@param parts table[]|nil
---@return table[]
function M.copy_parts(parts)
	local copied = {}
	for _, part in ipairs(parts or {}) do
		table.insert(copied, vim.deepcopy(part))
	end
	return copied
end

local function entry_text(entry)
	return type(entry) == "table" and entry.text or entry
end

local function entry_parts(entry)
	return M.copy_parts(type(entry) == "table" and entry.skills or {})
end

local function history_entry(text, parts)
	local skills, seen = {}, {}
	for _, part in ipairs(parts or {}) do
		local id = part.skillID or part.id
		if part.type == "skill" and type(id) == "string" and not seen[id] then
			local source = type(part.source) == "table" and (part.source.text or part.source) or nil
			skills[#skills + 1] = { type = "skill", id = id, name = type(part.name) == "string" and part.name or nil,
				_marker = type(source) == "table" and source.value or part._marker }
			seen[id] = true
		end
	end
	return #skills > 0 and { text = text, skills = skills } or text
end

local function trim()
	while #store.entries > store.max_entries do
		table.remove(store.entries, 1)
	end
	store.index = #store.entries + 1
end

local function save()
	local dir = vim.fn.fnamemodify(store.history_file, ":h")
	vim.fn.mkdir(dir, "p")

	local file = io.open(store.history_file, "w")
	if not file then
		return
	end
	file:write(vim.json.encode(store.entries))
	file:close()
end

---@param cfg table|nil
function M.configure(cfg)
	cfg = cfg or {}
	local history_file = cfg.history_file or store.history_file
	if history_file ~= store.history_file then
		store.history_file = history_file
		store.loaded = false
		store.loaded_file = nil
		store.entries = {}
		store.index = 1
	end

	store.max_entries = positive_int(cfg.max_history, store.max_entries)
	trim()
end

function M.load()
	if store.loaded and store.loaded_file == store.history_file then
		return
	end

	store.entries = {}
	local file = io.open(store.history_file, "r")
	if file then
		local content = file:read("*all")
		file:close()
		local ok, entries = pcall(vim.json.decode, content)
		if ok and type(entries) == "table" then
			store.entries = entries
		end
	end

	store.loaded = true
	store.loaded_file = store.history_file
	trim()
end

---@param text string|nil
function M.add(text, parts)
	if not text or text == "" then
		return
	end

	local entry = history_entry(text, parts)
	if #store.entries > 0 and vim.deep_equal(store.entries[#store.entries], entry) then
		return
	end

	table.insert(store.entries, entry)
	trim()
	save()
end

---@return string|nil
function M.previous()
	if store.index <= 1 then
		return nil
	end

	store.index = store.index - 1
	return entry_text(store.entries[store.index]), entry_parts(store.entries[store.index])
end

---@return string|nil
function M.next()
	if store.index < #store.entries then
		store.index = store.index + 1
		return entry_text(store.entries[store.index]), entry_parts(store.entries[store.index])
	end

	if store.index == #store.entries then
		store.index = store.index + 1
		return "", {}
	end

	return nil
end

---@param text string|nil
---@param parts table[]|nil
function M.set_pending(text, parts)
	local content = text or ""
	store.pending = content ~= "" and content or nil

	if parts ~= nil then
		store.pending_parts = #parts > 0 and M.copy_parts(parts) or nil
	end
end

---@param text string
function M.append_pending(text)
	local content = text or ""
	if content == "" then
		return
	end
	store.pending = (store.pending or "") .. content
end

function M.clear_pending()
	store.pending = nil
	store.pending_parts = nil
end

---@return string
function M.get_pending()
	return store.pending or ""
end

---@param parts table[]|nil
function M.set_pending_parts(parts)
	local copied = M.copy_parts(parts)
	store.pending_parts = #copied > 0 and copied or nil
end

---@return table[]
function M.get_pending_parts()
	return M.copy_parts(store.pending_parts)
end

function M.clear()
	store.entries = {}
	store.index = 1
	store.pending = nil
	store.pending_parts = nil
	store.loaded = true
	store.loaded_file = store.history_file
	os.remove(store.history_file)
end

---@return table[]
function M.entries()
	return vim.tbl_map(entry_text, store.entries)
end

return M
