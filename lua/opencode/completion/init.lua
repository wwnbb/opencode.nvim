-- One editor completion request, independent of conversation state and SSE.
local M = {}
local context = require("opencode.completion.context")
local ui = require("opencode.ui.completion")
local generation = 0
local current
local config
local connection_listener

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

-- OpenCode initializes the base model catalog lazily, separately from the
-- project's catalogs. These exact errors reject before contacting a provider.
-- Never retry timeouts, provider errors, or uncertain generation admissions.
local function catalog_starting(err, model)
	if type(err) ~= "table" or err.status ~= 400 or err.code ~= "InvalidRequestError" then return false end
	local name = model.providerID .. "/" .. (model.id or model.modelID)
	return err.message == "Model unavailable: " .. name
		or (model.variant ~= nil and err.message == "Variant unavailable for " .. name .. ": " .. model.variant)
end

local function matches(snapshot)
	if not snapshot or not context.eligible(snapshot.bufnr) or not vim.api.nvim_win_is_valid(snapshot.winid) then return false end
	if vim.api.nvim_get_current_win() ~= snapshot.winid or vim.api.nvim_get_current_buf() ~= snapshot.bufnr
		or vim.api.nvim_win_get_buf(snapshot.winid) ~= snapshot.bufnr
		or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i"
		or vim.api.nvim_buf_get_changedtick(snapshot.bufnr) ~= snapshot.changedtick then return false end
	local cursor = vim.api.nvim_win_get_cursor(snapshot.winid)
	return cursor[1] == snapshot.row + 1 and cursor[2] == snapshot.col
end

local function active(record)
	return current == record and record.id == generation and matches(record)
end

function M.dismiss()
	generation = generation + 1
	local record = current
	current = nil
	stop_timer(record, "deadline")
	stop_timer(record, "retry_timer")
	if record and record.handle then record.handle.cancel() end
	ui.clear()
	return record ~= nil
end

function M.visible()
	return current ~= nil and current.phase == "ready" and active(current)
end

--- Normalize only an unambiguous enclosing code fence; never trim code spaces.
function M.normalize(text, max_lines)
	if type(text) ~= "string" then return nil, "Invalid completion response" end
	text = text:gsub("\r\n", "\n")
	local fence, language, body = text:match("^(```+)([%w_+#%.%-]*)\n(.*)$")
	if fence and language and body then
		local closing = "\n" .. fence
		if body:sub(-1) == "\n" then body = body:sub(1, -2) end
		if body:sub(-#closing) == closing then text = body:sub(1, -#closing - 1) end
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
	local managed = not (global.server and global.server.port)
	local _, model_err = require("opencode.completion.profile").validate(config, { managed = managed })
	if model_err then notify(model_err); return false end
	local previous = current and matches(current) and (current.text or current.previous) or nil
	M.dismiss()
	snapshot.id, snapshot.phase, snapshot.previous = generation, "pending", previous
	current = snapshot
	local prompt, prompt_err = context.build(snapshot, config, previous)
	if not prompt then M.dismiss(); notify(prompt_err); return false end
	snapshot.started = vim.uv.now()
	snapshot.deadline = vim.uv.new_timer()
	snapshot.deadline:start(config.timeout_ms, 0, vim.schedule_wrap(function()
		if current ~= snapshot then return end
		M.dismiss()
		notify("Request timed out", vim.log.levels.WARN)
	end))
	if ui.pending(snapshot) == false then
		M.dismiss()
		notify("Could not display the completion indicator")
		return false
	end
	local lifecycle = require("opencode.lifecycle")
	lifecycle.ensure_connected(function()
		if not active(snapshot) then if current == snapshot then M.dismiss() end; return end
		local model, err = lifecycle.resolve_completion_model(config)
		if not model then M.dismiss(); notify(err); return end
		local warming_until, attempt = vim.uv.now() + 2000, 0
		local function dispatch()
			if not active(snapshot) then if current == snapshot then M.dismiss() end; return end
			local remaining = config.timeout_ms - (vim.uv.now() - snapshot.started)
			if remaining <= 0 then M.dismiss(); notify("Request timed out"); return end
			attempt = attempt + 1
			local handle = require("opencode.client").generate_completion(prompt, model, function(request_err, response)
				if not active(snapshot) then if current == snapshot then M.dismiss() end; return end
				snapshot.handle = nil
				local warming_left = warming_until - vim.uv.now()
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
					M.dismiss()
					if not request_err.cancelled then notify(request_err.message or request_err, vim.log.levels.ERROR) end
					return
				end
				local text, response_err = M.normalize(response, snapshot.suffix ~= "" and 1 or config.max_lines)
				if not text then
					M.dismiss()
					if response_err then notify(response_err) end
					return
				end
				snapshot.text, snapshot.phase = text, "ready"
				if ui.show(snapshot, text) == false then M.dismiss() end
			end, { timeout = remaining })
			if current == snapshot and snapshot.phase == "pending" then snapshot.handle = handle end
		end
		dispatch()
	end)
	if current == snapshot and (state.get_connection() == "error" or state.get_connection() == "idle") then
		M.dismiss()
		return false
	end
	return current == snapshot
end

--- Safe inside expr mappings: execute the actual edit after leaving textlock.
function M.accept()
	if not M.visible() then M.dismiss(); return false end
	local record = current
	record.phase = "accepting"
	ui.clear()
	local command = string.format("<C-g>u<Cmd>lua require('opencode.completion')._commit(%d)<CR><C-g>u", record.id)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(command, true, false, true), "in", false)
	return true
end

function M._commit(id)
	local record = current
	if not record or record.id ~= id or record.phase ~= "accepting" then return false end
	if not active(record) then M.dismiss(); return false end
	local replacement = vim.split(record.text, "\n", { plain = true })
	-- Invalidate before the edit so autocmds cannot revive or accept it twice.
	M.dismiss()
	vim.api.nvim_buf_set_text(record.bufnr, record.row, record.col, record.row, record.col, replacement)
	local row = record.row + #replacement
	local col = #replacement == 1 and record.col + #replacement[1] or #replacement[#replacement]
	vim.api.nvim_win_set_cursor(record.winid, { row, col })
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
	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI", "CursorMoved", "TextChanged" }, {
		group = group,
		callback = function() if current and not active(current) then M.dismiss() end end,
	})
	vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "WinLeave", "BufWipeout" }, {
		group = group,
		callback = function(event)
			if current and (event.buf == current.bufnr or not active(current)) then M.dismiss() end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.teardown })
	connection_listener = function(value)
		if current and (value == "error" or value == "idle") then M.dismiss() end
	end
	require("opencode.state").on("connection", connection_listener)
end

return M
