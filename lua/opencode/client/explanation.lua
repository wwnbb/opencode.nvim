-- Temporary native sessions reuse chat streaming without entering chat state.
local M = {}
local PREFIX = "ses_opencode_nvim_explanation_"
local pending = {}

function M.is_session(id)
	return type(id) == "string" and id:sub(1, #PREFIX) == PREFIX
end

function M.cancel_all()
	for request in pairs(pending) do request.cancel() end
end

function M.generate(prompt, model, callback, opts, endpoint_config)
	local api = require("opencode.client.api")
	local sse = require("opencode.client.sse")
	local schedule = require("opencode.util.schedule").schedule_callback
	local endpoint = endpoint_config()
	local title = opts.title or "Explanation"
	local bytes, random_err = (vim.uv or vim.loop).random(16)
	if not bytes then schedule(callback, { message = "Could not create " .. title:lower() .. " ID: " .. tostring(random_err) }); return end
	local id = PREFIX .. bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end)
	local done, creating, prompt_request = false, true, nil
	local blocks, order, characters = {}, {}, 0
	local request = {}
	local event, disconnected
	local function same_endpoint() return endpoint_config().generation == endpoint.generation end
	local function cleanup()
		if creating then return end
		if not same_endpoint() then
			vim.notify("OpenCode " .. title:lower() .. ": server changed before temporary session cleanup (" .. id .. ")", vim.log.levels.WARN)
			return
		end
		-- Deletion also interrupts execution and waits until it is idle.
		api.request("session_delete", { path = { sessionID = id } }, function(err)
			if err and err.status ~= 404 then
				vim.notify("OpenCode " .. title:lower() .. ": could not remove temporary session " .. id .. ": "
					.. tostring(err.message or err), vim.log.levels.WARN)
			end
		end)
	end
	local function finish(err, text)
		if done then return end
		done = true
		pending[request] = nil
		sse.off("*", event)
		sse.off("disconnected", disconnected)
		sse.off("error", disconnected)
		if prompt_request then prompt_request.cancel(); prompt_request = nil end
		cleanup()
		schedule(callback, err, text)
	end
	function request.cancel()
		if done then return false end
		finish({ code = "cancelled", cancelled = true, retryable = false, message = "Request cancelled" })
		return true
	end
	function request.is_active() return not done end
	local function text()
		local result = {}
		for _, key in ipairs(order) do result[#result + 1] = blocks[key].text end
		return table.concat(result, "\n\n")
	end
	disconnected = function(message)
		finish({ code = "disconnected", message = tostring(message or "OpenCode event stream disconnected"), retryable = false })
	end
	event = function(kind, data)
		if done then return end
		if not same_endpoint() then finish({ code = "stale_connection", message = "Server connection changed" }); return end
		if type(data) ~= "table" or data.sessionID ~= id then return end
		local reasoning = kind == "session.reasoning.delta" or kind == "session.reasoning.ended"
		if kind == "session.text.delta" or kind == "session.text.ended" or reasoning then
			if type(data.assistantMessageID) ~= "string" or type(data.ordinal) ~= "number" then return end
			local ended = kind == "session.text.ended" or kind == "session.reasoning.ended"
			local value = data[ended and "text" or "delta"]
			if type(value) ~= "string" then return end
			local key = (reasoning and "reasoning:" or "text:") .. data.assistantMessageID .. ":" .. data.ordinal
			if not blocks[key] then
				blocks[key] = { text = "", characters = 0 }
				if not reasoning then order[#order + 1] = key end
			end
			local block = blocks[key]
			if block.ended and not ended then return end
			characters = characters - block.characters
			if not reasoning then block.text = ended and value or block.text .. value end
			block.characters = (ended and 0 or block.characters) + vim.fn.strchars(value)
			block.ended = ended
			characters = characters + block.characters
			if not reasoning and type(opts.on_update) == "function" then opts.on_update(text()) end
			if not done and type(opts.on_progress) == "function" then
				-- shortcut: live usage is unavailable; replace the character estimate when the API exposes it.
				opts.on_progress(math.ceil(characters / 4))
			end
		elseif kind == "session.execution.succeeded" then finish(nil, text())
		elseif kind == "session.execution.failed" then
			finish({ code = "generation_failed", message = type(data.error) == "table" and data.error.message or title .. " failed" })
		elseif kind == "session.execution.interrupted" or kind == "session.deleted" then
			finish({ code = "interrupted", message = title .. " interrupted" })
		elseif kind == "form.asked" or kind == "permission.asked" then
			finish({ code = "interaction_required", message = "The " .. title:lower() .. " model requested an interaction" })
		end
	end
	if not sse.is_connected() then
		schedule(callback, { code = "disconnected", message = "OpenCode event stream is not connected" })
		return
	end
	pending[request] = true
	sse.on("*", event)
	sse.on("disconnected", disconnected)
	sse.on("error", disconnected)
	-- Keep creation alive when cancelled: its late reply must trigger deletion.
	api.request("session_create", { body = {
		id = id, title = title, model = model, location = { directory = opts.directory or vim.fn.getcwd() },
		permissions = { { action = "*", resource = "*", effect = "deny" } },
	}, timeout = opts.timeout }, function(err, session)
		creating = false
		if done then cleanup(); return end
		if err then finish(err); return end
		if not same_endpoint() then finish({ code = "stale_connection", message = "Server connection changed" }); return end
		if not session or session.id ~= id then finish({ code = "incompatible_response", message = "Unexpected " .. title:lower() .. " session" }); return end
		local handle = api.request("prompt", { path = { sessionID = id }, body = { text = prompt }, timeout = opts.timeout }, function(prompt_err)
			prompt_request = nil
			if prompt_err then finish(prompt_err) end
		end)
		if not done then prompt_request = handle end
	end)
	return request
end

return M
