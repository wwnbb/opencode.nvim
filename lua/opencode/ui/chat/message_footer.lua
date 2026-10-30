-- opencode.nvim - Assistant message footer and token breakdown
-- attach() installs the footer functions on a per-view render instance; they
-- use that instance's width, wrapping and agent highlights.
local M = {}

local NuiLine = require("nui.line")
local NuiText = require("nui.text")
local locale = require("opencode.util.locale")
local sync = require("opencode.sync")

---@param render table Per-view opencode.ui.chat.render instance
---@param attach_opts { ui_priority: integer }
function M.attach(render, attach_opts)
	local UI_HIGHLIGHT_PRIORITY = attach_opts.ui_priority

	---@param value any
	---@return number|nil
	local function _numeric(value)
		if type(value) ~= "number" then
			return nil
		end
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		return value
	end

	local _format_compact_number = require("opencode.util.locale").compact_number

	local TOKEN_USAGE_FIELDS = { "input", "output", "reasoning" }
	local TOKEN_CACHE_FIELDS = { "read", "write" }

	---@param message table
	---@return number|nil
	local function _get_token_usage(message)
		if type(message) ~= "table" or type(message.tokens) ~= "table" then
			return nil
		end

		local tokens = message.tokens
		local total = _numeric(tokens.total)
		if total then
			return total
		end

		local sum = 0
		local has_value = false
		for _, key in ipairs(TOKEN_USAGE_FIELDS) do
			local value = _numeric(tokens[key])
			if value then
				sum = sum + value
				has_value = true
			end
		end

		if type(tokens.cache) == "table" then
			for _, key in ipairs(TOKEN_CACHE_FIELDS) do
				local value = _numeric(tokens.cache[key])
				if value then
					sum = sum + value
					has_value = true
				end
			end
		end

		if has_value then
			return sum
		end
		return nil
	end

	---@param message table
	---@return table|nil
	local function _get_model(message)
		if type(message) ~= "table" then
			return nil
		end
		if type(message.providerID) ~= "string" or message.providerID == "" then
			return nil
		end
		if type(message.modelID) ~= "string" or message.modelID == "" then
			return nil
		end

		local ok, model = pcall(sync.get_model, message.providerID, message.modelID)
		if ok and type(model) == "table" then
			return model
		end
		return nil
	end

	---@param message table
	---@param model? table
	---@return number|nil
	local function _get_token_limit(message, model)
		if type(message) ~= "table" then
			return nil
		end
		if type(message.providerID) ~= "string" or message.providerID == "" then
			return nil
		end
		if type(message.modelID) ~= "string" or message.modelID == "" then
			return nil
		end
		if type(model) ~= "table" or type(model.limit) ~= "table" then
			return nil
		end

		local context_limit = _numeric(model.limit.context)
		if context_limit then
			return context_limit
		end
		return _numeric(model.limit.input)
	end

	---@param message table
	---@param model? table
	---@return string
	local function _get_model_name(message, model)
		local model_id = type(message) == "table" and message.modelID or nil
		if type(model_id) ~= "string" or model_id == "" then
			return ""
		end
		if type(message.providerID) ~= "string" or message.providerID == "" then
			return model_id
		end
		if type(model) == "table" and type(model.name) == "string" and model.name ~= "" then
			return model.name
		end
		return model_id
	end

	-- ─── Message metadata helpers ─────────────────────────────────────────────────

	---@param message table
	---@return boolean
	function render.is_message_final(message)
		local finish = message.finish
		if not finish then
			return false
		end
		return finish ~= "tool-calls" and finish ~= "unknown"
	end

	---@param message table
	---@param is_last boolean
	---@return boolean
	function render.should_show_footer(message, is_last)
		if
			message
			and message.modelID == nil
			and message.providerID == nil
			and message.agent == nil
			and message.mode == nil
		then
			return false
		end
		if is_last then
			return true
		end
		if render.is_message_final(message) then
			return true
		end
		if message.error and message.error.name == "MessageAbortedError" then
			return true
		end
		return false
	end

	---@param message table
	---@return boolean
	function render.is_interrupted(message)
		return message.error and message.error.name == "MessageAbortedError" or false
	end

	---Calculate duration for an assistant message (completed - parent_user.created).
	---@param message table
	---@param messages table[]
	---@return number|nil duration_ms
	function render.calculate_duration(message, messages)
		if not message.time or not message.time.completed then
			return nil
		end
		local parent_id = message.parentID
		if not parent_id then
			return nil
		end
		for _, msg in ipairs(messages) do
			if msg.id == parent_id and msg.role == "user" then
				if msg.time and msg.time.created then
					return message.time.completed - msg.time.created
				end
				break
			end
		end
		return nil
	end

	-- Cached footers pass verbosity explicitly so that it is part of their key.
	local function verbosity_of(opts)
		if opts and opts.verbosity ~= nil then return opts.verbosity end
		return ((require("opencode.state").read_config() or {}).session or {}).verbosity
	end

	-- Detailed usage gets its own wrapped rows so narrow chat windows can inspect
	-- every field without expanding the normal footer or confusing totals/context.
	---@param opts? { verbosity?: string } Defaults to the configured session verbosity
	function render.render_token_breakdown(message, turn, opts)
		if verbosity_of(opts) ~= "high" then return {} end
		local lines, width = {}, render.get_chat_text_width()
		local prefix = width >= 3 and "  " or ""
		local function add(label, usage)
			if not usage then return end
			local text = string.format("%s · input %s · output %s · reasoning %s · cache read %s · cache write %s", label,
				_format_compact_number(usage.input), _format_compact_number(usage.output), _format_compact_number(usage.reasoning),
				_format_compact_number(usage.cached), _format_compact_number(usage.cache_write))
			for _, row in ipairs(render.wrap_text(text, math.max(1, width - #prefix))) do
				local line = NuiLine(); line:append(NuiText(prefix .. row, "Comment")); lines[#lines + 1] = line
			end
		end
		add("Step", message and require("opencode.selectors").token_usage(message.tokens))
		add(turn and turn.complete and "Turn" or "Turn (known partial)", turn)
		return lines
	end

	---Render metadata footer for an assistant message.
	---@param message table
	---@param messages table[]
	---@param opts? table { spinner_frame?: string|nil, duration_ms?: number|nil, duration_calculated?: boolean, tokens_per_second?: number, verbosity?: string }
	---@return NuiLine
	function render.render_metadata_footer(message, messages, opts)
		opts = opts or {}
		local agent_name = message.mode or message.agent or "unknown"
		local agent_id = message.agent or message.mode or "unknown"
		local interrupted = render.is_interrupted(message)
		local is_final = render.is_message_final(message)
		local agent_hl = interrupted and "Comment" or render.get_agent_hl(agent_id)
		local model = _get_model(message)
		local token_usage = _get_token_usage(message)
		local token_limit = _get_token_limit(message, model)
		local spinner_frame = (type(opts.spinner_frame) == "string" and #opts.spinner_frame > 0) and opts.spinner_frame
			or nil
		local agent_prefix = spinner_frame and (spinner_frame .. " ") or "▣ "

		local line = NuiLine()
		line:append(NuiText(agent_prefix, { hl_group = "Comment", priority = UI_HIGHLIGHT_PRIORITY }))
		line:append(NuiText(locale.titlecase(agent_name), { hl_group = agent_hl, priority = UI_HIGHLIGHT_PRIORITY }))
		local model_name = _get_model_name(message, model)
		if model_name ~= "" then
			line:append(NuiText(" · ", "Comment"))
			line:append(NuiText(model_name, "Comment"))
		end
		if token_usage and token_usage > 0 then
			line:append(NuiText(" · ", "Comment"))
			local token_text = _format_compact_number(token_usage)
			if token_limit then
				token_text = token_text .. "/" .. _format_compact_number(token_limit)
			end
			line:append(NuiText(token_text .. " tok", "Comment"))
		end
		if verbosity_of(opts) == "high" then
			local step = require("opencode.selectors").token_usage(message.tokens)
			if step then
				line:append(NuiText(string.format(" · step %s new + %s cached = %s tok", _format_compact_number(step.new),
					_format_compact_number(step.cached), _format_compact_number(step.total)), "Comment"))
			end
			local turn = opts.turn_usage
			if turn and turn.steps > 0 then
				line:append(NuiText(string.format(" · turn %d steps: %s%s new + %s cached = %s tok", turn.steps,
					turn.complete and "" or "≥", _format_compact_number(turn.new), _format_compact_number(turn.cached),
					_format_compact_number(turn.total)), "Comment"))
			end
		end
		local cost = _numeric(message.cost)
		if cost and cost > 0 then line:append(NuiText(string.format(" · $%.2f", cost), "Comment")) end
		if not interrupted and is_final then
			local duration_ms
			if opts.duration_calculated then
				duration_ms = opts.duration_ms
			else
				duration_ms = render.calculate_duration(message, messages)
			end
			if duration_ms then
				line:append(NuiText(" · ", "Comment"))
				line:append(NuiText(locale.duration(duration_ms), agent_hl))
			end
		end
		local tokens_per_second = _numeric(opts.tokens_per_second)
		if tokens_per_second and tokens_per_second > 0 then
			line:append(NuiText(" · ", "Comment"))
			line:append(NuiText(string.format("%.1f tok/s", tokens_per_second), "Comment"))
		end
		if interrupted then
			line:append(NuiText(" · ", "Comment"))
			line:append(NuiText("interrupted", "Comment"))
		end
		return line
	end
end

return M
