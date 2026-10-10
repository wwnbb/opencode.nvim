-- Neovim's terminal emulator displays the remote persistent PTY directly.
local M = {}
local actions = require("opencode.actions")
local state = require("opencode.state")
local pending = require("opencode.session.pending")
local records = {}

local function report(err)
	local message = (err.status == 404 or err.status == 405 or err.status == 501 or err.status == 503) and "Persistent terminals are unavailable on this server" or tostring(err.message or err)
	vim.notify("Could not use terminal: " .. message, vim.log.levels.ERROR)
end

local function selected(record)
	local endpoint = actions.terminal_endpoint()
	return endpoint and endpoint.identity == record.endpoint_identity and state.get_session().id == record.session_id
		and state.get_session_directory(record.session_id) == record.directory
		and vim.api.nvim_buf_is_valid(record.bufnr)
end

local function current(record)
	local endpoint = actions.terminal_endpoint()
	return pending.is_current(record.token) and selected(record) and endpoint.generation == record.endpoint_generation
end

local function status(record, text)
	if record.winid and vim.api.nvim_win_is_valid(record.winid) and vim.api.nvim_win_get_buf(record.winid) == record.bufnr then
		vim.wo[record.winid].winbar = " OpenCode terminal: " .. text .. "  |  <C-\\><C-n> normal  R reconnect  q detach"
	end
end

local function decode_checkpoint(encoded)
	local decoder = vim.base64 and vim.base64.decode or vim.fn.base64decode
	local ok, data = pcall(decoder, encoded)
	if ok and type(data) == "string" and #data <= 8 * 1024 * 1024 then return data end
end

local function write(record, data)
	if current(record) then vim.api.nvim_chan_send(record.channel, data) end
end

local function size(record)
	if record.winid and vim.api.nvim_win_is_valid(record.winid) then
		return math.max(1, vim.api.nvim_win_get_width(record.winid)), math.max(1, vim.api.nvim_win_get_height(record.winid))
	end
	return record.cols or 80, record.rows or 24
end

local function detach(record)
	if not record then return end
	record.detached, record.revision = true, (record.revision or 0) + 1
	if record.handle then record.handle.close(); record.handle = nil end
	status(record, "detached; process remains on server")
end

local attach
local function snapshot(record)
	local revision = record.revision
	actions.get_terminal_snapshot(record.id, record.session_id, function(err, result)
		if not current(record) or record.detached or record.revision ~= revision then return end
		if err then report(err); status(record, "snapshot unavailable"); return end
		if result.info.id ~= record.id or result.info.sessionID ~= record.session_id then report({ message = "Server returned a different terminal" }); return end
		local checkpoint = decode_checkpoint(result.checkpoint)
		if not checkpoint then report({ message = "Invalid terminal checkpoint" }); return end
		record.cursor = result.info.output.tail
		write(record, "\27c" .. checkpoint)
		attach(record)
	end)
end

attach = function(record)
	if not current(record) or record.detached then return end
	if record.handle then record.handle.close() end
	record.revision = (record.revision or 0) + 1
	local revision = record.revision
	status(record, "connecting")
	local function valid() return current(record) and not record.detached and revision == record.revision end
	local err
	record.handle, err = actions.connect_terminal({ id = record.id, session_id = record.session_id, directory = record.directory,
		cursor = record.cursor, attachment_id = record.attachment_id,
		on_data = function(data, cursor)
			if not valid() then return end
			record.cursor = cursor; write(record, data)
		end,
		on_event = function(event, cursor)
			if not valid() then return end
			record.cursor = cursor
			if event.type == "resync" then record.cursor = nil; snapshot(record)
			elseif event.type == "replay_complete" then
				record.retries, record.warned_input = 0, false
				status(record, "connected")
				local cols, rows = size(record); record.cols, record.rows = cols, rows
				if record.handle then record.handle.control(cols, rows) end
			elseif event.type == "resized" then
				local checkpoint = decode_checkpoint(event.checkpoint)
				if not checkpoint then detach(record); report({ message = "Invalid terminal resize checkpoint" }); return end
				write(record, "\27c" .. checkpoint)
			elseif event.type == "exited" then record.exited = true; status(record, "exited") end
		end,
		on_error = function(failure) if valid() then report(failure) end end,
		on_close = function(reason, cursor)
			if revision ~= record.revision or record.detached then return end
			record.cursor = cursor
			status(record, reason == "stale" and "session changed; detached" or "disconnected; R reconnects")
			if not valid() or record.exited or reason == "detached" or reason == "stale" or reason == "protocol_error" or reason == "unavailable" then return end
			record.retries = (record.retries or 0) + 1
			if record.retries <= 3 then vim.defer_fn(function() if valid() then attach(record) end end, record.retries * 1000) end
		end,
	})
	if err then report(err); status(record, "connection unavailable; R reconnects") end
end

local function reconnect(record)
	if not selected(record) then vim.notify("Select this terminal's session and server first", vim.log.levels.WARN); return end
	detach(record)
	local token, endpoint, revision = pending.token(record.session_id), actions.terminal_endpoint(), record.revision
	status(record, "validating terminal")
	actions.get_terminal(record.id, record.session_id, function(err, info)
		local latest = actions.terminal_endpoint()
		if record.revision ~= revision or not pending.is_current(token) or not selected(record)
			or not latest or latest.generation ~= endpoint.generation then return end
		if err then report(err); status(record, "terminal unavailable"); return end
		if info.id ~= record.id or info.sessionID ~= record.session_id or info.cwd ~= record.terminal_cwd then
			report({ message = "Server returned a different terminal" }); return
		end
		if record.endpoint_generation ~= endpoint.generation then record.cursor = nil end
		record.token, record.endpoint_generation = token, endpoint.generation
		record.winid = vim.api.nvim_get_current_win()
		record.detached, record.retries, record.exited = false, 0, info.status == "exited"
		if record.cursor then attach(record) else snapshot(record) end
	end)
end

function M.open(info, session_id, directory)
	local token, endpoint = pending.token(session_id), actions.terminal_endpoint()
	if not endpoint then report({ message = "Server endpoint is unavailable" }); return end
	actions.get_terminal(info.id, session_id, function(err, fresh)
		local latest = actions.terminal_endpoint()
		if not pending.is_current(token) or not latest or latest.identity ~= endpoint.identity or latest.generation ~= endpoint.generation
			or state.get_session().id ~= session_id or state.get_session_directory(session_id) ~= directory then return end
		if err then report(err); return end
		if fresh.id ~= info.id or fresh.sessionID ~= session_id then report({ message = "Server returned a different terminal" }); return end
		local record = records[info.id]
		if record and (record.session_id ~= session_id or record.directory ~= directory or not pending.is_current(record.token)
			or record.endpoint_identity ~= endpoint.identity or record.endpoint_generation ~= endpoint.generation
			or not vim.api.nvim_buf_is_valid(record.bufnr)) then detach(record); record = nil end
		vim.cmd("tabnew")
		if record then vim.api.nvim_win_set_buf(0, record.bufnr)
		else
			local bufnr = vim.api.nvim_get_current_buf()
			local nonce = (vim.uv or vim.loop).random(16)
			if not nonce then report({ message = "Could not create terminal attachment ID" }); return end
			record = { id = info.id, session_id = session_id, directory = directory, token = token, bufnr = bufnr,
				attachment_id = vim.fn.sha256(nonce):sub(1, 32), revision = 0, terminal_cwd = fresh.cwd,
				endpoint_identity = endpoint.identity, endpoint_generation = endpoint.generation }
			records[info.id] = record
			vim.bo[bufnr].buflisted, vim.bo[bufnr].bufhidden, vim.bo[bufnr].swapfile = false, "hide", false
			record.channel = vim.api.nvim_open_term(bufnr, { force_crlf = false, on_input = function(_, _, _, data)
				local sent = record.handle and record.handle.input(data, record.cols or 80, record.rows or 24)
				if not sent and not record.warned_input then
					record.warned_input = true
					vim.schedule(function() if current(record) then vim.notify("Terminal is reconnecting; input was not sent", vim.log.levels.WARN) end end)
				end
			end })
			vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, { buffer = bufnr, callback = function(event)
				detach(record)
				if event.event == "BufWipeout" and records[record.id] == record then records[record.id] = nil end
			end })
			vim.keymap.set("n", "R", function() reconnect(record) end, { buffer = bufnr, silent = true })
			vim.keymap.set("n", "q", function()
				detach(record); vim.cmd(#vim.api.nvim_list_tabpages() > 1 and "tabclose" or "enew")
			end, { buffer = bufnr, silent = true })
		end
		record.winid, record.detached, record.retries, record.exited = vim.api.nvim_get_current_win(), false, 0, false
		vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn, vim.wo.foldcolumn = false, false, "no", "0"
		record.cols, record.rows = size(record)
		if record.cursor then attach(record) else snapshot(record) end
		vim.cmd("startinsert")
	end)
end

function M.show()
	local session_id = state.get_session().id
	if not session_id then vim.notify("Open a session first", vim.log.levels.WARN); return end
	local directory, token = state.get_session_directory(session_id), pending.token(session_id)
	local function valid() return pending.is_current(token) and state.get_session().id == session_id and state.get_session_directory(session_id) == directory end
	actions.list_terminals(session_id, function(err, terminals)
		if not valid() then return end
		if err then report(err); return end
		local items = {}
		for _, info in ipairs(terminals) do
			if info.sessionID == session_id then items[#items + 1] = { label = info.title, description = info.status .. " · " .. info.cwd, info = info } end
		end
		if #items == 0 then items[1] = { label = "Create terminal", create = true } end
		local function create()
			if not valid() then return end
			actions.create_terminal(session_id, { args = {}, env = vim.empty_dict(), cwd = directory, title = "Terminal",
				size = { cols = math.max(1, vim.o.columns), rows = math.max(1, vim.o.lines - 4) } }, function(create_err, info)
				if not valid() then return end
				if create_err then report(create_err) else M.open(info, session_id, directory) end
			end)
		end
		require("opencode.ui.menu").open({ title = " Persistent Terminals ", message = directory, items = items, width = 76, searchable = true,
			on_select = function(item) if valid() then if item.create then create() else M.open(item.info, session_id, directory) end end end,
			keys = {
				{ key = "n", label = "n:new", handler = function(ctx) if valid() then ctx.close(); create() end end },
				{ key = "d", label = "d:remove", handler = function(ctx, item)
					if not valid() or item.create then return end
					ctx.close()
					require("opencode.ui.menu").open({ title = " Remove Terminal? ", message = "Stop " .. item.info.title .. " and remove its terminal?",
						items = { "Remove", "Cancel" }, sort = false, on_select = function(choice)
							if choice ~= "Remove" or not valid() then return end
							actions.remove_terminal(item.info.id, session_id, function(remove_err)
								if not valid() then return end
								if remove_err then report(remove_err) else detach(records[item.info.id]); M.show() end
							end)
						end })
				end },
			} })
	end)
end

function M.detach_all() for _, record in pairs(records) do detach(record) end end
function M.clear_session(session_id) for _, record in pairs(records) do if record.session_id == session_id then detach(record) end end end

function M.register(palette)
	palette.register({ id = "session.terminals", title = "Persistent Terminals", description = "Create, attach, or remove remote session terminals",
		category = "session", slash = { name = "terminals" }, on_select = function(context) return context.run() end, run = M.show,
		enabled = function() return state.get_session().id ~= nil end })
end

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { callback = function()
	for _, record in pairs(records) do
		if current(record) and not record.detached and record.handle then
			record.cols, record.rows = size(record); record.handle.control(record.cols, record.rows)
		end
	end
end })

return M
