local M = {}
local actions = require("opencode.actions")
local state = require("opencode.state")
local pending = require("opencode.session.pending")

local function capture(context)
	return require("opencode.ui.palette").capture_context(context)
end

local function current(context, token, require_selection)
	return pending.is_current(token) and (not ((context.view and context.view.session_bound) or require_selection)
		or require("opencode.ui.palette").context_valid(context))
end

local function report(action, err)
	if err then
		local unavailable = err.status == 404 or err.status == 405 or err.status == 501 or err.status == 503
		vim.notify("Could not " .. action .. ": " .. (unavailable and ("This operation is unavailable on this server or location" .. (err.message and (": " .. err.message) or "")) or tostring(err.message or err)), vim.log.levels.ERROR)
	end
end

function M.projects(callback, context)
	context = capture(context)
	local token = pending.token()
	actions.list_projects(function(err, projects)
		if not current(context, token) then return end
		if err then report("list projects", err); return end
		if #projects == 0 then vim.notify("No projects found", vim.log.levels.INFO); return end
		local items = {}
		for _, project in ipairs(projects) do
			items[#items + 1] = { label = project.name or project.canonical, value = project.id, description = project.canonical, project = project }
		end
		require("opencode.ui.menu").open({ context = context, title = " Projects ", items = items, width = 76, searchable = true,
			on_select = function(item) if current(context, token) then callback(item.project) end end })
	end)
end

function M.pick(callback, context)
	context = capture(context)
	local source, token = context.session_id, pending.token()
	local function valid() return current(context, token, true) end
	local function resolve(directory)
		if not valid() then return end
		actions.get_location(directory, function(err, location)
			if not valid() then return end
			if err then report("resolve server location", err); return end
			callback(location.directory)
		end)
	end
	local directory = state.get_session_directory(source) or vim.fn.getcwd()
	require("opencode.ui.menu").open({ context = context, title = " Session Location ", width = 76, searchable = true, sort = false,
		items = {
			{ label = "Current location", value = directory, kind = "directory", description = directory },
			{ label = "Server default", kind = "directory" },
			{ label = "Project / worktree", kind = "project" },
			{ label = "Server directory…", kind = "input" },
		},
		on_select = function(item)
			if not valid() then return end
			if item.kind == "directory" then resolve(item.value)
			elseif item.kind == "input" then
				require("opencode.ui.float").create_input_popup({ context = context, title = " Server Directory ", prompt = "Absolute server directory:", on_submit = resolve })
			else
				M.projects(function(project)
					if not valid() then return end
					actions.list_worktrees(project.id, function(err, worktrees)
						if not valid() then return end
						if err then report("list worktrees", err); return end
						local items = { { label = project.canonical, value = project.canonical } }
						for _, worktree in ipairs(worktrees) do
							if worktree.directory ~= project.canonical then items[#items + 1] = { label = worktree.directory, value = worktree.directory } end
						end
						require("opencode.ui.menu").open({ context = context, title = " Project Locations ", items = items, width = 76, searchable = true,
							on_select = function(choice) resolve(choice.value) end })
					end)
				end, context)
			end
		end })
end

function M.new(directory, context)
	context = capture(context)
	local token = pending.token()
	local function create(value)
		if not current(context, token, true) then return end
		actions.new_session({ view = context.view, location = { directory = value } })
	end
	if type(directory) == "string" and vim.trim(directory) ~= "" then
		actions.get_location(vim.trim(directory), function(err, location)
			if not current(context, token, true) then return end
			if err then report("resolve server location", err); return end
			create(location.directory)
		end)
	else M.pick(create, context) end
end

function M.move(directory, context)
	context = capture(context)
	local session_id, token = context.session_id, pending.token(context.session_id)
	if not session_id then vim.notify("Open a session first", vim.log.levels.WARN); return end
	local function apply(value)
		if not current(context, token) then return end
		actions.move_session(session_id, value, function(err)
			report("move session", err)
			if not err then vim.notify("Session location change requested", vim.log.levels.INFO) end
		end)
	end
	if type(directory) == "string" and vim.trim(directory) ~= "" then apply(directory) else M.pick(apply, context) end
end

local function open_directory(directory, context)
	context = capture(context)
	local token = pending.token()
	require("opencode.ui.menu").open({ context = context, title = " Worktree ", message = directory, sort = false,
		items = { "Browse sessions", "New session here", "Move current session here" },
		on_select = function(choice)
			if not current(context, token) then return end
			if choice == "Browse sessions" then require("opencode.ui.palette.session").browse({ roots = true, directory = directory }, context)
			elseif choice == "New session here" then M.new(directory, context)
			elseif current(context, token, true) then M.move(directory, context) end
		end })
end

local function remove(project, directory, context)
	context = capture(context)
	local token = pending.token()
	local function request(force)
		if not current(context, token) then return end
		actions.remove_worktree(project.id, directory, force, function(err)
			if not current(context, token) then return end
			if err and not force and err.force_required then
				require("opencode.ui.menu").open({ context = context, title = " Force Delete Worktree? ", width = 76, sort = false,
					message = directory .. "\n" .. err.message .. "\nDelete these file changes permanently?",
					items = { "Delete anyway", "Cancel" }, on_select = function(choice) if choice == "Delete anyway" then request(true) end end })
				return
			end
			if err then report("remove worktree", err); return end
			vim.notify("Worktree removed", vim.log.levels.INFO)
			M.worktrees(project, context)
		end)
	end
	require("opencode.ui.menu").open({ context = context, title = " Delete Worktree? ", width = 76, message = directory, sort = false,
		items = { "Delete", "Cancel" }, on_select = function(choice) if choice == "Delete" then request(false) end end })
end

function M.worktrees(project, context)
	context = capture(context)
	if not project then M.projects(function(item) M.worktrees(item, context) end, context); return end
	local token = pending.token()
	actions.list_worktrees(project.id, function(err, worktrees)
		if not current(context, token) then return end
		if err then report("list worktrees", err); return end
		local items = { { label = project.canonical, value = project.canonical, root = true } }
		for _, worktree in ipairs(worktrees) do
			if worktree.directory ~= project.canonical then
				items[#items + 1] = { label = worktree.directory, value = worktree.directory, strategy = worktree.strategy }
			end
		end
		require("opencode.ui.menu").open({ context = context, title = " Worktrees ", items = items, width = 76, searchable = true,
			on_select = function(item) if current(context, token) then open_directory(item.value, context) end end,
			keymap_scope = "workspace_menu",
			keys = {
				{ action = "create", label = "new", handler = function(ctx)
					if not current(context, token) then return end
					ctx.close()
					require("opencode.ui.float").create_input_popup({ context = context, title = " New Worktree ", prompt = "Name (empty generates):",
						on_submit = function(name)
							if not current(context, token) then return end
							name = vim.trim(name)
							actions.create_worktree(project.id, name ~= "" and { name = name } or {}, function(create_err, created)
								if not current(context, token) then return end
								if create_err then report("create worktree", create_err); return end
								open_directory(created.directory, context)
							end)
						end })
				end },
				{ action = "refresh", label = "refresh", handler = function(ctx)
					if not current(context, token) then return end
					ctx.close()
					actions.refresh_worktrees(project.id, function(refresh_err)
						if not current(context, token) then return end
						if refresh_err then report("refresh worktrees", refresh_err) else M.worktrees(project, context) end
					end)
				end },
				{ action = "delete", label = "delete", handler = function(ctx, item)
					if not current(context, token) then return end
					if item.root or not item.strategy then vim.notify("This directory is not a managed worktree", vim.log.levels.WARN); return end
					ctx.close(); remove(project, item.value, context)
				end },
			} })
	end)
end

function M.register(palette)
	palette.register({ id = "session.location", title = "Move Session Location", description = "Move the server session to another directory",
		category = "session", slash = { name = "cd" }, enter_with_args = true, with_parts = "reject",
		on_select = function(context) return context.run() end, run = function(context) M.move(context and context.args, context) end,
		enabled = function() return state.get_session().id ~= nil end })
	palette.register({ id = "session.worktrees", title = "Manage Worktrees", description = "List, create, open, refresh, or remove server worktrees",
		category = "session", slash = { name = "worktrees" }, on_select = function(context) return context.run() end,
		run = function(context) M.worktrees(nil, context) end })
	palette.register({ id = "session.workspaces", title = "Select Server Location", description = "Browse sessions or create a session in another location",
		category = "session", slash = { name = "workspaces", aliases = { "projects" } }, on_select = function(context) return context.run() end,
		run = function(context)
			context = capture(context)
			M.pick(function(directory) open_directory(directory, context) end, context)
		end })
end

return M
