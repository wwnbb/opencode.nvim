local M = {}

local actions = require("opencode.actions")
local selectors = require("opencode.selectors")

---@param session table
---@return string
local function stats_label(session)
	local pieces = { session:status_label() }
	local pending = session.pending or {}
	if session:pending_total() > 0 then
		table.insert(
			pieces,
			string.format("wait p%d q%d e%d", pending.permissions or 0, pending.questions or 0, pending.edits or 0)
		)
	end
	local count = session:message_count()
	if count > 0 then
		table.insert(pieces, count .. " msgs")
	end
	return table.concat(pieces, " · ")
end

local function refresh_data(callback)
	actions.refresh_session_activity(callback)
end

function M.show(context)
	local palette = require("opencode.ui.palette")
	context = palette.capture_context(context)
	local pending = require("opencode.session.pending")
	local token = pending.token()
	local function current()
		return pending.is_current(token) and (not context.view or not context.view.session_bound or palette.context_valid(context))
	end
	refresh_data(function()
		if not current() then return end
		local sessions = selectors.get_active_session_views(context)
		local current_view = selectors.get_current_session_view(context)
		local current_id = current_view and current_view.id or nil
		local current_root_session_id = selectors.get_current_runtime_root_id(context)
		if #sessions == 0 then
			vim.notify("No OpenCode sessions found", vim.log.levels.INFO)
			return
		end

		local items = {}
		local function make_label(session)
			local title = session:title() or session.id
			local is_current = session.id == current_id or session.id == current_root_session_id
			local marker = is_current and "● " or "  "
			return marker .. title
		end

		for index, session in ipairs(sessions) do
			local is_current = session.id == current_id or session.id == current_root_session_id
			table.insert(items, {
				label = make_label(session),
				value = session.id,
				session = session,
				description = stats_label(session),
				priority = is_current and 100 or (100 - index),
				sort_index = index,
			})
		end

		local function refresh_labels()
			local selection = context.view and context.view.session_bound and context or nil
			local next_current_view = selectors.get_current_session_view(selection)
			local next_current_id = next_current_view and next_current_view.id or nil
			local next_root_id = selectors.get_current_runtime_root_id(selection)
			current_id = next_current_id
			current_root_session_id = next_root_id
			for index, item in ipairs(items) do
				local session = item.session
				item.label = make_label(session)
				local is_current = session and (session.id == next_current_id or session.id == next_root_id)
				item.priority = is_current and 100 or (100 - (item.sort_index or index))
			end
		end

		local menu = require("opencode.ui.menu")
		menu.open({
			context = context,
			items = items,
			title = " Active Sessions ",
			width = 76,
			searchable = false,
			on_select = function(item)
				if not current() then return end
				actions.switch_session(item.session:to_record(), {
					view = context.view,
					notify = true,
					reason = "active_sessions",
				})
			end,
			keymap_scope = "active_sessions",
			keys = {
				{
					action = "close_session", label = "close tab",
					handler = function(ctx, item)
						if not current() then return end
						local closed = require("opencode.actions").close_session({
							session_id = item.value,
							notify = true,
						})
						if not closed then
							return
						end
						if not current() then ctx.close(); return end
						for i = #items, 1, -1 do
							if items[i].value == item.value then
								table.remove(items, i)
								break
							end
						end
						if #items == 0 then
							ctx.close()
							return
						end
						refresh_labels()
					end,
				},
			},
		})
	end)
end

return M
