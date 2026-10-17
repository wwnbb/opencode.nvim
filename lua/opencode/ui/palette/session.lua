-- opencode.nvim - Session palette commands

local M = {}

local actions = require("opencode.actions")
local session_util = require("opencode.util.session")
local state = require("opencode.state")
local pending = require("opencode.session.pending")

local function capture(context)
	return require("opencode.ui.palette").capture_context(context)
end

local function current(context, token)
	return pending.is_current(token) and (not (context.view and context.view.session_bound)
		or require("opencode.ui.palette").context_valid(context))
end

local function directory_label(directory)
	local path = tostring(directory or ""):gsub("\\", "/"):gsub("/+$", "")
	local parts = vim.split(path, "/", { trimempty = true })
	local label = #parts > 2 and (".../" .. parts[#parts - 1] .. "/" .. parts[#parts]) or directory
	return require("opencode.util.text").truncate(label or "", 28, "...")
end

local function report(action, err)
	if err then vim.notify("Could not " .. action .. ": " .. tostring(err.message or err), vim.log.levels.ERROR) end
end

local function rename(session, title, callback, context)
	context = capture(context)
	local token = pending.token(session.id)
	local function submit(value)
		if not current(context, token) then return end
		actions.rename_session(session.id, value, function(err, info)
			if not current(context, token) then return end
			report("rename session", err)
			if not err and callback then callback(info) end
		end)
	end
	if title ~= nil then submit(title); return end
	require("opencode.ui.float").create_input_popup({ context = context, title = " Rename Session ", prompt = "Title (empty regenerates):",
		default = session_util.displayTitle(session.title or session.name), on_submit = submit })
end

local function remove(session, callback, context)
	context = capture(context)
	local token = pending.token(session.id)
	local title = session_util.displayTitle(session.title or session.name) or session.id
	local prompt = "Delete session '" .. title .. "'?"
	require("opencode.ui.menu").open({ context = context, items = { "Yes", "No" }, title = "Delete Session", message = prompt,
		width = vim.fn.strdisplaywidth(prompt) + 12, sort = false,
		on_select = function(choice)
			if choice ~= "Yes" or not current(context, token) then return end
			actions.delete_session(session.id, function(err)
				if not pending.is_current(token) then return end
				report("delete session", err)
				if not err then
					vim.notify("Session deleted", vim.log.levels.INFO)
					if callback then callback() end
				end
			end)
		end })
end

function M.open(id, context)
	context = capture(context)
	local token = pending.token()
	local function submit(value)
		if not current(context, token) then return end
		actions.open_session(vim.trim(value), { view = context.view, notify = true, reason = "session_open" }, function(err) report("open session", err) end)
	end
	if id ~= nil and vim.trim(id) ~= "" then submit(id); return end
	require("opencode.ui.float").create_input_popup({ context = context, title = " Open Session ", prompt = "Session ID:", on_submit = submit })
end

local function projects(context)
	context = capture(context)
	local token = pending.token()
	actions.list_projects(function(err, values)
		if not current(context, token) then return end
		if err then report("list projects", err); return end
		local items = {}
		for _, project in ipairs(values) do
			items[#items + 1] = { label = project.name or project.canonical, value = project.id, project = project, description = project.canonical }
		end
		require("opencode.ui.menu").open({ context = context, items = items, title = " Session Projects ", width = 76, searchable = true,
			on_select = function(item)
				if not current(context, token) then return end
				actions.list_worktrees(item.value, function(worktree_err, worktrees)
					if not current(context, token) then return end
					if worktree_err then report("list worktrees", worktree_err); M.browse({ roots = true, project = item.value }, context); return end
					local locations = {
						{ label = "All project sessions", query = { roots = true, project = item.value } },
						{ label = item.project.canonical, query = { roots = true, directory = item.project.canonical } },
					}
					for _, worktree in ipairs(worktrees) do
						if worktree.directory ~= item.project.canonical then
							locations[#locations + 1] = { label = worktree.directory, query = { roots = true, directory = worktree.directory } }
						end
					end
					require("opencode.ui.menu").open({ context = context, items = locations, title = " Session Locations ", width = 76, searchable = true,
						on_select = function(location) if current(context, token) then M.browse(location.query, context) end end })
				end)
			end })
	end)
end

function M.browse(query, context)
	context = capture(context)
	query = query or { roots = true }
	local token = pending.token()
	actions.list_sessions(query, function(err, sessions)
		if not current(context, token) then return end
		if err then report("list sessions", err); return end
		local selected, items = context.session_id, {}
		for _, session in ipairs(sessions or {}) do
			local title = session_util.displayTitle(session.title) or "New session"
			local directory = session.directory or (session.location and session.location.directory) or ""
			items[#items + 1] = { label = (selected == session.id and "● " or "  ") .. title,
				title = title, directory = directory, search_text = directory,
				value = session.id, session = session, description = directory_label(directory),
				sort_key = session.time and session.time.updated or 0 }
		end
		local scope = query.directory and ("Directory: " .. directory_label(query.directory))
			or (query.project and "Selected project" or "All projects")
		require("opencode.ui.menu").open({ context = context, items = items, title = " Switch Session ", width = 90, searchable = true,
			message = scope .. " · " .. #items .. (#items == 1 and " session" or " sessions") .. " · ● current",
			search_placeholder = "Search by session title or directory...", confirm_label = "open",
			item_detail = function(item) return "Selected: " .. item.title .. "\n" .. item.directory end,
			sort = function(a, b) return a.sort_key > b.sort_key end,
			on_select = function(item) if current(context, token) then M.open(item.value, context) end end,
			keymap_scope = "session_menu",
			keys = {
				{ action = "rename", label = "rename", handler = function(ctx, item)
					if not current(context, token) then return end
					ctx.close(); rename(item.session, nil, function() M.browse(query, context) end, context)
				end },
				{ action = "delete", label = "delete", handler = function(ctx, item)
					if not current(context, token) then return end
					ctx.close(); remove(item.session, function() M.browse(query, context) end, context)
				end },
				{ action = "project", label = "project/worktree", allow_empty = true, handler = function(ctx)
					if current(context, token) then ctx.close(); projects(context) end
				end },
				{ action = "all", label = "all projects", allow_empty = true, handler = function(ctx)
					if current(context, token) then ctx.close(); M.browse(nil, context) end
				end },
				{ action = "current_directory", label = "current directory", allow_empty = true, handler = function(ctx)
					if current(context, token) then
						ctx.close(); M.browse({ roots = true, directory = state.get_session_directory(context.session_id) or vim.fn.getcwd() }, context)
					end
				end },
			} })
	end)
end

function M.register(palette)
	local keymaps = (state.get_config() or require("opencode.config").defaults).keymaps or {}
	palette.register({
		id = "session.timeline",
		title = "Timeline",
		description = "Choose a user turn to jump, copy, fork, or revert",
		category = "session",
		slash = { name = "timeline" },
		on_select = function(context) return context.run() end,
		run = function(context) require("opencode.ui.timeline").show(capture(context)) end,
		enabled = function() return state.get_session().id ~= nil end,
	})
	palette.register({ id = "session.history", title = "Load Full Session History", category = "session",
		description = "Fetch every history page", run = function(context)
			context = capture(context)
			local sid = context.session_id
			if not sid then return end
			local token = pending.token(sid)
			actions.load_session_messages(sid, { all = true }, function(err, messages)
				if not current(context, token) then return end
				if not err then
					local view = context.view or require("opencode.ui.chat.state").state
					view.full_history_sessions[sid] = true
					require("opencode.ui.chat.render_coordinator").request({ session_id = sid, view_id = view.id, reason = "full_history" })
				end
				vim.notify(err and ("Could not load history: " .. err.message) or ("Loaded " .. #messages .. " messages"), err and vim.log.levels.ERROR or vim.log.levels.INFO)
			end)
		end })

	palette.register({
		id = "session.new",
		title = "New Session",
		description = "Create a new chat session",
		category = "session",
		slash = { name = "new" },
		enter_with_args = true, with_parts = "reject",
		on_select = function(context) return context.run() end,
		run = function(context) require("opencode.ui.palette.workspaces").new(context and context.args, capture(context)) end,
	})
	palette.register({
		id = "session.aside",
		title = "Ask a Side Question (/btw)",
		description = "Ask using session context without adding a chat turn",
		category = "session",
		slash = { name = "btw" },
		on_select = function(ctx) return ctx.run() end,
		enter_with_args = true,
		with_parts = "reject",
		parts_error = "/btw supports text questions only",
		run = function(ctx)
			ctx = capture(ctx)
			local args = ctx and ctx.args
			if type(args) == "string" and vim.trim(args) ~= "" then
				actions.ask_btw(args, ctx.session_id)
				return
			end
			local session_id = ctx.session_id
			if not session_id then
				vim.notify("Open a session first", vim.log.levels.WARN)
				return
			end
			local pending = require("opencode.session.pending")
			local token = pending.token(session_id)
			require("opencode.ui.btw").prompt(function(question)
				if not current(ctx, token) then return end
				actions.ask_btw(question, session_id)
			end)
		end,
	})
	palette.register({
		id = "session.active",
		title = "Active Sessions",
		description = "Show running, waiting, and recent sessions",
		category = "session",
		keybind = keymaps.active_sessions,
		run = function(context)
			actions.active_sessions(capture(context))
		end,
	})
	palette.register({
		id = "session.close",
		title = "Close Session Tab",
		description = "Close the current active tab without deleting the session",
		category = "session",
		keybind = keymaps.close_session,
		slash = { name = "close", aliases = { "close-session", "close-tab" } },
		run = function(context)
			context = capture(context)
			actions.close_session({ session_id = context.session_id, notify = true })
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.list", title = "Switch Session", description = "Browse sessions across projects and worktrees",
		category = "session", slash = { name = "sessions", aliases = { "resume", "continue" } },
		on_select = function(context) return context.run() end, run = function(context) M.browse(nil, context) end,
	})
	palette.register({
		id = "session.open", title = "Open Session by ID", description = "Open a session in its server location",
		category = "session", slash = { name = "open" }, enter_with_args = true, with_parts = "reject",
		on_select = function(context) return context.run() end, run = function(context) M.open(context and context.args, context) end,
	})
	palette.register({
		id = "session.rename", title = "Rename Session", description = "Rename the current session; an empty title regenerates it",
		category = "session", slash = { name = "rename" }, enter_with_args = true, with_parts = "reject",
		on_select = function(context) return context.run() end,
		run = function(context)
			context = capture(context)
			rename(state.get_session_record(context.session_id) or { id = context.session_id }, context.args, nil, context)
		end,
		enabled = function() return state.get_session().id ~= nil end,
	})
	palette.register({
		id = "session.reopen", title = "Reopen Closed Session Tab", category = "session", slash = { name = "reopen" },
		on_select = function(context) return context.run() end, run = function(context) actions.reopen_session_tab(capture(context)) end,
		enabled = function() return #state.get_closed_session_order() > 0 end,
	})
	local function runtime_tab()
		return state.is_runtime_session(require("opencode.selectors").get_current_runtime_root_id())
	end
	palette.register({
		id = "session.move-left", title = "Move Session Tab Left", category = "session", slash = { name = "tab-left" },
		on_select = function(context) return context.run() end, run = function(context) actions.reorder_session_tab(-1, capture(context)) end, enabled = runtime_tab,
	})
	palette.register({
		id = "session.move-right", title = "Move Session Tab Right", category = "session", slash = { name = "tab-right" },
		on_select = function(context) return context.run() end, run = function(context) actions.reorder_session_tab(1, capture(context)) end, enabled = runtime_tab,
	})
	palette.register({
		id = "session.fork",
		title = "Fork Session",
		description = "Fork full session or before a user turn",
		category = "session",
		slash = { name = "fork" },
		on_select = function(context) return context.run() end,
		run = function(context)
			require("opencode.ui.timeline").show_fork_picker(capture(context))
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.copy",
		title = "Copy Session Transcript",
		description = "Copy complete server transcript to clipboard",
		category = "session",
		slash = { name = "copy" },
		on_select = function(context) return context.run() end,
		run = function(context)
			require("opencode.ui.export").run({ action = "copy", format = "markdown", thinking = true, tools = true }, capture(context))
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.export",
		title = "Export Session Transcript",
		description = "Export complete history as Markdown or JSON",
		category = "session",
		slash = { name = "export" },
		on_select = function(context) return context.run() end,
		run = function(context) require("opencode.ui.export").show(capture(context)) end,
		enabled = function() return state.get_session().id ~= nil end,
	})
	palette.register({
		id = "session.copy_raw",
		title = "Copy Raw Session Object",
		description = "Copy complete server session export as JSON",
		category = "session",
		run = function(context)
			require("opencode.ui.export").run({ action = "copy", format = "json", sanitize = false }, capture(context))
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.delete", title = "Delete Session", description = "Delete current session", category = "session",
		run = function(context)
			context = capture(context)
			remove(state.get_session_record(context.session_id) or { id = context.session_id }, nil, context)
		end,
		enabled = function() return state.get_session().id ~= nil end,
	})
	require("opencode.ui.palette.workspaces").register(palette)
end

return M
