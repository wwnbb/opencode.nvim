local M = {}
local actions, state, selectors = require("opencode.actions"), require("opencode.state"), require("opencode.selectors")
local palette_context = require("opencode.ui.palette.context")

local function failed(action, err)
	vim.notify("Could not " .. action .. " queued prompt: " .. tostring(type(err) == "table" and err.message or err),
		vim.log.levels.WARN)
end

-- The TUI's queued prompts dialog: Enter steers the selected prompt, delete
-- removes it and undo restores it into the input. The list follows the queue.
function M.show(context)
	context = palette_context.capture(context)
	local id = context.session_id
	if not id then vim.notify("Open a session first", vim.log.levels.INFO); return end
	local current = palette_context.guard(context, { session_token = id, require_view = true })
	local function items()
		local queued = selectors.queued_prompts(id)
		local result = {}
		for index, prompt in ipairs(queued) do
			result[index] = { label = (prompt.text:gsub("%c", " ")), value = prompt.id, description = index .. " of " .. #queued }
		end
		return result
	end
	local list = items()
	if #list == 0 then vim.notify("No queued prompts", vim.log.levels.INFO); return end
	local events, menu = require("opencode.events"), nil
	local function refresh()
		local next_items = items()
		if not menu or vim.deep_equal(next_items, list) then return end
		list = next_items
		if #list == 0 then menu.close() else menu.set_items(list, { preserve_selection = true }) end
	end
	menu = require("opencode.ui.menu").open({ context = context, title = " Queued prompts ", items = list, width = 80,
		searchable = true, sort = false, close_on_select = false, confirm_label = "steer", keymap_scope = "queue_menu",
		on_select = function(item, ctx)
			if not current() then ctx.close(); return end
			actions.steer_pending_input(id, item.value, function(err)
				if err then failed("steer", err) else ctx.close() end
			end)
		end,
		on_close = function() events.off("sync_changed", refresh) end,
		keys = palette_context.guard_keys({
			{ action = "delete", label = "delete", insert = true, handler = function(_, item)
				actions.cancel_pending_input(id, item.value, function(err)
					if err then failed("delete", err) else refresh() end
				end)
			end },
			{ action = "undo", label = "undo", insert = true, handler = function(ctx, item)
				-- Check before cancelling: the prompt must not be lost when it cannot join the draft.
				local ok, err = require("opencode.ui.input").can_merge_draft({ mode = "normal" })
				if not ok then vim.notify(err, vim.log.levels.WARN); return end
				actions.edit_pending_input(id, item.value, function(edit_err, draft)
					if edit_err then failed("undo", edit_err); return end
					ctx.close()
					if not draft then return end
					if not current() then require("opencode.ui.input.history").defer_pending(draft, id); return end
					local views = require("opencode.ui.chat.state")
					views.module(context.view, require("opencode.ui.chat.pending_inputs")).restore_draft(draft, id)
				end)
			end },
		}, current) })
	if menu then events.on("sync_changed", refresh) end
end

function M.register(palette)
	palette.register({ id = "prompt.queue", title = "View Queued Prompts", description = "Steer, delete or restore queued prompts",
		category = "prompt", slash = { name = "queued" }, run = M.show, on_select = function(ctx) return ctx.run() end,
		enabled = function()
			local id = state.get_session().id
			return id ~= nil and #selectors.queued_prompts(id) > 0
		end })
end
return M
