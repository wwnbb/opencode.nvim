local M = {}
local actions, state, pending = require("opencode.actions"), require("opencode.state"), require("opencode.session.pending")
function M.show(context)
	context = require("opencode.ui.palette").capture_context(context)
	local id = context.session_id
	if not id then vim.notify("Open a session first", vim.log.levels.INFO); return end
	local token = pending.token(id)
	local function current() return pending.is_current(token) and require("opencode.ui.palette").context_valid(context) end
	actions.list_pending_inputs(id, function(err, inputs)
		if not current() then return end
		if err then vim.notify("Could not load queued inputs: " .. tostring(err.message or err), vim.log.levels.WARN); return end
		local items = {}
		for _, item in ipairs(inputs) do
			local record = pending.get(id, item.id)
			if record and (record.status == "queued" or record.status == "accepted") then
				items[#items + 1] = { label = tostring((item.payload or {}).text or item.type):gsub("[%c]", " "), value = item.id,
					description = record.status == "queued" and "Queued" or "Steering", kind = item.type }
			end
		end
		if #items == 0 then vim.notify("No queued inputs", vim.log.levels.INFO); return end
		local function mutate(action, ctx, item)
			if not current() then return end
			ctx.close()
			actions[action .. "_pending_input"](id, item.value, function(failure, draft)
				if failure then vim.notify("Could not " .. action .. " input: " .. tostring(failure.message or failure), vim.log.levels.WARN); return end
				if draft then
					if not current() then require("opencode.ui.input.history").defer_pending(draft, id); return end
					local views = require("opencode.ui.chat.state")
					views.module(context.view, require("opencode.ui.chat.pending_inputs")).restore_draft(draft, id)
				elseif current() then M.show(context) end
			end)
		end
		require("opencode.ui.menu").open({ context = context, title = " Queued Inputs ", items = items, width = 80, sort = false,
			close_on_select = false, on_select = function(item, ctx) if item.kind == "user" then mutate("edit", ctx, item) end end,
			keymap_scope = "queue_menu",
			keys = {
				{ action = "edit", label = "restore draft", handler = function(ctx, item) if item.kind == "user" then mutate("edit", ctx, item) end end },
				{ action = "cancel", label = "cancel", handler = function(ctx, item) mutate("cancel", ctx, item) end },
				{ action = "steer", label = "steer", handler = function(ctx, item) mutate("steer", ctx, item) end },
				{ action = "queue", label = "queue", handler = function(ctx, item) mutate("queue", ctx, item) end },
			} })
	end)
end
function M.register(palette)
	palette.register({ id = "prompt.queue", title = "Queued Inputs", description = "Inspect, restore, promote or cancel pending inputs", category = "prompt",
		slash = { name = "queued" }, run = M.show, on_select = function(ctx) return ctx.run() end,
		enabled = function() return state.get_session().id ~= nil end })
end
return M
