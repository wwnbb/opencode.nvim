-- Persist unsent prompts independently of history and server state.
local M = {}
local filename, owner
local function store()
	local config = require("opencode.state").get_config() or {}
	local target = (config.input or {}).stash_file or vim.fn.stdpath("data") .. "/opencode_stash.json"
	if target ~= filename then filename, owner = target, require("opencode.preferences").open(target) end
	return owner
end
local function scope() return require("opencode.util.path").absolute(vim.fn.getcwd()) end
local function entries()
	local data = store().data.scopes
	local values = type(data) == "table" and data[scope()] or {}
	local result = {}
	for _, entry in ipairs(type(values) == "table" and values or {}) do
		if type(entry) == "table" and type(entry.id) == "string" and entry.id ~= ""
			and type(entry.text) == "string" and type(entry.parts) == "table" and vim.islist(entry.parts) then
			local valid = true
			for _, part in ipairs(entry.parts) do if type(part) ~= "table" then valid = false; break end end
			if valid then
				local copied = vim.deepcopy(entry)
				copied.mode = copied.mode == "shell" and "shell" or "normal"
				copied.options = type(entry.options) == "table" and type(entry.options.context) == "table"
					and { context = require("opencode.ui.input.history").copy_parts(entry.options.context) } or nil
				result[#result + 1] = copied
			end
		end
	end
	return result
end
local function save(values)
	local scopes = vim.deepcopy(type(store().data.scopes) == "table" and store().data.scopes or {})
	scopes[scope()] = values
	if not store().save({ scopes = scopes }) then return nil, "Could not save prompt stash; previous file preserved" end
	return true
end
function M.list() return entries() end
function M.push(draft)
	if type(draft) ~= "table" or type(draft.text) ~= "string" or type(draft.parts) ~= "table" then return nil, "Invalid prompt draft" end
	if draft.text == "" and #draft.parts == 0 then return nil, "The prompt is empty" end
	local values = entries()
	local entry = { id = tostring(vim.uv.hrtime()), text = draft.text, parts = require("opencode.ui.input.history").copy_parts(draft.parts),
		mode = draft.mode == "shell" and "shell" or "normal", created = os.time() }
	-- Only prompt content travels across sessions/restarts, not request ownership.
	if type(draft.options) == "table" and type(draft.options.context) == "table" then
		entry.options = { context = require("opencode.ui.input.history").copy_parts(draft.options.context) }
	end
	for _, part in ipairs(entry.parts) do part._mention, part._session_id = nil, nil end
	table.insert(values, 1, entry)
	local ok, err = save(values)
	if not ok then return nil, err end
	return vim.deepcopy(entry)
end
function M.take(id)
	local values = entries()
	for index, entry in ipairs(values) do
		if id == nil or entry.id == id then
			table.remove(values, index)
			local ok, err = save(values)
			if not ok then return nil, err end
			return entry
		end
	end
	return nil, "Stashed prompt is no longer available"
end
return M
