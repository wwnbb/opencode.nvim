local M = {}
local actions, input = require("opencode.actions"), require("opencode.ui.input")
local function capture(context) return require("opencode.ui.palette").capture_context(context) end
local function current(context)
	return require("opencode.state").get_session().id == context.session_id
		and require("opencode.ui.palette").context_valid(context)
end
local function report(err) if err then vim.notify(err, vim.log.levels.WARN) end end
function M.push(context)
	context = capture(context)
	if not current(context) then return end
	local value, err = actions.stash_prompt({ text = input.get_pending_text(), parts = input.get_pending_parts(), mode = input.get_mode(),
		options = input.get_pending_options() })
	if not value then report(err); return end
	input.set_pending_draft("", {}); input.set_mode("normal")
	vim.notify("Prompt stashed", vim.log.levels.INFO)
end
function M.pop(id, context)
	context = capture(context)
	if not current(context) then return end
	local candidate
	for _, draft in ipairs(actions.list_stashed_prompts()) do if not id or draft.id == id then candidate = draft; break end end
	if candidate then
		local ok, failure = input.can_merge_draft(candidate)
		if not ok then report(failure); return end
	end
	local draft, err = actions.take_stashed_prompt(id)
	if not draft then report(err); return end
	input.merge_pending_draft(draft)
	vim.notify("Stashed prompt restored", vim.log.levels.INFO)
end
function M.show(context)
	context = capture(context)
	if not current(context) then return end
	local items = actions.list_stashed_prompts()
	if #items == 0 then vim.notify("Prompt stash is empty", vim.log.levels.INFO); return end
	local scope, token = vim.fn.getcwd(), input.draft_token()
	local state, pending = require("opencode.state"), require("opencode.session.pending")
	local sid = context.session_id
	local directory = state.get_session_directory(sid)
	local request_token = pending.token(sid)
	for _, item in ipairs(items) do
		item.label = item.text ~= "" and item.text:gsub("[%c]", " ") or "Attachments"
		local ok, date = pcall(os.date, "%Y-%m-%d %H:%M", item.created or 0)
		item.description = (ok and date or "Unknown date") .. " · " .. #item.parts .. " parts · " .. item.mode
	end
	require("opencode.ui.menu").open({ context = context, title = " Stashed Prompts ", items = items, width = 80, sort = false,
		on_select = function(item)
			if vim.fn.getcwd() == scope and input.draft_token() == token and current(context)
				and state.get_session_directory(sid) == directory and pending.is_current(request_token) then M.pop(item.id, context) end
		end })
end
function M.register(palette)
	palette.register({ id = "prompt.stash.push", title = "Stash Current Prompt", category = "prompt", run = M.push })
	palette.register({ id = "prompt.stash.pop", title = "Restore Latest Stashed Prompt", category = "prompt", run = function(context) M.pop(nil, context) end })
	palette.register({ id = "prompt.stash", title = "Stashed Prompts", category = "prompt", slash = { name = "stash" },
		on_select = function(ctx) return ctx.run() end, run = M.show })
end
return M
