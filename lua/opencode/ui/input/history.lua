-- opencode.nvim - Input history and session drafts

local M = {}

local HISTORY_VERSION = 2
local store = {
	entries = {},
	index = 1,
	max_entries = 100,
	history_file = vim.fn.stdpath("data") .. "/opencode_input_history.json",
	loaded = false,
	loaded_file = nil,
	read_only = false,
	drafts = {},
}

local function positive_int(value, fallback)
	local number = tonumber(value)
	if not number or number < 1 then return fallback end
	return math.floor(number)
end

local function session_key(session_id)
	if session_id == nil then
		local ok, state = pcall(require, "opencode.state")
		if ok then session_id = (state.get_session() or {}).id end
	end
	return session_id or ""
end

local function draft(session_id)
	return store.drafts[session_key(session_id)]
end

---@param parts table[]|nil
---@return table[]
function M.copy_parts(parts)
	local copied = {}
	for _, part in ipairs(parts or {}) do
		if type(part) == "table" then copied[#copied + 1] = vim.deepcopy(part) end
	end
	return copied
end

local function history_parts(parts)
	local copied = M.copy_parts(parts)
	for _, part in ipairs(copied) do
		-- Buffer extmark IDs and the originating session are UI state, not prompt
		-- content. Keep the marker so a removed image is not sent on recall.
		part._mention = nil
		part._session_id = nil
		local source = type(part.source) == "table" and (part.source.text or part.source) or nil
		if part.type == "file" and not part._marker and type(source) == "table" then
			part._marker = source.value
		end
	end
	return copied
end

local function normalized_entry(entry)
	if type(entry) == "string" then return { text = entry, parts = {}, mode = "normal" } end
	if type(entry) ~= "table" or type(entry.text) ~= "string" then return nil end
	local parts = entry.parts or entry.skills or {}
	if type(parts) ~= "table" then return nil end
	return {
		text = entry.text,
		parts = history_parts(parts),
		mode = entry.mode == "shell" and "shell" or "normal",
	}
end

local function trim()
	while #store.entries > store.max_entries do table.remove(store.entries, 1) end
	store.index = #store.entries + 1
end

local function save()
	if store.read_only then return end
	if not require("opencode.util.json_file").write(store.history_file, { version = HISTORY_VERSION, entries = store.entries }) then
		vim.notify("OpenCode: could not save prompt history; previous file preserved", vim.log.levels.WARN)
	end
end

---@param cfg table|nil
function M.configure(cfg)
	cfg = cfg or {}
	local history_file = cfg.history_file or store.history_file
	if history_file ~= store.history_file then
		store.history_file = history_file
		store.loaded = false
		store.loaded_file = nil
		store.read_only = false
		store.entries = {}
		store.index = 1
	end
	store.max_entries = positive_int(cfg.max_history, store.max_entries)
	trim()
end

function M.load()
	if store.loaded and store.loaded_file == store.history_file then return end
	store.entries = {}
	store.read_only = false
	local decoded = require("opencode.util.json_file").read(store.history_file)
	if type(decoded) == "table" then
		if decoded.version ~= nil and decoded.version ~= HISTORY_VERSION then store.read_only = true end
		local entries = decoded.version == HISTORY_VERSION and decoded.entries
			or decoded.version == nil and decoded or nil
		if type(entries) == "table" and vim.islist(entries) then
			for _, value in ipairs(entries) do
				local entry = normalized_entry(value)
				if entry then store.entries[#store.entries + 1] = entry end
			end
		else store.read_only = true end
	elseif (vim.uv or vim.loop).fs_lstat(store.history_file) then
		store.read_only = true
	end
	store.loaded = true
	store.loaded_file = store.history_file
	trim()
end

---@param text string|nil
---@param parts table[]|nil
---@param mode string|nil
function M.add(text, parts, mode)
	if type(text) ~= "string" or (text == "" and #(parts or {}) == 0) then return end
	M.load()
	local entry = normalized_entry({ text = text, parts = parts or {}, mode = mode })
	if not entry then return end
	if #store.entries > 0 and vim.deep_equal(store.entries[#store.entries], entry) then return end
	store.entries[#store.entries + 1] = entry
	trim()
	save()
end

local function recalled(entry)
	return entry.text, M.copy_parts(entry.parts), entry.mode
end

local function can_move(text, parts, mode)
	if text == nil or (text == "" and #(parts or {}) == 0) then return true end
	return vim.deep_equal(store.entries[store.index], normalized_entry({ text = text, parts = parts, mode = mode }))
end

function M.previous(text, parts, mode)
	if store.index <= 1 or not can_move(text, parts, mode) then return nil end
	store.index = store.index - 1
	return recalled(store.entries[store.index])
end

function M.next(text, parts, mode)
	if not can_move(text, parts, mode) then return nil end
	if store.index < #store.entries then
		store.index = store.index + 1
		return recalled(store.entries[store.index])
	end
	if store.index == #store.entries then
		store.index = store.index + 1
		return "", {}, "normal"
	end
	return nil
end

---@param text string|nil
---@param parts table[]|nil
---@param session_id string|nil
function M.set_pending(text, parts, session_id)
	local key = session_key(session_id)
	local current = store.drafts[key] or { text = "", parts = {}, mode = "normal" }
	local content = text or ""
	if content ~= current.text then current.cursor = nil end
	current.text = content
	if parts ~= nil then current.parts = M.copy_parts(parts) end
	store.drafts[key] = current
end

function M.append_pending(text, session_id)
	local content = text or ""
	if content == "" then return end
	M.set_pending(M.get_pending(session_id) .. content, nil, session_id)
end

function M.clear_pending(session_id)
	local key = session_key(session_id)
	local deferred = (store.drafts[key] or {}).deferred
	store.drafts[key] = deferred and #deferred > 0 and { deferred = deferred } or nil
end

function M.clear_session(session_id)
	store.drafts[session_key(session_id)] = nil
end

function M.defer_pending(value, session_id)
	local key = session_key(session_id)
	local current = store.drafts[key] or {}
	current.deferred = current.deferred or {}
	current.deferred[#current.deferred + 1] = vim.deepcopy(value)
	store.drafts[key] = current
end

function M.take_deferred(session_id)
	local current = draft(session_id)
	if not current or not current.deferred then return nil end
	local value = table.remove(current.deferred, 1)
	if #current.deferred == 0 then current.deferred = nil end
	return value
end

function M.peek_deferred(session_id)
	local current = draft(session_id)
	return current and current.deferred and vim.deepcopy(current.deferred[1]) or nil
end

function M.get_pending(session_id)
	return (draft(session_id) or {}).text or ""
end

function M.set_pending_parts(parts, session_id)
	M.set_pending(M.get_pending(session_id), parts, session_id)
end

function M.get_pending_parts(session_id)
	return M.copy_parts((draft(session_id) or {}).parts)
end

function M.set_pending_options(options, session_id)
	local key = session_key(session_id)
	local current = store.drafts[key] or { text = "", parts = {}, mode = "normal" }
	current.options = type(options) == "table" and vim.deepcopy(options) or nil
	store.drafts[key] = current
end

function M.get_pending_options(session_id)
	local options = (draft(session_id) or {}).options
	return type(options) == "table" and vim.deepcopy(options) or nil
end

function M.set_pending_cursor(offset, session_id)
	local key = session_key(session_id)
	local current = store.drafts[key] or { text = "", parts = {}, mode = "normal" }
	current.cursor = type(offset) == "number" and math.max(0, math.floor(offset)) or nil
	store.drafts[key] = current
end

function M.get_pending_cursor(session_id)
	return (draft(session_id) or {}).cursor
end

function M.set_pending_mode(mode, session_id)
	local key = session_key(session_id)
	local current = store.drafts[key] or { text = "", parts = {}, mode = "normal" }
	current.mode = mode == "shell" and "shell" or "normal"
	store.drafts[key] = current
end

function M.get_pending_mode(session_id)
	return (draft(session_id) or {}).mode or "normal"
end

function M.clear()
	store.entries = {}
	store.index = 1
	store.drafts = {}
	store.read_only = false
	store.loaded = true
	store.loaded_file = store.history_file
	os.remove(store.history_file)
end

---@return string[]
function M.entries()
	return vim.tbl_map(function(entry) return entry.text end, store.entries)
end

function M.list()
	M.load()
	return vim.deepcopy(store.entries)
end

return M
