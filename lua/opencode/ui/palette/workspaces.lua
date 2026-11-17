local M = {}
local actions = require("opencode.actions")
local state = require("opencode.state")
local focus = require("opencode.session.focus")
local palette_context = require("opencode.ui.palette.context")
local capture, show_menu = palette_context.capture, palette_context.show_menu

-- Only a session-bound view must keep its session, unless the check requires
-- the captured selection (current(true) or opts.require_selection).
local function guard(context, opts)
	return palette_context.guard(context, vim.tbl_extend("force", { require_view = "session_bound" }, opts or {}))
end

local function report(action, err)
	if err then
		local unavailable = err.status == 404 or err.status == 405 or err.status == 501 or err.status == 503
		local message = tostring(err.message or err)
		if unavailable then
			message = "This operation is unavailable on this server or location" .. (err.message and (": " .. err.message) or "")
		end
		vim.notify("Could not " .. action .. ": " .. message, vim.log.levels.ERROR)
	end
end

---Menu options shared by the project pickers: favorites come first (the
---default sort puts priority rows on top) and are toggled in place.
---@param projects table[]
---@return table
function M.project_menu(projects)
	local favorites = {}
	for _, id in ipairs(actions.project_favorites()) do favorites[id] = true end
	local function describe(item)
		item.label = (item.is_favorite and "★ " or "") .. (item.project.name or item.project.canonical)
		item.priority = item.is_favorite and 1 or 0
	end
	local items = {}
	for _, project in ipairs(projects) do
		local item = { value = project.id, description = project.canonical, project = project, is_favorite = favorites[project.id] == true }
		describe(item)
		items[#items + 1] = item
	end
	return { items = items, width = 76, searchable = true, keymap_scope = "project_menu",
		keys = { { action = "favorite", label = "favorite", handler = function(_, item)
			item.is_favorite = actions.toggle_project_favorite(item.value)
			describe(item)
		end } } }
end

function M.projects(callback, context)
	context = capture(context)
	local current = guard(context)
	local initial_input = focus.capture_input(context.view)
	actions.list_projects(function(err, projects)
		if not current() then return end
		if err then report("list projects", err); return end
		if #projects == 0 then vim.notify("No projects found", vim.log.levels.INFO); return end
		show_menu(context, initial_input, vim.tbl_extend("force", M.project_menu(projects), { context = context, title = " Projects ",
			on_select = function(item) if current() then callback(item.project) end end }))
	end)
end

local function starts_with(value, prefix, ignore_case)
	if ignore_case then value, prefix = value:lower(), prefix:lower() end
	return value:sub(1, #prefix) == prefix
end

---Complete an absolute server directory from the server's own filesystem, so
---remote servers complete their paths rather than the editor's.
---@param value string Text before the cursor
---@param callback fun(matches: string[])
function M.complete_directory(value, callback)
	local server_path = require("opencode.util.path")
	if not server_path.is_absolute(value) then callback({}); return end
	local parent, partial = value:match("^(.*[/\\])([^/\\]*)$")
	actions.list_directory(parent, function(err, entries)
		if err then callback({}); return end
		local matches = {}
		-- Prefer exact case; fall back to case-insensitive like a shell would.
		for _, ignore_case in ipairs({ false, true }) do
			for _, entry in ipairs(entries or {}) do
				local hidden = entry.name:sub(1, 1) == "." and partial:sub(1, 1) ~= "."
				if entry.type == "directory" and entry.name ~= "" and not hidden and starts_with(entry.name, partial, ignore_case) then
					matches[#matches + 1] = parent .. entry.name .. "/"
				end
			end
			if #matches > 0 then break end
		end
		table.sort(matches)
		callback(matches)
	end)
end

function M.pick(callback, context)
	context = capture(context)
	local source = context.session_id
	local valid = guard(context, { require_selection = true })
	local function resolve(directory)
		if not valid() then return end
		local initial_input = focus.capture_input(context.view)
		actions.get_location(directory, function(err, location)
			if not valid() then return end
			if err then report("resolve server location", err); return end
			focus.with_session_focus(context.view, function() callback(location.directory) end, initial_input)
		end)
	end
	local directory = state.get_session_directory(source) or require("opencode.util.cwd").get()
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
				require("opencode.ui.float").create_input_popup({ context = context, title = " Server Directory ",
					prompt = "Directory:", default = directory, complete = M.complete_directory,
					on_submit = function(value)
						value = vim.trim(value)
						if value == "" then return end
						local server_path = require("opencode.util.path")
						resolve(server_path.is_absolute(value) and server_path.normalize(value) or value)
					end })
			else
				M.projects(function(project)
					if not valid() then return end
					local initial_input = focus.capture_input(context.view)
					actions.list_worktrees(project.id, function(err, worktrees)
						if not valid() then return end
						if err then report("list worktrees", err); return end
						local items = { { label = project.canonical, value = project.canonical } }
						for _, worktree in ipairs(worktrees) do
							if worktree.directory ~= project.canonical then items[#items + 1] = { label = worktree.directory, value = worktree.directory } end
						end
						show_menu(context, initial_input, { context = context, title = " Project Locations ", items = items, width = 76, searchable = true,
							on_select = function(choice) resolve(choice.value) end })
					end)
				end, context)
			end
		end })
end

function M.new(directory, context)
	context = capture(context)
	local current = guard(context, { require_selection = true })
	local initial_input = context.view and focus.capture_input(context.view)
	local function create(value)
		if not current() then return end
		actions.new_session({ view = context.view, initial_input = initial_input, location = { directory = value } })
	end
	if type(directory) == "string" and vim.trim(directory) ~= "" then
		actions.get_location(vim.trim(directory), function(err, location)
			if not current() then return end
			if err then report("resolve server location", err); return end
			create(location.directory)
		end)
	else M.pick(create, context) end
end

function M.move(directory, context)
	context = capture(context)
	local session_id, current = context.session_id, guard(context, { session_token = context.session_id })
	if not session_id then vim.notify("Open a session first", vim.log.levels.WARN); return end
	local function apply(value)
		if not current() then return end
		actions.move_session(session_id, value, function(err)
			report("move session", err)
			if not err then vim.notify("Session location change requested", vim.log.levels.INFO) end
		end)
	end
	if type(directory) == "string" and vim.trim(directory) ~= "" then apply(directory) else M.pick(apply, context) end
end

local function open_directory(directory, context)
	context = capture(context)
	local current = guard(context)
	require("opencode.ui.menu").open({ context = context, title = " Worktree ", message = directory, sort = false,
		items = { "Browse sessions", "New session here", "Move current session here" },
		on_select = function(choice)
			if not current() then return end
			if choice == "Browse sessions" then require("opencode.ui.palette.session").browse({ roots = true, directory = directory }, context)
			elseif choice == "New session here" then M.new(directory, context)
			elseif current(true) then M.move(directory, context) end
		end })
end

local function remove(project, directory, context)
	context = capture(context)
	local current = guard(context)
	local function request(force)
		if not current() then return end
		actions.remove_worktree(project.id, directory, force, function(err)
			if not current() then return end
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
	local current = guard(context)
	local initial_input = focus.capture_input(context.view)
	actions.list_worktrees(project.id, function(err, worktrees)
		if not current() then return end
		if err then report("list worktrees", err); return end
		local items = { { label = project.canonical, value = project.canonical, root = true } }
		for _, worktree in ipairs(worktrees) do
			if worktree.directory ~= project.canonical then
				items[#items + 1] = { label = worktree.directory, value = worktree.directory, strategy = worktree.strategy }
			end
		end
		show_menu(context, initial_input, { context = context, title = " Worktrees ", items = items, width = 76, searchable = true,
			on_select = function(item) if current() then open_directory(item.value, context) end end,
			keymap_scope = "workspace_menu",
			keys = {
				{ action = "create", label = "new", handler = function(ctx)
					if not current() then return end
					ctx.close()
					require("opencode.ui.float").create_input_popup({ context = context, title = " New Worktree ", prompt = "Name (empty generates):",
						on_submit = function(name)
							if not current() then return end
							name = vim.trim(name)
							local create_input = focus.capture_input(context.view)
							actions.create_worktree(project.id, name ~= "" and { name = name } or {}, function(create_err, created)
								if not current() then return end
								if create_err then report("create worktree", create_err); return end
								focus.with_session_focus(context.view, function() open_directory(created.directory, context) end, create_input)
							end)
						end })
				end },
				{ action = "refresh", label = "refresh", handler = function(ctx)
					if not current() then return end
					ctx.close()
					local refresh_input = focus.capture_input(context.view)
					actions.refresh_worktrees(project.id, function(refresh_err)
						if not current() then return end
						if refresh_err then report("refresh worktrees", refresh_err)
						else focus.with_session_focus(context.view, function() M.worktrees(project, context) end, refresh_input) end
					end)
				end },
				{ action = "delete", label = "delete", handler = function(ctx, item)
					if not current() then return end
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
