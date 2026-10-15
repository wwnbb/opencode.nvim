local M = {}
function M.show()
	local state, diagnostics = require("opencode.state"), require("opencode.diagnostics")
	local id = state.get_session().id
	local items = diagnostics.collect(id)
	if #items == 0 then vim.notify("No server diagnostics in this session", vim.log.levels.INFO); return end
	local pending = require("opencode.session.pending")
	local token = pending.token(id)
	for _, item in ipairs(items) do
		item.label = string.format("%s:%d:%d", item.path, item.line, item.character + 1)
		item.description = item.message:gsub("[%c]", " ")
	end
	local function current() return pending.is_current(token) and state.get_session().id == id end
	require("opencode.ui.menu").open({ title = " Server Diagnostics ", items = items, width = 90,
		on_select = function(item)
			if not current() then return end
			local ok, err = diagnostics.jump(item, id)
			if not ok then vim.notify(err, vim.log.levels.WARN) end
		end,
		keymap_scope = "diagnostics",
		keys = { { action = "quickfix", label = "quickfix", handler = function(ctx)
			if not current() then return end
			ctx.close(); diagnostics.quickfix(items, id)
		end } } })
end
function M.register(palette)
	palette.register({ id = "action.diagnostics", title = "Server Diagnostics", category = "actions",
		slash = { name = "diagnostics" }, run = M.show, on_select = function(ctx) return ctx.run() end,
		enabled = function() return require("opencode.state").get_session().id ~= nil end })
end
return M
