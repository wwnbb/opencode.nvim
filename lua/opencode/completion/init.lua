-- Editor completion requests, independent of conversation state.
local M = {}
local context = require("opencode.completion.context")
local ui = require("opencode.ui.completion")
local generation = 0
local records = {}
local applying = false
local config
local connection_listener
-- Lua watchers detach on their next event; reuse them across requests and setup.
local watched_buffers = {}

local function notify(message, level)
	vim.notify("OpenCode completion: " .. tostring(message), level or vim.log.levels.WARN)
end

local function stop_timer(record, key)
	if record and record[key] then
		record[key]:stop()
		record[key]:close()
		record[key] = nil
	end
end

local catalog_starting = require("opencode.completion.profile").catalog_starting

local function discard(record)
	if not record or records[record.id] ~= record then return false end
	records[record.id] = nil
	stop_timer(record, "deadline")
	stop_timer(record, "retry_timer")
	if record.handle then record.handle.cancel() end
	ui.clear(record)
	return true
end

local function invalidate(record)
	record.invalidated = true
	vim.schedule(function() discard(record) end)
end

local function watch_source(bufnr)
	if watched_buffers[bufnr] then return true end
	local function each_record(callback)
		local found = false
		for _, record in pairs(records) do
			if record.bufnr == bufnr and not record.invalidated then
				found = true
				callback(record)
			end
		end
		if not found then watched_buffers[bufnr] = nil; return true end
	end
	local function detach()
		each_record(invalidate)
		watched_buffers[bufnr] = nil
		return true
	end
	local attached = vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function(_, _, tick, first, last, new_last)
			return each_record(function(record)
				if (not record.accept_requested and not applying) or (first <= record.row and record.row < last) then
					invalidate(record)
				else
					if last <= record.row then record.row = record.row + new_last - last end
					record.changedtick = tick
				end
			end)
		end,
		on_changedtick = function(_, _, tick)
			return each_record(function(record) record.changedtick = tick end)
		end,
		on_reload = detach,
		on_detach = detach,
	})
	watched_buffers[bufnr] = attached or nil
	return attached
end

local function matches(snapshot)
	if not snapshot or snapshot.invalidated or not context.eligible(snapshot.bufnr)
		or vim.api.nvim_buf_get_changedtick(snapshot.bufnr) ~= snapshot.changedtick then return false end
	if snapshot.accept_requested then return true end
	if vim.api.nvim_get_current_win() ~= snapshot.winid or vim.api.nvim_get_current_buf() ~= snapshot.bufnr then return false end
	local mode = vim.api.nvim_get_mode().mode
	if mode:sub(1, 1) ~= "i" then return false end
	local cursor = vim.api.nvim_win_get_cursor(snapshot.winid)
	return cursor[1] == snapshot.row + 1 and cursor[2] == snapshot.col
end

local function active(record)
	return records[record.id] == record and matches(record)
end

function M.dismiss()
	local found = next(records) ~= nil
	for _, record in pairs(records) do discard(record) end
	ui.clear()
	return found
end

function M.visible()
	local bufnr = vim.api.nvim_get_current_buf()
	for _, record in pairs(records) do
		if record.bufnr == bufnr and (record.phase == "streaming" or record.phase == "ready") and active(record) then return true end
	end
	return false
end

--- Normalize only an unambiguous enclosing code fence; never trim code spaces.
function M.normalize(text, max_lines, streaming)
	if type(text) ~= "string" then return nil, "Invalid completion response" end
	text = text:gsub("\r\n", "\n")
	-- A partial opening fence or language tag is not yet safe to accept.
	if streaming and text:match("^`+[%w_+#%.%-]*$") then return nil end
	local fence, body = text:match("^(```+)[%w_+#%.%-]*\n(.*)$")
	if fence then
		local closing = "\n" .. fence
		if body:sub(-1) == "\n" then body = body:sub(1, -2) end
		if body:sub(-#closing) == closing then text = body:sub(1, -#closing - 1)
		elseif streaming then return nil end
	end
	if vim.trim(text) == "" then return nil end
	if text:find("[%z\1-\8\11-\31\127]") then return nil, "Completion contains control characters" end
	if #text > 16384 then return nil, "Completion exceeds the 16 KiB response limit" end
	local _, newlines = text:gsub("\n", "")
	if newlines + 1 > max_lines then return nil, "Completion exceeds the requested line limit" end
	return text
end

function M.complete()
	if not config or not config.enabled then notify("enable completion in setup() first"); return false end
	local snapshot, capture_err = context.capture()
	if not snapshot then notify(capture_err); return false end
	local state = require("opencode.state")
	local global = state.get_config() or {}
	local config = global.completion or config
	local managed = not (global.server and global.server.port)
	local _, model_err = require("opencode.completion.profile").validate(config, { managed = managed })
	if model_err then notify(model_err); return false end
	local previous
	for _, record in pairs(records) do
		if record.bufnr == snapshot.bufnr and record.row == snapshot.row then
			if record.col == snapshot.col and matches(record) then previous = record.text or record.previous end
			discard(record)
		elseif not record.accept_requested then
			discard(record)
		end
	end
	generation = generation + 1
	snapshot.id, snapshot.phase, snapshot.previous = generation, "pending", previous
	records[snapshot.id] = snapshot
	local prompt, prompt_err = context.build(snapshot, config, previous)
	if not prompt then discard(snapshot); notify(prompt_err); return false end
	if not watch_source(snapshot.bufnr) then discard(snapshot); notify("Could not track the completion source"); return false end
	snapshot.started = vim.uv.now()
	if config.timeout_ms > 0 then
		snapshot.deadline = vim.uv.new_timer()
		snapshot.deadline:start(config.timeout_ms, 0, vim.schedule_wrap(function()
			if records[snapshot.id] ~= snapshot or not snapshot.deadline then return end
			discard(snapshot)
			notify("Request timed out")
		end))
	end
	if ui.pending(snapshot) == false then
		discard(snapshot)
		notify("Could not display the completion indicator")
		return false
	end
	local lifecycle = require("opencode.lifecycle")
	lifecycle.ensure_connected(function()
		if not active(snapshot) then discard(snapshot); return end
		local model, err = lifecycle.resolve_completion_model(config)
		if not model then discard(snapshot); notify(err); return end
		local warming_until, attempt = vim.uv.now() + 2000, 0
		local function dispatch()
			if not active(snapshot) then discard(snapshot); return end
			local remaining = config.timeout_ms > 0 and config.timeout_ms - (vim.uv.now() - snapshot.started) or 0
			if config.timeout_ms > 0 and remaining <= 0 then discard(snapshot); notify("Request timed out"); return end
			attempt = attempt + 1
			local handle = require("opencode.client").generate_completion(prompt, model, function(request_err, response)
				if snapshot.phase ~= "pending" and snapshot.phase ~= "streaming" then return end
				if not active(snapshot) then discard(snapshot); return end
				snapshot.handle = nil
				local warming_left = warming_until - vim.uv.now()
				-- Retry only explicit catalog rejections before generation starts.
				if catalog_starting(request_err, model) and warming_left > 0 then
					local delay = math.min(warming_left, 100 * 2 ^ math.min(attempt - 1, 2))
					snapshot.retry_timer = vim.uv.new_timer()
					snapshot.retry_timer:start(delay, 0, vim.schedule_wrap(function()
						stop_timer(snapshot, "retry_timer")
						dispatch()
					end))
					return
				end
				stop_timer(snapshot, "deadline")
				if request_err then
					discard(snapshot)
					if not request_err.cancelled then notify(request_err.message or request_err, vim.log.levels.ERROR) end
					return
				end
				local text, response_err = M.normalize(response, snapshot.suffix ~= "" and 1 or config.max_lines)
				if not text then
					discard(snapshot)
					if response_err then notify(response_err) end
					return
				end
				snapshot.text, snapshot.phase = text, "ready"
				if ui.show(snapshot, text) == false then discard(snapshot)
				elseif snapshot.accept_requested then M.accept(snapshot.id) end
			end, {
				timeout = remaining, directory = snapshot.root,
				on_update = function(response)
					if records[snapshot.id] ~= snapshot or (snapshot.phase ~= "pending" and snapshot.phase ~= "streaming") then return end
					if not active(snapshot) then discard(snapshot); return end
					local text = M.normalize(response, snapshot.suffix ~= "" and 1 or config.max_lines, true)
					if text == snapshot.text then return end
					snapshot.text, snapshot.phase = text, text and "streaming" or "pending"
					local displayed
					if text then displayed = ui.show(snapshot, text) else displayed = ui.pending(snapshot) end
					if displayed == false then discard(snapshot) end
				end,
			})
			if records[snapshot.id] == snapshot and (snapshot.phase == "pending" or snapshot.phase == "streaming") then snapshot.handle = handle end
		end
		dispatch()
	end)
	if records[snapshot.id] == snapshot and (state.get_connection() == "error" or state.get_connection() == "idle") then
		discard(snapshot)
		return false
	end
	return records[snapshot.id] == snapshot
end

--- Safe inside expr mappings: execute the actual edit after leaving textlock.
function M.accept(id)
	local record = id and records[id]
	if not id then
		local bufnr, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
		for _, candidate in pairs(records) do
			if candidate.bufnr == bufnr and candidate.row == cursor[1] - 1 and candidate.col == cursor[2] then
				record = candidate
				break
			end
		end
	end
	if not record or not active(record) then discard(record); return false end
	if record.phase == "pending" or record.phase == "streaming" then
		if not record.accept_requested and record.suffix == "" and record.prefix:match("^[ \t]+$") then
			-- Native cursor movement keeps untouched autoindent from being stripped on Esc.
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Left><Right>", true, false, true), "in", false)
		end
		record.accept_requested = true
		return true
	end
	if record.phase ~= "ready" then return false end
	local mode = vim.api.nvim_get_mode().mode
	if mode ~= "n" and mode:sub(1, 1) ~= "i" then return true end
	record.phase = "accepting"
	stop_timer(record, "deadline")
	if record.handle then record.handle.cancel(); record.handle = nil end
	ui.clear(record)
	local command = string.format("<Cmd>lua require('opencode.completion')._commit(%d)<CR>", record.id)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(command, true, false, true), "in", false)
	return true
end

function M._commit(id)
	local record = records[id]
	if not record or record.id ~= id or record.phase ~= "accepting" then return false end
	if not active(record) then discard(record); return false end
	local mode = vim.api.nvim_get_mode().mode
	if mode ~= "n" and mode:sub(1, 1) ~= "i" then record.phase = "ready"; return false end
	local winid = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(winid)
	local follow = mode:sub(1, 1) == "i" and vim.api.nvim_get_current_buf() == record.bufnr
		and cursor[1] == record.row + 1 and cursor[2] == record.col
	local replacement = vim.split(record.text, "\n", { plain = true })
	-- Invalidate before the edit so autocmds cannot revive or accept it twice.
	discard(record)
	applying = true
	local ok, err = pcall(vim.api.nvim_buf_call, record.bufnr, function()
		-- Split undo in the target buffer, including when it is hidden or Esc is in progress.
		vim.cmd("noautocmd let &g:undolevels = &g:undolevels")
		vim.api.nvim_buf_set_text(record.bufnr, record.row, record.col, record.row, record.col, replacement)
		vim.cmd("noautocmd let &g:undolevels = &g:undolevels")
	end)
	applying = false
	if not ok then notify(err, vim.log.levels.ERROR); return false end
	if follow then
		local row = record.row + #replacement
		local col = #replacement == 1 and record.col + #replacement[1] or #replacement[#replacement]
		vim.api.nvim_win_set_cursor(winid, { row, col })
	end
	return true
end

function M.teardown()
	M.dismiss()
	pcall(vim.api.nvim_del_augroup_by_name, "OpenCodeCompletionController")
	if connection_listener then require("opencode.state").off("connection", connection_listener) end
	connection_listener = nil
	ui.teardown()
	config = nil
end

function M.setup(opts)
	M.teardown()
	config = vim.deepcopy(opts)
	if not config.enabled then return end
	if vim.fn.has("nvim-0.10") ~= 1 then notify("Inline completion requires Neovim 0.10 or newer"); config.enabled = false; return end
	ui.setup(config)
	local group = vim.api.nvim_create_augroup("OpenCodeCompletionController", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI", "CursorMoved", "TextChanged", "ModeChanged" }, {
		group = group,
		callback = function()
			if applying then return end
			for _, record in pairs(records) do
				if not active(record) then discard(record)
				elseif record.accept_requested and record.phase == "ready" then M.accept(record.id) end
			end
		end,
	})
	vim.api.nvim_create_autocmd("InsertLeave", {
		group = group,
		callback = function()
			for _, record in pairs(records) do
				if not record.accept_requested or not active(record) then discard(record) end
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "BufUnload", "BufWipeout" }, {
		group = group,
		callback = function(event)
			if applying then return end
			for _, record in pairs(records) do
				if not active(record) or (event.buf == record.bufnr
					and (not record.accept_requested or event.event == "BufUnload" or event.event == "BufWipeout")) then
					discard(record)
				end
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.teardown })
	connection_listener = function(value)
		if value == "error" or value == "idle" then M.dismiss() end
	end
	require("opencode.state").on("connection", connection_listener)
end

return M
