local M = {}
local actions = require("opencode.actions")
local pending = require("opencode.session.pending")
local state = require("opencode.state")

local function notify(message) vim.notify(message, vim.log.levels.WARN) end
local function failure(err, feature)
	return (err.status == 404 or err.status == 405 or err.status == 501 or err.status == 503)
		and (feature .. " is unavailable on this server or location") or (err.message or feature .. " failed")
end

-- Keep unfinished control sequences and CRLF boundaries out of the committed
-- buffer prefix. The visible carry uses the same normalizer as complete output.
local function split_output(text)
	local esc, cut, start, last_plain = string.char(27), #text, 1, 0
	local ambiguous = false
	while true do
		local pos = text:find(esc, start, true)
		if not pos then
			if start <= #text then last_plain = #text end
			break
		end
		if pos > start then last_plain = pos - 1 end
		local kind = text:sub(pos + 1, pos + 1)
		if kind == "" then cut = pos - 1; break end
		if kind == "]" then
			local stop = text:find("[" .. string.char(7) .. esc .. "]", pos + 2)
			if not stop or (text:sub(stop, stop) == esc and stop == #text) then cut = pos - 1; break end
			if text:sub(stop, stop) == string.char(7) then start = stop + 1
			elseif text:sub(stop + 1, stop + 1) == "\\" then start = stop + 2
			else start = stop; last_plain = stop - 1; ambiguous = true end
		elseif kind == "[" then
			local index = pos + 2
			while text:byte(index) and text:byte(index) >= 48 and text:byte(index) <= 63 do index = index + 1 end
			while text:byte(index) and text:byte(index) >= 32 and text:byte(index) <= 47 do index = index + 1 end
			if index > #text then cut = pos - 1; break end
			if text:byte(index) >= 64 and text:byte(index) <= 126 then start = index + 1
			else start = pos + 1; last_plain = pos; ambiguous = true end
		else start = pos + 1; last_plain = pos; ambiguous = true end
	end
	-- Removing OSC can join an otherwise invalid CSI (or another OSC). Keep
	-- ambiguous raw input until the normalizer's remaining suffix is complete.
	if ambiguous and cut > 0 then
		local plain = require("opencode.util.text").strip_ansi(text:sub(1, cut))
		if plain:sub(-1) == "\r" or plain:sub(-1) == esc
			or plain:match(esc .. "%[[0-?]*[ -/]*$")
			or plain:match(esc .. "%][^" .. string.char(7) .. esc .. "]*$") then cut = 0 end
	end
	-- Complete ANSI suffixes disappear before newline normalization, so a CR
	-- preceding them must wait for a possible LF on the next output page.
	if text:sub(last_plain, last_plain) == "\r" then cut = math.min(cut, last_plain - 1) end
	return require("opencode.util.text").normalize_text(text:sub(1, cut), tostring), text:sub(cut + 1)
end

function M.output(entry)
	local float = require("opencode.ui.float")
	local directory, id = entry.location.directory, entry.id
	local timer, inflight, closed, missing, carry, preview, cursor, error_text = nil, nil, false, false, "", "", 0, ""
	local function stop_timer()
		if timer then if not timer:is_closing() then timer:stop(); timer:close() end; timer = nil end
	end
	local popup, bufnr = float.create_centered_popup({ title = " Shell output ", width = 86, height = 24,
		on_close = function() closed = true; stop_timer() end })
	popup:mount()
	float.setup_close_keymaps(bufnr, function() popup:close() end)
	local stable_row, stable_col, end_row, end_col = 3, 0, 3, 0
	local rendered_header, rendered_status, rendered_tail
	local function advance(row, col, lines)
		return row + #lines - 1, #lines[#lines] + (#lines == 1 and col or 0)
	end
	local function render(addition)
		if closed then return end
		addition = addition or ""
		local header, status = "$ " .. entry.command:gsub("\n", " "), "Status: " .. entry.status
		local tail = require("opencode.util.text").normalize_text(carry .. preview, tostring)
		if error_text ~= "" then tail = tail .. "\n" .. error_text end
		if addition == "" and header == rendered_header and status == rendered_status and tail == rendered_tail then return end
		local follow = popup.winid and vim.api.nvim_win_is_valid(popup.winid)
			and vim.api.nvim_win_get_cursor(popup.winid)[1] >= vim.api.nvim_buf_line_count(bufnr) - 1
		if not rendered_header then
			popup:render({ header, status, "", "" })
			rendered_header, rendered_status, rendered_tail = header, status, ""
		end
		local modifiable, readonly = vim.bo[bufnr].modifiable, vim.bo[bufnr].readonly
		vim.bo[bufnr].readonly, vim.bo[bufnr].modifiable = false, true
		if header ~= rendered_header or status ~= rendered_status then
			vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, { header, status })
		end
		if addition ~= "" or tail ~= rendered_tail then
			local lines = vim.split(addition .. tail, "\n", { plain = true })
			vim.api.nvim_buf_set_text(bufnr, stable_row, stable_col, end_row, end_col, lines)
			end_row, end_col = advance(stable_row, stable_col, lines)
			stable_row, stable_col = advance(stable_row, stable_col, vim.split(addition, "\n", { plain = true }))
		end
		vim.bo[bufnr].modifiable, vim.bo[bufnr].readonly = modifiable, readonly
		rendered_header, rendered_status, rendered_tail = header, status, tail
		if follow then vim.api.nvim_win_set_cursor(popup.winid, { end_row + 1, 0 }) end
	end
	local poll
	local function schedule(delay)
		stop_timer()
		if not closed and not missing then timer = vim.defer_fn(poll, delay or 1000) end
	end
	local function live(marker)
		return not closed and inflight == marker and pending.is_current(marker.token)
	end
	poll = function()
		if closed or missing then return end
		schedule()
		if inflight and pending.is_current(inflight.token) then return end
		if not state.is_connected() then error_text = "Disconnected; waiting to resume output"; render(); return end
		local marker = { token = pending.token() }
		inflight = marker
		actions.get_shell(id, { directory = directory }, function(info_err, info)
			if not live(marker) then return end
			if info_err then
				inflight = nil; missing = info_err.status == 404 or info_err.status == 405 or info_err.status == 501
				error_text = failure(info_err, "Shell output"); render(); return
			end
			entry.status, entry.exit = info.status, info.exit
			local start = cursor
			actions.get_shell_output(id, { directory = directory, cursor = start, limit = 65536 }, function(err, page)
				if not live(marker) then return end
				inflight = nil
				if err then
					missing = err.status == 404 or err.status == 405 or err.status == 501; error_text = failure(err, "Shell output"); render(); return
				end
				error_text, preview = "", ""
				local chunk = page.output
				cursor = page.cursor
				-- The server decodes each byte page separately. Re-read a trailing
				-- replacement from the last complete UTF-8 boundary on the next page.
				if chunk:sub(-3) == "\239\191\189" then
					chunk, preview = chunk:sub(1, -4), "\239\191\189"
					cursor = math.min(page.cursor, start + #chunk)
				end
				local addition
				addition, carry = split_output(carry .. chunk)
				render(addition)
				if cursor > start and cursor < page.size then schedule(0) end
			end)
		end)
	end
	render(); poll()
	return popup
end

function M.list(context)
	local sid = context and context.session_id or state.get_session().id
	if not sid then notify("Open a session before listing processes"); return end
	local opts = { directory = state.get_session_directory(sid) or vim.fn.getcwd() }
	local token = pending.token(sid)
	actions.list_shells(opts, function(err, entries)
		if not pending.is_current(token) or state.get_session().id ~= sid then return end
		if err then notify(failure(err, "Shell processes")); return end
		local items = {}
		local function replace(current)
			for index = #items, 1, -1 do items[index] = nil end
			for _, entry in ipairs(current) do
				if entry.metadata.sessionID == sid then
					items[#items + 1] = { label = entry.command:gsub("\n", " "), value = entry.id,
						description = entry.status .. " · " .. entry.location.directory, entry = entry }
				end
			end
			if #items == 0 then items[1] = { label = "No running processes", value = "" } end
		end
		replace(entries)
		local menu, revision = nil, 0
		local function refresh()
			if not pending.is_current(token) then return end
			revision = revision + 1
			local current_revision = revision
			actions.list_shells(opts, function(load_err, current)
				if not pending.is_current(token) or current_revision ~= revision or not menu.popup.winid or not vim.api.nvim_win_is_valid(menu.popup.winid) then return end
				if load_err then notify(failure(load_err, "Shell processes")); return end
				replace(current); menu.refresh()
			end)
		end
		menu = require("opencode.ui.menu").open({ title = " Session processes ", items = items, searchable = true, width = 76,
			on_select = function(item) if pending.is_current(token) and item.entry then M.output(item.entry) end end,
			keys = {
				{ key = "r", label = "r: refresh", handler = refresh },
				{ key = "x", label = "x: kill selected", handler = function(_, item)
					if not pending.is_current(token) or not item.entry then return end
					actions.remove_shell(item.entry.id, { directory = item.entry.location.directory }, function(kill_err)
						if not pending.is_current(token) then return end
						if kill_err then notify(failure(kill_err, "Shell removal")) else refresh() end
					end)
				end },
			} })
	end)
end

function M.background(context)
	local sid = context and context.session_id or state.get_session().id
	if not sid then notify("Open a session before backgrounding work"); return end
	local sync, found = require("opencode.sync"), false
	for _, message in ipairs(sync.get_messages(sid)) do
		for _, part in ipairs(sync.get_parts(message.id)) do
			if part.type == "tool" and part.state.status == "running"
				and (part.raw_tool == "shell" or part.raw_tool == "subagent") then found = true end
		end
	end
	if not found then notify("No foreground shell or subagent tool is available to background"); return end
	actions.background_session(sid, function(err)
		if err then notify(failure(err, "Background execution"))
		else vim.notify("Requested background execution", vim.log.levels.INFO) end
	end)
end

function M.register(palette)
	palette.register({ id = "action.shell", title = "Toggle Shell Mode", description = "Run commands in the session location", category = "actions",
		slash = { name = "shell" }, with_parts = "reject", enter_with_args = true,
		run = function(context)
			if vim.trim(context.args or "") ~= "" then return actions.send(context.args, { mode = "shell", session_id = context.session_id }) end
			require("opencode.ui.chat").focus_input()
			local input = require("opencode.ui.input")
			input.set_mode(input.get_mode() == "shell" and "normal" or "shell")
		end, on_select = function(context) return context.run() end })
	palette.register({ id = "action.background", title = "Background Running Tools", description = "Release foreground shell or subagent work", category = "actions",
		slash = { name = "background" }, run = M.background, on_select = function(context) return context.run() end })
	palette.register({ id = "action.processes", title = "Session Processes", description = "View output or stop one shell process", category = "actions",
		slash = { name = "processes" }, run = M.list, on_select = function(context) return context.run() end })
end

return M
