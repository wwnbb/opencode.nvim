local M = {}
local actions = require("opencode.actions")
local state = require("opencode.state")
local pending = require("opencode.session.pending")

local function report(action, err)
	if err then
		local unavailable = err.status == 404 or err.status == 405 or err.status == 501 or err.status == 503
		vim.notify("Could not " .. action .. ": " .. (unavailable and ("This operation is unavailable on this server or location" .. (err.message and (": " .. err.message) or "")) or tostring(err.message or err)), vim.log.levels.ERROR)
	end
end

function M.projects(callback)
	local token = pending.token()
	actions.list_projects(function(err, projects)
		if not pending.is_current(token) then return end
		if err then report("list projects", err); return end
		if #projects == 0 then vim.notify("No projects found", vim.log.levels.INFO); return end
		local items = {}
		for _, project in ipairs(projects) do
			items[#items + 1] = { label = project.name or project.canonical, value = project.id, description = project.canonical, project = project }
		end
		require("opencode.ui.menu").open({ title = " Projects ", items = items, width = 76, searchable = true,
			on_select = function(item) if pending.is_current(token) then callback(item.project) end end })
	end)
end

function M.pick(callback)
	local source, token = state.get_session().id, pending.token()
	local function current() return pending.is_current(token) and state.get_session().id == source end
	local function resolve(directory)
		if not current() then return end
		actions.get_location(directory, function(err, location)
			if not current() then return end
			if err then report("resolve server location", err); return end
			callback(location.directory)
		end)
	end
	local directory = state.get_session_directory(source) or vim.fn.getcwd()
	require("opencode.ui.menu").open({ title = " Session Location ", width = 76, searchable = true, sort = false,
		items = {
			{ label = "Current location", value = directory, kind = "directory", description = directory },
			{ label = "Server default", kind = "directory" },
			{ label = "Project / worktree", kind = "project" },
			{ label = "Server directory…", kind = "input" },
		},
		on_select = function(item)
			if not current() then return end
			if item.kind == "directory" then resolve(item.value)
			elseif item.kind == "input" then
				require("opencode.ui.float").create_input_popup({ title = " Server Directory ", prompt = "Absolute server directory:", on_submit = resolve })
			else
				M.projects(function(project)
					if not current() then return end
					actions.list_worktrees(project.id, function(err, worktrees)
						if not current() then return end
						if err then report("list worktrees", err); return end
						local items = { { label = project.canonical, value = project.canonical } }
						for _, worktree in ipairs(worktrees) do
							if worktree.directory ~= project.canonical then items[#items + 1] = { label = worktree.directory, value = worktree.directory } end
						end
						require("opencode.ui.menu").open({ title = " Project Locations ", items = items, width = 76, searchable = true,
							on_select = function(choice) resolve(choice.value) end })
					end)
				end)
			end
		end })
end

function M.new(directory)
	local token, source = pending.token(), state.get_session().id
	local function create(value)
		if not pending.is_current(token) or state.get_session().id ~= source then return end
		actions.new_session({ location = { directory = value } })
	end
	if type(directory) == "string" and vim.trim(directory) ~= "" then
		actions.get_location(vim.trim(directory), function(err, location)
			if not pending.is_current(token) then return end
			if err then report("resolve server location", err); return end
			create(location.directory)
		end)
	else M.pick(create) end
end

function M.move(directory)
	local session_id, token = state.get_session().id, pending.token(state.get_session().id)
	if not session_id then vim.notify("Open a session first", vim.log.levels.WARN); return end
	local function apply(value)
		if not pending.is_current(token) then return end
		actions.move_session(session_id, value, function(err)
			report("move session", err)
			if not err then vim.notify("Session location change requested", vim.log.levels.INFO) end
		end)
	end
	if type(directory) == "string" and vim.trim(directory) ~= "" then apply(directory) else M.pick(apply) end
end

local function open_directory(directory)
	local session_id, token = state.get_session().id, pending.token()
	require("opencode.ui.menu").open({ title = " Worktree ", message = directory, sort = false,
		items = { "Browse sessions", "New session here", "Move current session here" },
		on_select = function(choice)
			if not pending.is_current(token) then return end
			if choice == "Browse sessions" then require("opencode.ui.palette.session").browse({ roots = true, directory = directory })
			elseif choice == "New session here" then M.new(directory)
			elseif state.get_session().id == session_id then M.move(directory) end
		end })
end

local function remove(project, directory)
	local token = pending.token()
	local function request(force)
		if not pending.is_current(token) then return end
		actions.remove_worktree(project.id, directory, force, function(err)
			if not pending.is_current(token) then return end
			if err and not force and err.force_required then
				require("opencode.ui.menu").open({ title = " Force Delete Worktree? ", width = 76, sort = false,
					message = directory .. "\n" .. err.message .. "\nDelete these file changes permanently?",
					items = { "Delete anyway", "Cancel" }, on_select = function(choice) if choice == "Delete anyway" then request(true) end end })
				return
			end
			if err then report("remove worktree", err); return end
			vim.notify("Worktree removed", vim.log.levels.INFO)
			M.worktrees(project)
		end)
	end
	require("opencode.ui.menu").open({ title = " Delete Worktree? ", width = 76, message = directory, sort = false,
		items = { "Delete", "Cancel" }, on_select = function(choice) if choice == "Delete" then request(false) end end })
end

function M.worktrees(project)
	if not project then M.projects(M.worktrees); return end
	local token = pending.token()
	actions.list_worktrees(project.id, function(err, worktrees)
		if not pending.is_current(token) then return end
		if err then report("list worktrees", err); return end
		local items = { { label = project.canonical, value = project.canonical, root = true } }
		for _, worktree in ipairs(worktrees) do
			if worktree.directory ~= project.canonical then
				items[#items + 1] = { label = worktree.directory, value = worktree.directory, strategy = worktree.strategy }
			end
		end
		require("opencode.ui.menu").open({ title = " Worktrees ", items = items, width = 76, searchable = true,
			on_select = function(item) if pending.is_current(token) then open_directory(item.value) end end,
			keys = {
				{ key = "n", label = "n:new", handler = function(ctx)
					if not pending.is_current(token) then return end
					ctx.close()
					require("opencode.ui.float").create_input_popup({ title = " New Worktree ", prompt = "Name (empty generates):",
						on_submit = function(name)
							if not pending.is_current(token) then return end
							name = vim.trim(name)
							actions.create_worktree(project.id, name ~= "" and { name = name } or {}, function(create_err, created)
								if not pending.is_current(token) then return end
								if create_err then report("create worktree", create_err); return end
								open_directory(created.directory)
							end)
						end })
				end },
				{ key = "r", label = "r:refresh", handler = function(ctx)
					if not pending.is_current(token) then return end
					ctx.close()
					actions.refresh_worktrees(project.id, function(refresh_err)
						if not pending.is_current(token) then return end
						if refresh_err then report("refresh worktrees", refresh_err) else M.worktrees(project) end
					end)
				end },
				{ key = "d", label = "d:delete", handler = function(ctx, item)
					if not pending.is_current(token) then return end
					if item.root or not item.strategy then vim.notify("This directory is not a managed worktree", vim.log.levels.WARN); return end
					ctx.close(); remove(project, item.value)
				end },
			} })
	end)
end

function M.register(palette)
	palette.register({ id = "session.location", title = "Move Session Location", description = "Move the server session to another directory",
		category = "session", slash = { name = "cd" }, enter_with_args = true, with_parts = "reject",
		on_select = function(context) return context.run() end, run = function(context) M.move(context and context.args) end,
		enabled = function() return state.get_session().id ~= nil end })
	palette.register({ id = "session.worktrees", title = "Manage Worktrees", description = "List, create, open, refresh, or remove server worktrees",
		category = "session", slash = { name = "worktrees" }, on_select = function(context) return context.run() end,
		run = function() M.worktrees() end })
	palette.register({ id = "session.workspaces", title = "Select Server Location", description = "Browse sessions or create a session in another location",
		category = "session", slash = { name = "workspaces", aliases = { "projects" } }, on_select = function(context) return context.run() end,
		run = function() M.pick(open_directory) end })
end

return M
