-- Shared command definitions for the palette and local slash commands.

local M = {}

local commands = {}
local next_serial = 0

local function as_context(context, id)
	local result = {}
	for key, value in pairs(context or {}) do
		result[key] = value
	end
	result.run = function()
		return M.run(id, result)
	end
	return result
end

function M.register(spec)
	if type(spec) ~= "table"
		or type(spec.id) ~= "string" or spec.id == ""
		or type(spec.title) ~= "string" or spec.title == ""
		or type(spec.category) ~= "string" or spec.category == ""
		or type(spec.run) ~= "function"
	then
		error("Command must have id, title, category, and run")
	end
	if spec.slash ~= nil and (type(spec.slash) ~= "table" or type(spec.slash.name) ~= "string" or spec.slash.name == "") then
		error("Command slash metadata must have a name")
	end

	-- Keep optional command metadata for both UI surfaces and future adapters.
	local record = {}
	for key, value in pairs(spec) do
		record[key] = value
	end
	if spec.slash then
		record.slash = {
			name = spec.slash.name,
			aliases = vim.deepcopy(spec.slash.aliases or {}),
		}
	end
	if record.palette == nil then
		record.palette = true
	end
	record.description = record.description or ""
	local serial = next_serial + 1
	next_serial = serial
	record._serial = serial
	commands[record.id] = record
	return record
end

function M.unregister(id)
	if commands[id] == nil then
		return false
	end
	commands[id] = nil
	return true
end

function M.get(id)
	return commands[id]
end

function M.all()
	local result = {}
	for _, record in pairs(commands) do
		table.insert(result, record)
	end
	table.sort(result, function(a, b)
		return a.id < b.id
	end)
	return result
end

function M.get_slash(name)
	if type(name) ~= "string" then
		return nil
	end
	local newest = nil
	for _, record in pairs(commands) do
		local slash = record.slash
		if slash then
			local matches = slash.name == name
			if not matches then
				for _, alias in ipairs(slash.aliases or {}) do
					if alias == name then
						matches = true
						break
					end
				end
			end
			if matches and (newest == nil or record._serial > newest._serial) then
				newest = record
			end
		end
	end
	return newest
end

function M.enabled(record, context)
	if type(record) == "string" then
		record = commands[record]
	end
	if not record or commands[record.id] ~= record then
		return false
	end
	if record.enabled == nil then
		return true
	end
	if type(record.enabled) == "function" then
		local ok, result = pcall(record.enabled, context)
		return ok and not not result
	end
	return not not record.enabled
end

function M.list_slash()
	local result = {}
	for _, record in ipairs(M.all()) do
		local slash = record.slash
		if slash and M.get_slash(slash.name) == record and M.enabled(record) then
			table.insert(result, {
				id = record.id,
				generation = record._serial,
				name = slash.name,
				aliases = vim.deepcopy(slash.aliases or {}),
				description = record.description,
				category = record.category,
				on_select = record.on_select,
				enter_with_args = record.enter_with_args,
				with_parts = record.with_parts,
			})
		end
	end
	table.sort(result, function(a, b)
		return a.name < b.name
	end)
	return result
end

local function invoke(record, callback, context)
	if not M.enabled(record, context) then
		return false
	end
	local ok, result = pcall(callback, as_context(context, record.id))
	if not ok then
		vim.notify("Command error: " .. tostring(result), vim.log.levels.ERROR)
		return false
	end
	return result ~= false
end

function M.run(id, context)
	local record = commands[id]
	if not record then
		return false
	end
	return invoke(record, record.run, context)
end

function M.select(id, context)
	local record = commands[id]
	if not record or type(record.on_select) ~= "function" then
		return false
	end
	return invoke(record, record.on_select, context)
end

return M
