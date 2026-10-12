-- Server snapshots, not the editor's LSP state. No second diagnostic store.
local M = {}
local path = require("opencode.util.path")

local function position(value)
	return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0
end

function M.parse(value, fallback)
	local result = {}
	if type(value) ~= "table" then return result end
	local function add(filename, list)
		if type(filename) ~= "string" or filename == "" or filename:find("[%z\r\n]") or type(list) ~= "table" then return end
		for _, diagnostic in ipairs(list) do
			local start = type(diagnostic) == "table" and type(diagnostic.range) == "table" and diagnostic.range.start
			if type(start) == "table" and position(start.line) and position(start.character)
				and type(diagnostic.message) == "string" and diagnostic.message ~= "" then
				result[#result + 1] = { path = filename, line = start.line + 1, character = start.character,
					message = diagnostic.message, severity = diagnostic.severity or 1 }
			end
		end
	end
	if vim.islist(value) then add(fallback, value) else
		for filename, list in pairs(value) do add(filename, list) end
	end
	table.sort(result, function(a, b)
		if a.path ~= b.path then return a.path < b.path end
		if a.line ~= b.line then return a.line < b.line end
		return a.character < b.character
	end)
	return result
end

function M.collect(session_id)
	local state, sync = require("opencode.state"), require("opencode.sync")
	local record, files = state.get_session_record(session_id), {}
	for _, message in ipairs(sync.get_messages(session_id)) do
		if record and record.revert and message.id == record.revert.messageID then break end
		for _, part in ipairs(sync.get_parts(message.id)) do
			local metadata = type(part.state) == "table" and part.state.metadata
			local value = type(metadata) == "table" and metadata.diagnostics
			if type(value) == "table" then
				local input = part.state.input or {}
				local fallback = input.path or input.filePath or metadata.filePath
				if vim.islist(value) and fallback then files[fallback] = value
				else
					for filename, list in pairs(value) do
						if type(list) == "table" then files[filename] = list end
					end
				end
			end
		end
	end
	return M.parse(files)
end

function M.local_path(filename, session_id)
	local state = require("opencode.state")
	local server = (state.get_config() or {}).server or {}
	if not path.is_absolute(filename) then
		local directory = state.get_session_directory(session_id)
		local record = state.get_session_record(session_id)
		directory = directory or (record and type(record.location) == "table" and record.location.directory)
		if not directory then return nil, "Session location is unavailable" end
		filename = directory .. "/" .. filename
	end
	filename = path.normalize(filename)
	local mapped, longest = nil, 0
	for _, mapping in ipairs(server.path_mappings or {}) do
		local remote, local_root
		if type(mapping) == "table" and type(mapping.remote) == "string" and type(mapping.local_root) == "string" then
			remote, local_root = path.normalize(mapping.remote), path.normalize(mapping.local_root)
		end
		if path.is_absolute(remote) and path.is_absolute(local_root) and path.within(filename, remote) and #remote > longest then
			mapped, longest = local_root .. "/" .. filename:sub(#remote + 1):gsub("^[/\\]+", ""), #remote
		end
	end
	if mapped then return path.normalize(mapped) end
	if server.shared_filesystem == true or (server.shared_filesystem ~= false and state.is_server_managed()) then return filename end
	return nil, "Server file requires server.shared_filesystem=true or server.path_mappings"
end

function M.byte_column(line, character)
	local ok, byte = pcall(vim.str_byteindex, line, "utf-16", character, false)
	return (ok and byte or math.min(character, #line)) + 1
end

function M.jump(item, session_id)
	local filename, err = M.local_path(item.path, session_id)
	if not filename then return nil, err end
	if vim.fn.filereadable(filename) ~= 1 then return nil, "Server diagnostic file is not available locally: " .. filename end
	local ok, failure = pcall(vim.cmd.edit, vim.fn.fnameescape(filename))
	if not ok then return nil, tostring(failure) end
	local row = math.min(item.line, vim.api.nvim_buf_line_count(0))
	local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
	vim.api.nvim_win_set_cursor(0, { row, M.byte_column(line, item.character) - 1 })
	return true
end

function M.quickfix(items, session_id)
	local entries, cache = {}, {}
	for _, item in ipairs(items) do
		local filename = M.local_path(item.path, session_id)
		local available = filename and vim.fn.filereadable(filename) == 1
		if available and not cache[filename] then cache[filename] = vim.fn.readfile(filename) end
		local line = available and cache[filename][item.line] or ""
		entries[#entries + 1] = { filename = available and filename or nil, lnum = item.line,
			col = M.byte_column(line, item.character), valid = available and 1 or 0,
			type = ({ "E", "W", "I", "N" })[item.severity] or "E",
			text = (available and "" or (item.path .. ": ")) .. item.message }
	end
	vim.fn.setqflist({}, " ", { title = "OpenCode server diagnostics", items = entries,
		context = { session_id = session_id, source = "server" } })
	vim.cmd.copen()
end
return M
