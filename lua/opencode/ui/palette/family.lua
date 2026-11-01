local M = {}
local actions = require("opencode.actions")
local app_state = require("opencode.state")
local status = require("opencode.session.status")
local focus = require("opencode.session.focus")
local requests = setmetatable({}, { __mode = "k" })

function M.show(context)
	local palette_context = require("opencode.ui.palette.context")
	context = palette_context.capture(context)
	local initial_input = focus.capture_input(context.view)
	local source_id = context.session_id
	local key, request = context.view or M, {}
	requests[key] = request
	local current = palette_context.guard(context, { session_token = source_id, require_view = true, same_directory = true,
		check = function() return requests[key] == request end })
	local records, items, mode, interrupting, load_request = {}, {}, context.filter or "all", {}, 0
	local function rebuild()
		while #items > 0 do table.remove(items) end
		local by_id, children, seen, titles, title_counts = {}, {}, {}, {}, {}
		for _, record in ipairs(records) do
			by_id[record.id] = record
			local title = require("opencode.util.session").displayTitle(record.title or record.name) or record.id
			titles[record.id] = title
			title_counts[title] = (title_counts[title] or 0) + 1
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
				local title, suffix = titles[record.id], ""
				if title_counts[title] > 1 then
					local length = 6
					for _, other in ipairs(records) do
						if other.id ~= record.id and titles[other.id] == title then
							while record.id:sub(-length) == other.id:sub(-length) do length = length + 1 end
						end
					end
					suffix = " · " .. record.id:sub(-length)
				end
				items[#items + 1] = {
					key = record.id, value = record.id, title = title,
					label = string.rep("  ", depth) .. (record.id == source_id and "● " or "")
						.. title,
					description = (record.agent and record.agent .. " · " or "") .. (running and "Active" or "Inactive") .. suffix,
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
	local function show()
		local width, status_listener, events = 76, nil, require("opencode.events")
		for _, item in ipairs(items) do
			width = math.max(width, math.min(100, vim.fn.strdisplaywidth(item.label) + vim.fn.strdisplaywidth(item.description) + 10))
		end
		local ctx = require("opencode.ui.menu").open({
			context = context,
			items = items, title = " Session Family ", width = width, searchable = true, sort = false,
			message = "Activity on the connected server only",
			item_detail = function(item) return "Selected: " .. item.title .. "\n" .. item.value end,
			close_on_select = false,
			on_close = function()
				if requests[key] == request then requests[key] = nil end
				if status_listener then events.off("session_status_change", status_listener) end
			end,
			on_select = function(item, ctx)
				if not current() then return end
				ctx.close()
				require("opencode.ui.chat.state").module(context.view, require("opencode.ui.chat.nav")).open_family_session(item.value)
			end,
			keymap_scope = "family_menu",
			keys = {
				{ action = "filter", label = "all/active/inactive", allow_empty = true, handler = function(ctx)
					if not current() then return end
					mode = mode == "all" and "active" or mode == "active" and "inactive" or "all"
					load(ctx.refresh)
				end },
				{ action = "refresh", label = "refresh", allow_empty = true, handler = function(ctx) if current() then load(ctx.refresh) end end },
				{ action = "interrupt", label = "interrupt", handler = function(ctx, item)
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
		if ctx then
			status_listener = events.on("session_status_change", function(data)
				if not current() then return end
				for _, record in ipairs(records) do
					if record.id == data.session_id then rebuild(); ctx.refresh(); return end
				end
			end)
		end
	end
	load(function() focus.with_session_focus(context.view, show, initial_input) end)
end

function M.register(palette)
	palette.register({
		id = "session.family", title = "Session Family", description = "View active and inactive family sessions",
		category = "session", slash = { name = "family" }, run = M.show,
		on_select = function(context) return context.run() end,
	})
end

return M
