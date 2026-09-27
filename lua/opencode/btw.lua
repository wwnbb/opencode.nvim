-- Transient side questions. They use the session context without recording a turn.
local M = {}

local INSTRUCTION = "The user is asking a quick side question about the conversation so far. "
	.. "Answer directly and concisely in markdown from what you already know. "
	.. "Do not call any tools and do not take any actions."

local pending = {}
local generation = 0
local session_epochs = {}
local timer
local SPINNER_INTERVAL_MS = 80

local function refresh_indicator()
	local chat = package.loaded["opencode.ui.chat"]
	if chat and type(chat.update_winbar) == "function" then
		chat.update_winbar()
	end
end

local function total_pending()
	local count = 0
	for _, value in pairs(pending) do count = count + value end
	return count
end

local function stop_timer()
	if not timer then return end
	timer:stop()
	timer:close()
	timer = nil
end

local function update_animation()
	if total_pending() == 0 then
		stop_timer()
	elseif not timer then
		timer = vim.uv.new_timer()
		timer:start(SPINNER_INTERVAL_MS, SPINNER_INTERVAL_MS, vim.schedule_wrap(function()
			if total_pending() > 0 then refresh_indicator() end
		end))
	end
	refresh_indicator()
end

function M.pending_count(session_id)
	return session_id and (pending[session_id] or 0) or total_pending()
end

function M.ask(session_id, question)
	question = vim.trim(question or "")
	if type(session_id) ~= "string" or session_id == "" then
		vim.notify("No active session for /btw", vim.log.levels.WARN)
		return false
	end
	if question == "" then
		vim.notify("Usage: /btw <question>", vim.log.levels.WARN)
		return false
	end

	local request_generation = generation
	local request_epoch = session_epochs[session_id] or 0
	local function is_current()
		return request_generation == generation and request_epoch == (session_epochs[session_id] or 0)
	end
	pending[session_id] = (pending[session_id] or 0) + 1
	update_animation()
	local function complete(err, answer)
		if not is_current() then return end
		pending[session_id] = math.max(0, (pending[session_id] or 1) - 1)
		if pending[session_id] == 0 then pending[session_id] = nil end
		update_animation()
		if err then
			vim.notify("/btw failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
			return
		end
		require("opencode.ui.btw").show(question, vim.trim(answer))
	end
	local client = require("opencode.client")
	local function generate()
		if not is_current() then return end
		client.generate_text(session_id, INSTRUCTION .. "\n\n" .. question, complete)
	end
	local selection = require("opencode.session.selection")
	local chosen = selection.pending_values(session_id)
	if not chosen then
		generate()
		return true
	end
	-- Local model and agent choices normally reach the server on prompt
	-- admission. Prepare them first so /btw uses the model shown in the UI.
	local session_pending = require("opencode.session.pending")
	local token = session_pending.token(session_id)
	session_pending.serialize(session_id, function(done)
		client.get_session(session_id, function(err, info)
			if not is_current() then done(); return end
			if err then complete(err); done(); return end
			local fallback = require("opencode.selectors").send_selection({ session_id = session_id })
			local desired_agent = chosen.agent and chosen.agent ~= vim.NIL and chosen.agent or info.agent or fallback.agent
			local desired_model = chosen.model and chosen.model ~= vim.NIL and chosen.model or info.model or fallback.model
			local variant = chosen.variant
			if variant == vim.NIL then variant = "default" end
			if not desired_model and chosen.agent and desired_agent then
				client.switch_agent(session_id, desired_agent, function(agent_err)
					if agent_err then complete(agent_err) else generate() end
					done()
				end)
				return
			end
			local model, model_err = require("opencode.protocol.v2.requests").model(desired_model, variant)
			if not model then
				complete({ message = model_err }); done(); return
			end
			selection.prepare(session_id, { agent = desired_agent, model = model }, token, function(prepare_err)
				if prepare_err then complete(prepare_err) else generate() end
				done()
			end, info)
		end)
	end)
	return true
end

function M.clear_session(session_id)
	if type(session_id) ~= "string" or session_id == "" then return end
	session_epochs[session_id] = (session_epochs[session_id] or 0) + 1
	pending[session_id] = nil
	update_animation()
end

function M.reset()
	generation = generation + 1
	pending = {}
	session_epochs = {}
	stop_timer()
	local view = package.loaded["opencode.ui.btw"]
	if view and type(view.close) == "function" then view.close() end
	refresh_indicator()
end

return M
