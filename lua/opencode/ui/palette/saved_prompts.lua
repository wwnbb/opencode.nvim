local M = {}
local actions, input = require("opencode.actions"), require("opencode.ui.input")
local palette_context = require("opencode.ui.palette.context")
local capture = palette_context.capture
-- Saved prompts edit the focused composer: require the captured, focused session.
local function guard(context, opts)
	return palette_context.guard(context, vim.tbl_extend("force", { require_view = true, global_session = true }, opts or {}))
end
local function current(context) return guard(context)() end
local function report(err) if err then vim.notify(err, vim.log.levels.WARN) end end

--- Save the current draft to the library; the draft stays in the composer.
function M.save(context)
	context = capture(context)
	if not current(context) then return end
	local value, err = actions.save_prompt({ text = input.get_pending_text(), parts = input.get_pending_parts(), mode = input.get_mode(),
		options = input.get_pending_options() })
	if not value then report(err); return end
	vim.notify("Prompt saved", vim.log.levels.INFO)
	return value
end

--- Insert a saved prompt (the newest when id is nil) into the draft and keep it in the library.
function M.insert(id, context)
	context = capture(context)
	if not current(context) then return end
	local draft, err = actions.get_saved_prompt(id)
	if not draft then report(err); return end
	local ok, failure = input.merge_pending_draft(draft)
	if not ok then report(failure); return end
	return true
end

local function items()
	local result = {}
	for _, prompt in ipairs(actions.list_saved_prompts()) do
		local ok, date = pcall(os.date, "%Y-%m-%d %H:%M", prompt.created or 0)
		result[#result + 1] = { id = prompt.id, label = prompt.text ~= "" and prompt.text:gsub("[%c]", " ") or "Attachments",
			description = (ok and date or "Unknown date") .. " · " .. #prompt.parts .. " parts · " .. prompt.mode }
	end
	return result
end

function M.show(context)
	context = capture(context)
	if not current(context) then return end
	local list = items()
	if #list == 0 then vim.notify("No saved prompts", vim.log.levels.INFO); return end
	local scope, token = require("opencode.util.cwd").get(), input.draft_token()
	local selected = guard(context, { session_token = context.session_id, same_directory = true,
		check = function() return require("opencode.util.cwd").get() == scope and input.draft_token() == token end })
	return require("opencode.ui.menu").open({ context = context, title = " Saved Prompts ", items = list, width = 80,
		searchable = true, sort = false, confirm_label = "insert", keymap_scope = "saved_prompts_menu",
		on_select = function(item)
			-- Let the composer's pending BufLeave save finish before inserting into the draft.
			vim.schedule(function()
				if selected() and M.insert(item.id, context) then actions.focus_input() end
			end)
		end,
		keys = palette_context.guard_keys({
			{ action = "delete", label = "delete", insert = true, handler = function(ctx, item)
				local _, err = actions.delete_saved_prompt(item.id)
				if err then report(err); return end
				local next_items = items()
				if #next_items == 0 then ctx.close() else ctx.set_items(next_items, { preserve_selection = true }) end
			end },
		}, selected),
	})
end

function M.register(palette)
	palette.register({ id = "prompt.saved.save", title = "Save Current Prompt", category = "prompt",
		description = "Add the current draft to the saved prompts library", run = M.save })
	palette.register({ id = "prompt.saved", title = "Saved Prompts", category = "prompt", slash = { name = "prompts" },
		description = "Insert a saved prompt into the current draft", on_select = function(ctx) return ctx.run() end, run = M.show })
end

return M
