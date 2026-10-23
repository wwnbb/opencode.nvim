local M = {}

function M.show(context)
	local state = require("opencode.state")
	local palette_context = require("opencode.ui.palette.context")
	context = palette_context.capture(context)
	if state.get_session().id ~= context.session_id or not palette_context.valid(context) then return end
	local cfg = (state.get_config() or {}).input or {}
	local search = require("opencode.ui.history_search").new(cfg)
	if not search then return end

	local input = require("opencode.ui.input")
	local scope, draft_token = require("opencode.util.cwd").get(), input.draft_token()
	local current = palette_context.guard(context, { session_token = context.session_id, require_view = true,
		global_session = true, same_directory = true,
		check = function() return require("opencode.util.cwd").get() == scope and input.draft_token() == draft_token end })
	return require("opencode.ui.menu").open({
		context = context,
		title = " Prompt History ", items = search.items, width = 80, searchable = true, sort = false,
		search_placeholder = "Search prompt text", filter = function() return true end,
		on_search = function(query, ctx) search.search(query, ctx.set_items) end,
		on_close = search.close,
		on_select = function(item)
			-- Let the composer's pending BufLeave save finish before restoring the draft.
			vim.schedule(function()
				if not current() then return end
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
