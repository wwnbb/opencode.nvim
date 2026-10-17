local M = {}

function M.show(context)
	local state = require("opencode.state")
	context = require("opencode.ui.palette").capture_context(context)
	if state.get_session().id ~= context.session_id or not require("opencode.ui.palette").context_valid(context) then return end
	local cfg = (state.get_config() or {}).input or {}
	local search = require("opencode.ui.history_search").new(cfg)
	if not search then return end

	local input = require("opencode.ui.input")
	local pending = require("opencode.session.pending")
	local sid, scope, draft_token = context.session_id, vim.fn.getcwd(), input.draft_token()
	local directory = state.get_session_directory(sid)
	local request_token = pending.token(sid)
	return require("opencode.ui.menu").open({
		context = context,
		title = " Prompt History ", items = search.items, width = 80, searchable = true, sort = false,
		search_placeholder = "Search prompt text", filter = function() return true end,
		on_search = function(query, ctx) search.search(query, ctx.set_items) end,
		on_close = search.close,
		on_select = function(item)
			-- Let the composer's pending BufLeave save finish before restoring the draft.
			vim.schedule(function()
				if vim.fn.getcwd() ~= scope or state.get_session().id ~= sid or input.draft_token() ~= draft_token
					or state.get_session_directory(sid) ~= directory or not require("opencode.ui.palette").context_valid(context)
					or not pending.is_current(request_token) then return end
				local ok, err = input.merge_pending_draft(item.entry)
				if not ok then vim.notify(err, vim.log.levels.WARN); return end
				require("opencode.actions").focus_input()
			end)
		end,
	})
end

function M.register(palette)
	palette.register({ id = "prompt.history", title = "Search Prompt History", category = "prompt",
		description = "Find an earlier prompt and insert it into the current draft", run = M.show })
end

return M
