-- Shared controller for one temporary feature generation (completion,
-- explanation): runtime config, deadline, connection, model resolution,
-- catalog warm-up retry and remaining budget. Features keep their own
-- validity checks, failure messages and display updates through hooks.
local M = {}
local profile = require("opencode.completion.profile")

-- A cold server may reject a configured model until its catalog is loaded.
local WARMUP_MS = 2000

function M.stop_timer(record, key)
	if record and record[key] then
		record[key]:stop()
		record[key]:close()
		record[key] = nil
	end
end

---Feature settings read at call time; settings.apply replaces them at runtime.
---@param kind "completion"|"explanation"
---@param fallback table Setup-time feature configuration
function M.current_config(kind, fallback)
	local global = require("opencode.state").get_config() or {}
	return global[kind] or fallback
end

---Validate the feature model before any request state exists.
---@return string|nil error
function M.validate(config, kind)
	local managed = require("opencode.lifecycle").owns_server()
	local _, err = profile.validate(config, { managed = managed }, kind)
	return err
end

---Run one request for `record` (a feature snapshot) with `prompt`.
---Hooks:
---  current(record) -> boolean        record is still the feature's live request
---  valid(record) -> boolean          still usable; on false it has already cleaned up
---  in_flight(record) -> boolean      a returned transport handle should be kept
---  fail(record, message)             report a failure and discard the request
---  unavailable(record)               the server refused to start or connect
---  resolve_model(lifecycle, config) -> model|nil, err
---  generate(prompt, model, callback, opts) -> handle
---  update(record, text)              streamed partial response
---  respond(record, err, response)    final response after warm-up retries
function M.run(record, config, prompt, hooks)
	record.started = vim.uv.now()
	if config.timeout_ms > 0 then
		record.deadline = vim.uv.new_timer()
		record.deadline:start(config.timeout_ms, 0, vim.schedule_wrap(function()
			if hooks.current(record) and record.deadline then hooks.fail(record, "Request timed out") end
		end))
	end
	local lifecycle = require("opencode.lifecycle")
	lifecycle.ensure_connected(function()
		if not hooks.valid(record) then return end
		local model, err = hooks.resolve_model(lifecycle, config)
		if not model then hooks.fail(record, err); return end
		local warming_until, attempt = vim.uv.now() + WARMUP_MS, 0
		local function dispatch()
			if not hooks.valid(record) then return end
			local remaining = config.timeout_ms > 0 and config.timeout_ms - (vim.uv.now() - record.started) or 0
			if config.timeout_ms > 0 and remaining <= 0 then hooks.fail(record, "Request timed out"); return end
			attempt = attempt + 1
			local handle = hooks.generate(prompt, model, function(request_err, response)
				if not hooks.valid(record) then return end
				record.handle = nil
				local warming_left = warming_until - vim.uv.now()
				-- Retry only explicit catalog rejections before generation starts.
				if profile.catalog_starting(request_err, model) and warming_left > 0 then
					local delay = math.min(warming_left, 100 * 2 ^ math.min(attempt - 1, 2))
					record.retry_timer = vim.uv.new_timer()
					record.retry_timer:start(delay, 0, vim.schedule_wrap(function()
						M.stop_timer(record, "retry_timer")
						dispatch()
					end))
					return
				end
				M.stop_timer(record, "deadline")
				hooks.respond(record, request_err, response)
			end, {
				timeout = remaining, directory = record.root,
				on_update = function(text) hooks.update(record, text) end,
			})
			if hooks.in_flight(record) then record.handle = handle end
		end
		dispatch()
	end)
	local connection = require("opencode.state").get_connection()
	if hooks.current(record) and (connection == "error" or connection == "idle") then hooks.unavailable(record) end
end

return M
