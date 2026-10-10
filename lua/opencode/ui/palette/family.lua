local M = {}
local actions = require("opencode.actions")
local app_state = require("opencode.state")
local status = require("opencode.session.status")
local request = 0

function M.show()
	local source_id = app_state.get_session().id
	local pending = require("opencode.session.pending")
	local token = pending.token(source_id)
	local directory = app_state.get_session_directory(source_id)
	request = request + 1
	local serial = request
	local function current()
		return request == serial and pending.is_current(token) and app_state.get_session().id == source_id
			and app_state.get_session_directory(source_id) == directory
	end
	local records, items, mode, interrupting, load_request = {}, {}, "all", {}, 0
	local function rebuild()
		while #items > 0 do table.remove(items) end
		local by_id, children, seen = {}, {}, {}
		for _, record in ipairs(records) do
			by_id[record.id] = record
			if record.parentID then
				children[record.parentID] = children[record.parentID] or {}
				children[record.parentID][#children[record.parentID] + 1] = record
			end
		end
		local function walk(record, depth)
			if seen[record.id] then return end
			seen[record.id] = true
			local running = status.is_busy(app_state.get_session_status(record.id))
			if mode == "all" or (mode == "active" and running) or (mode == "inactive" and not running) then
				items[#items + 1] = {
					key = record.id, value = record.id,
					label = string.rep("  ", depth) .. (record.id == source_id and "● " or "")
						.. (require("opencode.util.session").displayTitle(record.title or record.name) or record.id),
					description = (record.agent and record.agent .. " · " or "") .. (running and "Active" or "Inactive"),
					priority = record.id == source_id and 1 or 0,
				}
			end
			for _, child in ipairs(children[record.id] or {}) do walk(child, depth + 1) end
		end
		for _, record in ipairs(records) do if not by_id[record.parentID] then walk(record, 0) end end
	end
	local function load(done)
		load_request = load_request + 1
		local load_serial = load_request
		actions.get_session_family(source_id, function(err, family)
			if not current() or load_serial ~= load_request then return end
			if err then
				vim.notify("Cannot load session family: " .. require("opencode.events.util").format_session_error(err), vim.log.levels.WARN)
				return
			end
			records = family
			rebuild()
			done()
		end)
	end
	load(function()
		require("opencode.ui.menu").open({
			items = items, title = " Session Family ", width = 76, searchable = true, sort = false,
			on_select = function(item)
				if current() then require("opencode.ui.chat.nav").open_family_session(item.value) end
			end,
			keys = {
				{ key = "a", label = "a:all/active/inactive", allow_empty = true, handler = function(ctx)
					if not current() then return end
					mode = mode == "all" and "active" or mode == "active" and "inactive" or "all"
					load(ctx.refresh)
				end },
				{ key = "r", label = "r:refresh", allow_empty = true, handler = function(ctx) if current() then load(ctx.refresh) end end },
				{ key = "x", label = "x:interrupt", handler = function(ctx, item)
					if not current() or interrupting[item.value] or not status.is_busy(app_state.get_session_status(item.value)) then return end
					interrupting[item.value] = true
					actions.interrupt_session(item.value, function(err)
						if not current() then return end
						interrupting[item.value] = nil
						if err then vim.notify("Cannot interrupt session: " .. require("opencode.events.util").format_session_error(err), vim.log.levels.WARN) end
						load(ctx.refresh)
					end)
				end },
			},
		})
	end)
end

function M.register(palette)
	palette.register({
		id = "session.family", title = "Session Family", description = "View active and inactive family sessions",
		category = "session", slash = { name = "family" }, run = M.show,
		on_select = function(context) return context.run() end,
	})
end

return M
