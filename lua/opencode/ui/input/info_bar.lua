-- opencode.nvim - Input info bar

local M = {}

local NS_INFO = vim.api.nvim_create_namespace("opencode_input_info")
local highlights = require("opencode.ui.highlights")
local session_lock = require("opencode.session.lock")

function M.setup_highlights()
	highlights.setup_message_backgrounds()
	vim.api.nvim_set_hl(0, "OpenCodeInputBorder", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputBorderAgent", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputInfo", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputAgent", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputModel", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputProvider", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputVariant", { link = "WarningMsg", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputDot", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputSkill", { link = "Special", default = true })
end

local function titlecase(str)
	if not str or str == "" then
		return str
	end
	return str:sub(1, 1):upper() .. str:sub(2)
end

local function local_state()
	local ok, lc = pcall(require, "opencode.local")
	if not ok then
		return nil
	end
	return lc
end

local function active_session_lock()
	local ok, app_state = pcall(require, "opencode.state")
	if not ok then
		return nil
	end
	local session = app_state.get_session()
	return session_lock.get(session and session.id)
end

local function info_parts()
	local locked = active_session_lock()
	if locked then
		local lc = local_state()
		local model = locked.model or {}
		local model_info = nil
		local provider_info = nil
		local sync_ok, sync = pcall(require, "opencode.sync")
		if sync_ok and type(sync.get_model) == "function" then
			model_info = sync.get_model(model.providerID, model.modelID)
			if type(sync.get_provider) == "function" then
				provider_info = sync.get_provider(model.providerID)
			end
		end
		local agent_name = locked.agent or "Subagent"
		local model_name = model_info and model_info.name or model.modelID or "Unavailable"
		local provider_name = model_info and model_info.provider or provider_info and provider_info.name or model.providerID or ""
		local agent_hl = lc and lc.agent and lc.agent.color and lc.agent.color(agent_name) or "OpenCodeInputAgent"
		return agent_name, model_name, provider_name, locked.variant, agent_hl
	end

	local lc = local_state()
	if not lc then
		return "Code", "", "", nil, "OpenCodeInputAgent"
	end

	local agent = lc.agent.current()
	local agent_name = agent and agent.name or "Code"
	local model = lc.model.parsed()
	local model_name = model and model.name or ""
	local provider_name = model and model.provider or ""
	local variant = lc.variant.current()
	local agent_hl = lc.agent.color(agent and (agent.id or agent.name) or agent_name)

	return agent_name, model_name, provider_name, variant, agent_hl
end

local function mark(bufnr, col, text, hl_group)
	if text == "" then
		return col
	end

	vim.api.nvim_buf_set_extmark(bufnr, NS_INFO, 0, col, {
		end_col = col + #text,
		hl_group = hl_group,
	})
	return col + #text
end

local function clip(text, width)
	return require("opencode.util.text").truncate(text:gsub("[%c]", " "), width, "…")
end

local function skill_names(state)
	local names, seen = {}, {}
	local text
	local function marker_present(marker)
		if not state.marker_range then return false end
		if text == nil then
			-- Markers may occur anywhere in the draft; share one complete read.
			text = state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)
				and table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n") or ""
		end
		return state.marker_range(text, marker)
	end
	local by_id
	for _, part in ipairs(state.parts or {}) do
		local id = part.skillID or part.id
		if part.type == "skill" and type(id) == "string" and not seen[id]
			and (not part._marker or marker_present(part._marker)) then
			if not by_id then
				local ok, sync = pcall(require, "opencode.sync")
				local catalog = ok and sync.get_skills() or {}
				by_id = {}
				for _, skill in pairs(type(catalog) == "table" and catalog or {}) do
					if type(skill) == "table" and type(skill.id) == "string" then by_id[skill.id] = skill.name end
			end
			end
			local name = by_id[id] or part.name or id
			names[#names + 1] = type(name) == "string" and name or id
			seen[id] = true
		end
	end
	return names
end

local function usage_part(state, room)
	if state.mode == "shell" then return "" end
	local selectors = require("opencode.selectors")
	local usage = selectors.current_context(state.session_id)
	local cost, complete = selectors.session_cost(state.session_id)
	local function number(value)
		if value >= 1000000 then return string.format("%.1fM", value / 1000000) end
		if value >= 1000 then return string.format("%.1fK", value / 1000) end
		return tostring(value)
	end
	local context = usage and "ctx " .. number(usage.tokens) or ""
	local full = context .. (usage and usage.percent and " (" .. usage.percent .. "%)" or "")
	local money = cost and cost > 0 and (complete and "" or "≥") .. string.format("$%.2f", cost) or ""
	local both = full .. (full ~= "" and money ~= "" and " · " or "") .. money
	for _, value in ipairs({ both, full, context, money }) do
		if value ~= "" and vim.fn.strdisplaywidth(" · " .. value) <= room then return " · " .. value end
	end
	return ""
end

function M.update(state)
	if not state.visible then
		return
	end

	local bufnr = state.info_bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if state.history_search then
		local keys = require("opencode.util.keymap")
		local text = "History · type to search · " .. keys.label("input", "command_enter") .. "/"
			.. keys.label("input", "autocomplete_confirm") .. ":insert · Esc:cancel"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { clip(text, state.layout.content_width) })
		vim.api.nvim_buf_clear_namespace(bufnr, NS_INFO, 0, -1)
		mark(bufnr, 0, clip(text, state.layout.content_width), "OpenCodeInputInfo")
		return
	end

	local agent, model, provider, variant, agent_hl = info_parts()
	if state.mode == "shell" then
		local keymaps = require("opencode.util.keymap")
		local toggle = keymaps.label("input", "toggle_mode")
		if toggle == "(disabled)" then toggle = "/shell" end
		agent, model, provider, variant = "shell", toggle .. ": return to chat", "", nil
	end
	vim.api.nvim_set_hl(0, "OpenCodeInputBorderAgent", { link = agent_hl, default = false })

	local agent_part = titlecase(agent) .. " "
	local model_part = model ~= "" and model or ""
	local provider_part = provider ~= "" and (" " .. provider) or ""
	local dot_part = variant and variant ~= "" and " \194\183 " or ""
	local variant_part = variant and variant ~= "" and variant or ""
	local skill_part = ""
	local editor_status = require("opencode.editor_context").status((require("opencode.state").get_session() or {}).id, state.editor_context)
	local info_win = state.info_popup and state.info_popup.winid
	local width = info_win and vim.api.nvim_win_is_valid(info_win) and vim.api.nvim_win_get_width(info_win)
		or (state.layout and state.layout.content_width) or vim.o.columns
	local names = skill_names(state)
	if #names > 0 then
		local summary = " · " .. (#names == 1 and "Skill: " or "Skills: ") .. table.concat(names, ", ")
		local core_width = vim.fn.strdisplaywidth(agent_part .. model_part)
		local optional_width = vim.fn.strdisplaywidth(provider_part .. dot_part .. variant_part)
		local room = width - core_width - optional_width
		if room < math.min(vim.fn.strdisplaywidth(summary), 16) then
			provider_part, dot_part, variant_part = "", "", ""
			room = width - core_width
		end
		if room < 12 then
			local reserve = math.min(12, math.max(1, math.floor(width / 2)))
			local agent_width = math.min(vim.fn.strdisplaywidth(agent_part), math.max(1, math.floor((width - reserve) / 3)))
			agent_part = clip(vim.trim(agent_part), math.max(0, agent_width - 1)) .. " "
			model_part = clip(model_part, math.max(0, width - reserve - vim.fn.strdisplaywidth(agent_part)))
			room = width - vim.fn.strdisplaywidth(agent_part .. model_part)
		end
		if room < 16 then summary = " · Skills: " .. #names end
		skill_part = clip(summary, room)
	end
	local usage = usage_part(state, width - vim.fn.strdisplaywidth(agent_part .. model_part .. provider_part .. dot_part .. variant_part .. skill_part))
	local editor_part = ""
	if editor_status and state.mode ~= "shell" then
		editor_part = clip(" · Context: " .. editor_status, math.max(0, width - vim.fn.strdisplaywidth(agent_part .. model_part .. provider_part .. dot_part .. variant_part .. skill_part .. usage)))
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		agent_part .. model_part .. provider_part .. dot_part .. variant_part .. skill_part .. usage .. editor_part,
	})
	vim.api.nvim_buf_clear_namespace(bufnr, NS_INFO, 0, -1)

	local col = 0
	col = mark(bufnr, col, agent_part, agent_hl)
	col = mark(bufnr, col, model_part, "OpenCodeInputModel")
	col = mark(bufnr, col, provider_part, "OpenCodeInputProvider")
	col = mark(bufnr, col, dot_part, "OpenCodeInputDot")
	col = mark(bufnr, col, variant_part, "OpenCodeInputVariant")
	col = mark(bufnr, col, skill_part, "OpenCodeInputSkill")
	col = mark(bufnr, col, usage, "OpenCodeInputInfo")
	mark(bufnr, col, editor_part, "OpenCodeInputInfo")
end

function M.cycle_variant(state)
	if active_session_lock() then
		return
	end
	local lc = local_state()
	if lc then
		lc.variant.cycle()
		M.update(state)
	end
end

function M.cycle_agent(state)
	if active_session_lock() then
		return
	end
	local lc = local_state()
	if lc then
		lc.agent.move(1)
		M.update(state)
	end
end

function M.cycle_model(state)
	if active_session_lock() then
		return
	end
	local lc = local_state()
	if lc then
		lc.model.cycle(1)
		M.update(state)
	end
end

return M
