-- opencode.nvim - Input info bar

local M = {}

local NS_INFO = vim.api.nvim_create_namespace("opencode_input_info")
local highlights = require("opencode.ui.highlights")

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

local function info_parts()
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
	local agent_hl = lc.agent.color(agent_name)

	return agent_name, model_name, provider_name, variant, agent_hl
end

local function update_border_color(agent_name)
	local lc = local_state()
	if not lc then
		return
	end

	vim.api.nvim_set_hl(0, "OpenCodeInputBorderAgent", {
		link = lc.agent.color(agent_name),
		default = false,
	})
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

function M.update(state)
	if not state.visible then
		return
	end

	local bufnr = state.info_bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local agent, model, provider, variant, agent_hl = info_parts()
	update_border_color(agent)

	local agent_part = titlecase(agent) .. " "
	local model_part = model ~= "" and model or ""
	local provider_part = provider ~= "" and (" " .. provider) or ""
	local dot_part = variant and variant ~= "" and " \194\183 " or ""
	local variant_part = variant and variant ~= "" and variant or ""

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		agent_part .. model_part .. provider_part .. dot_part .. variant_part,
	})
	vim.api.nvim_buf_clear_namespace(bufnr, NS_INFO, 0, -1)

	local col = 0
	col = mark(bufnr, col, agent_part, agent_hl)
	col = mark(bufnr, col, model_part, "OpenCodeInputModel")
	col = mark(bufnr, col, provider_part, "OpenCodeInputProvider")
	col = mark(bufnr, col, dot_part, "OpenCodeInputDot")
	mark(bufnr, col, variant_part, "OpenCodeInputVariant")
end

function M.cycle_variant(state)
	local lc = local_state()
	if lc then
		lc.variant.cycle()
		M.update(state)
	end
end

function M.cycle_agent(state)
	local lc = local_state()
	if lc then
		lc.agent.move(1)
		M.update(state)
	end
end

function M.cycle_model(state)
	local lc = local_state()
	if lc then
		lc.model.cycle(1)
		M.update(state)
	end
end

return M
