-- One Visual selection, one streamed explanation, one temporary popup.
local M = {}
local context = require("opencode.explanation.context")
local request = require("opencode.generation.request")
local response_text = require("opencode.explanation.response")
local ui = require("opencode.ui.explanation")
local config, current, connection_listener

local function notify(message)
	vim.notify("OpenCode explanation: " .. tostring(message), vim.log.levels.WARN)
end

local stop_timer = request.stop_timer

local function source_unchanged(record)
	return vim.api.nvim_buf_is_valid(record.bufnr) and vim.api.nvim_buf_is_loaded(record.bufnr)
		and vim.api.nvim_buf_get_changedtick(record.bufnr) == record.changedtick
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

function M.dismiss()
	local record = current
	current = nil
	stop_request(record)
	ui.close()
	return record ~= nil
end

local function validate_request(record)
	if current ~= record then return false end
	if not source_unchanged(record) then fail(record, "Source buffer changed"); return false end
	if not ui.is_open() then M.dismiss(); return false end
	return true
end

-- The display config is the one captured when the request started.
local function hooks(feature_config)
	return {
		current = function(record) return current == record end,
		valid = validate_request,
		in_flight = function(record)
			return current == record and record.phase == "pending" and ui.is_open() and source_unchanged(record)
		end,
		fail = fail,
		unavailable = function(record) fail(record, "OpenCode server is unavailable") end,
		resolve_model = function(lifecycle, value) return lifecycle.resolve_explanation_model(value) end,
		generate = function(...) return require("opencode.client").generate_explanation(...) end,
		update = function(record, text)
			if record.phase ~= "pending" or not validate_request(record) then return end
			local visible = response_text.display(text, feature_config, { streaming = true })
			if visible ~= "" and ui.show(visible, { streaming = true }) == false then M.dismiss() end
		end,
		respond = function(record, request_err, response)
			if request_err then
				if request_err.cancelled then M.dismiss() else fail(record, request_err.message or request_err) end
				return
			end
			if type(response) ~= "string" or vim.trim(response) == "" then
				fail(record, "The model returned an empty explanation")
				return
			end
			record.phase = "ready"
			if ui.show(response_text.display(response, feature_config)) == false then M.dismiss() end
		end,
	}
end

function M.explain_selection()
	if not config or not config.enabled then notify("enable explanation in setup() first"); return false end
	local snapshot, capture_err = require("opencode.util.visual_selection").capture()
	if not snapshot then notify(capture_err); return false end
	local config = request.current_config("explanation", config)
	local model_err = request.validate(config, "explanation")
	if model_err then notify(model_err); return false end
	M.dismiss()
	snapshot.phase = "pending"
	current = snapshot
	if ui.open(snapshot, function() M.dismiss() end) == false then
		M.dismiss()
		notify("Could not open the explanation popup")
		return false
	end
	local prompt, prompt_err = context.build(snapshot, config)
	if not prompt then fail(snapshot, prompt_err); return true end
	request.run(snapshot, config, prompt, hooks(config))
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
