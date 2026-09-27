-- One Visual selection, one sessionless generate request, one temporary popup.
local M = {}
local context = require("opencode.explanation.context")
local response_text = require("opencode.explanation.response")
local ui = require("opencode.ui.explanation")
local config, current, connection_listener
local generation = 0

local function notify(message)
	vim.notify("OpenCode explanation: " .. tostring(message), vim.log.levels.WARN)
end

local function stop_timer(record, key)
	if record and record[key] then
		record[key]:stop()
		record[key]:close()
		record[key] = nil
	end
end

local function source_unchanged(record)
	return vim.api.nvim_buf_is_valid(record.bufnr) and vim.api.nvim_buf_is_loaded(record.bufnr)
		and vim.api.nvim_buf_get_changedtick(record.bufnr) == record.changedtick
end

local function active(record)
	return current == record and generation == record.id and ui.is_open() and source_unchanged(record)
end

local function stop_request(record)
	stop_timer(record, "deadline")
	stop_timer(record, "retry_timer")
	if record and record.handle then record.handle.cancel(); record.handle = nil end
end

local function fail(record, message)
	if current ~= record then return end
	current = nil
	stop_request(record)
	if ui.is_open() then ui.error(message) end
end

local function catalog_starting(err, model)
	if type(err) ~= "table" or err.status ~= 400 or err.code ~= "InvalidRequestError" then return false end
	local name = model.providerID .. "/" .. (model.id or model.modelID)
	return err.message == "Model unavailable: " .. name
		or (model.variant ~= nil and err.message == "Variant unavailable for " .. name .. ": " .. model.variant)
end

function M.dismiss()
	generation = generation + 1
	local record = current
	current = nil
	stop_request(record)
	ui.close()
	return record ~= nil
end

function M.explain_selection()
	if not config or not config.enabled then notify("enable explanation in setup() first"); return false end
	local snapshot, capture_err = require("opencode.util.visual_selection").capture()
	if not snapshot then notify(capture_err); return false end
	local state = require("opencode.state")
	local global = state.get_config() or {}
	local managed = not (global.server and global.server.port)
	local _, model_err = require("opencode.completion.profile").validate(config, { managed = managed }, "explanation")
	if model_err then notify(model_err); return false end
	M.dismiss()
	snapshot.id, snapshot.phase = generation, "pending"
	current = snapshot
	if ui.open(snapshot, function() M.dismiss() end) == false then
		M.dismiss()
		notify("Could not open the explanation popup")
		return false
	end
	local prompt, prompt_err = context.build(snapshot, config)
	if not prompt then fail(snapshot, prompt_err); return true end
	snapshot.started = vim.uv.now()
	snapshot.deadline = vim.uv.new_timer()
	snapshot.deadline:start(config.timeout_ms, 0, vim.schedule_wrap(function()
		if current == snapshot then fail(snapshot, "Request timed out") end
	end))
	local lifecycle = require("opencode.lifecycle")
	lifecycle.ensure_connected(function()
		if current ~= snapshot then return end
		if not source_unchanged(snapshot) then fail(snapshot, "Source buffer changed"); return end
		if not ui.is_open() then M.dismiss(); return end
		local model, err = lifecycle.resolve_explanation_model(config)
		if not model then fail(snapshot, err); return end
		local warming_until, attempt = vim.uv.now() + 2000, 0
		local function dispatch()
			if current ~= snapshot then return end
			if not source_unchanged(snapshot) then fail(snapshot, "Source buffer changed"); return end
			if not ui.is_open() then M.dismiss(); return end
			local remaining = config.timeout_ms - (vim.uv.now() - snapshot.started)
			if remaining <= 0 then fail(snapshot, "Request timed out"); return end
			attempt = attempt + 1
			local handle = require("opencode.client").generate_explanation(prompt, model, function(request_err, response)
				if current ~= snapshot then return end
				if not source_unchanged(snapshot) then fail(snapshot, "Source buffer changed"); return end
				if not ui.is_open() then M.dismiss(); return end
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
				if request_err then
					if not request_err.cancelled then fail(snapshot, request_err.message or request_err) end
					return
				end
				if type(response) ~= "string" or vim.trim(response) == "" then
					fail(snapshot, "The model returned an empty explanation")
					return
				end
				stop_timer(snapshot, "deadline")
				snapshot.phase = "ready"
				if ui.show(response_text.display(response, config)) == false then M.dismiss() end
			end, { timeout = remaining })
			if active(snapshot) and snapshot.phase == "pending" then snapshot.handle = handle end
		end
		dispatch()
	end)
	if current == snapshot and (state.get_connection() == "error" or state.get_connection() == "idle") then
		fail(snapshot, "OpenCode server is unavailable")
	end
	return ui.is_open()
end

function M.teardown()
	M.dismiss()
	pcall(vim.api.nvim_del_augroup_by_name, "OpenCodeExplanationController")
	if connection_listener then require("opencode.state").off("connection", connection_listener) end
	connection_listener = nil
	ui.teardown()
	config = nil
end

function M.setup(opts)
	M.teardown()
	config = vim.deepcopy(opts)
	ui.setup(config)
	if not config.enabled then return end
	local group = vim.api.nvim_create_augroup("OpenCodeExplanationController", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "BufWipeout" }, {
		group = group,
		callback = function(event)
			if current and event.buf == current.bufnr and not source_unchanged(current) then fail(current, "Source buffer changed") end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.teardown })
	connection_listener = function(value)
		if current and (value == "error" or value == "idle") then fail(current, "OpenCode server disconnected") end
	end
	require("opencode.state").on("connection", connection_listener)
end

return M
