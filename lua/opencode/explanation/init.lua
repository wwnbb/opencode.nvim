-- One Visual selection, one streamed explanation, one temporary popup.
-- Follow-up questions reuse the captured selection context; each is a new
-- temporary request carrying the earlier turns.
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

local function scratch_directory()
	local directory = vim.fs.joinpath(vim.fn.stdpath("cache"), "opencode.nvim", "explanation")
	vim.fn.mkdir(directory, "p")
	return directory
end

local function source_unchanged(record)
	return vim.api.nvim_buf_is_valid(record.bufnr) and vim.api.nvim_buf_is_loaded(record.bufnr)
		and vim.api.nvim_buf_get_changedtick(record.bufnr) == record.changedtick
end

local function stop_request(record)
	stop_timer(record, "deadline")
	stop_timer(record, "retry_timer")
	if record and record.handle then record.handle.cancel(); record.handle = nil end
end

-- The popup's conversation so far, with each question quoted.
local function transcript(record)
	local blocks = {}
	for _, turn in ipairs(record.turns) do
		if turn.question then blocks[#blocks + 1] = "> " .. turn.question:gsub("\n", "\n> ") end
		if turn.answer then blocks[#blocks + 1] = turn.answer end
	end
	return table.concat(blocks, "\n\n")
end

local function fail(record, message)
	if current ~= record then return end
	stop_request(record)
	local last = record.turns and record.turns[#record.turns]
	if last and last.question and not last.answer then
		-- A failed follow-up keeps the earlier answers open for another question.
		table.remove(record.turns)
		record.phase = "ready"
	else
		current = nil
	end
	if ui.is_open() then ui.error(message) end
end

function M.dismiss()
	local record = current
	current = nil
	stop_request(record)
	ui.close()
	return record ~= nil
end

-- The display config is the one captured when the request started.
-- Follow-ups always ask for <answer> markers, so they display as the default prompt.
local function hooks(owner, feature_config, follow_up)
	local display_config = follow_up and {} or feature_config
	-- A failed follow-up leaves its record current; late replies must not reach it.
	local generation = owner.generation
	local function live(record)
		return current == record and record.phase == "pending" and record.generation == generation
	end
	local function valid(record)
		if not live(record) then return false end
		if not source_unchanged(record) then fail(record, "Source buffer changed"); return false end
		if not ui.is_open() then M.dismiss(); return false end
		return true
	end
	return {
		current = live,
		valid = valid,
		in_flight = function(record) return live(record) and ui.is_open() and source_unchanged(record) end,
		fail = function(record, message) if live(record) then fail(record, message) end end,
		unavailable = function(record) if live(record) then fail(record, "OpenCode server is unavailable") end end,
		resolve_model = function(lifecycle, value) return lifecycle.resolve_explanation_model(value) end,
		-- The temporary session runs outside the project so AGENTS.md discovery
		-- does not prepend repository instructions to the explanation prompt.
		generate = function(prompt, model, callback, opts)
			opts.directory = scratch_directory()
			opts.agent = require("opencode.lifecycle").explanation_agent()
			return require("opencode.client").generate_explanation(prompt, model, callback, opts)
		end,
		update = function(record, text)
			if not valid(record) then return end
			local visible = response_text.display(text, display_config, { streaming = true })
			if visible ~= "" and ui.show(visible, { streaming = true }) == false then M.dismiss() end
		end,
		respond = function(record, request_err, response)
			if request_err then
				if request_err.cancelled then M.dismiss() else fail(record, request_err.message or request_err) end
				return
			end
			if type(response) ~= "string" or vim.trim(response) == "" then
				fail(record, "The model returned an empty " .. (follow_up and "answer" or "explanation"))
				return
			end
			local answer = response_text.display(response, display_config)
			record.phase = "ready"
			if follow_up then record.turns[#record.turns].answer = answer else record.turns = { { answer = answer } } end
			if ui.show(answer) == false then M.dismiss() end
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
	snapshot.phase, snapshot.turns, snapshot.generation = "pending", {}, 1
	current = snapshot
	if ui.open(snapshot, function() M.dismiss() end, M.ask) == false then
		M.dismiss()
		notify("Could not open the explanation popup")
		return false
	end
	local collected, context_err = context.collect(snapshot, config)
	if not collected then fail(snapshot, context_err); return true end
	snapshot.context = collected
	request.run(snapshot, config, context.prompt(collected, config), hooks(snapshot, config))
	return ui.is_open()
end

---Ask a follow-up question about the open explanation.
---@return boolean started
function M.ask(question)
	local record = current
	question = type(question) == "string" and vim.trim(question) or ""
	if question == "" then return false end
	if not record or record.phase ~= "ready" or not record.context then
		notify("wait for the explanation before asking")
		return false
	end
	if not ui.is_open() then M.dismiss(); return false end
	local config = request.current_config("explanation", config)
	local model_err = request.validate(config, "explanation")
	if model_err then notify(model_err); return false end
	record.turns[#record.turns + 1] = { question = question }
	record.phase, record.generation = "pending", record.generation + 1
	ui.pending(transcript(record))
	request.run(record, config, context.follow_up(record.context, record.turns, config), hooks(record, config, true))
	return true
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
			if current and current.phase == "pending" and event.buf == current.bufnr and not source_unchanged(current) then
				fail(current, "Source buffer changed")
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.teardown })
	connection_listener = function(value)
		if current and current.phase == "pending" and (value == "error" or value == "idle") then
			fail(current, "OpenCode server disconnected")
		end
	end
	require("opencode.state").on("connection", connection_listener)
end

return M
