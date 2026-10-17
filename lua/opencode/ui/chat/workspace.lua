-- Virtual layouts share one Neovim tab; hidden layouts retain their chat views.
local M = {}
local cs = require("opencode.ui.chat.state")
local layouts, active, next_id = {}, nil, 0
local function chat() return require("opencode.ui.chat") end
local function bar() return require("opencode.ui.chat.workspace_bar") end

function M.list() return layouts end
function M.current() return active end

local function members(layout)
	return vim.tbl_filter(function(view) return view.workspace_id == layout.id end, cs.all())
end

function M.ensure(view)
	if not cs.workspace.tabpage or not vim.api.nvim_tabpage_is_valid(cs.workspace.tabpage) then return end
	local known = false
	for _, layout in ipairs(layouts) do if layout.id == view.workspace_id then known = true end end
	if not known then
		next_id = next_id + 1
		active = { id = next_id, session_id = cs.session(view).id, last_view = view, root_view = view }
		layouts[#layouts + 1] = active
		view.workspace_id = active.id
	end
	bar().ensure()
end

local function capture(node)
	if node[1] ~= "leaf" then
		local children = {}
		for _, child in ipairs(node[2]) do
			local saved = capture(child)
			if saved then children[#children + 1] = saved end
		end
		if #children == 1 then return children[1] end
		if #children > 0 then return { kind = node[1], children = children } end
		return
	end
	local win = node[2]
	if win == bar().winid() then return end
	local buf = vim.api.nvim_win_get_buf(win)
	local view = cs.for_window(win)
	if view and view.bufnr ~= buf then view = nil end
	local options = {}
	for name, info in pairs(vim.api.nvim_get_all_options_info()) do
		if info.scope == "win" then options[name] = vim.api.nvim_get_option_value(name, { win = win, scope = "local" }) end
	end
	return { kind = "leaf", buf = buf, view = view, owned = view and view.winid == win,
		focused = win == vim.api.nvim_get_current_win(), options = options,
		directory = vim.fn.haslocaldir(win) == 1 and vim.fn.getcwd(win) or nil,
		width = vim.api.nvim_win_get_width(win), height = vim.api.nvim_win_get_height(win),
		position = vim.api.nvim_win_call(win, vim.fn.winsaveview) }
end

local function suspend(save_tree)
	if not active then return end
	local input = require("opencode.ui.input")
	for _, view in ipairs(members(active)) do
		input.close_for_view(view)
		local details = package.loaded["opencode.ui.chat.execute_details"]
		if details then cs.module(view, details).close(false) end
		local edits = package.loaded["opencode.ui.chat.edits"]
		if edits then cs.module(view, edits).close_inline_diff_split({ preserve_actual = true }) end
	end
	if save_tree ~= false and not active.incomplete then active.tree = capture(vim.fn.winlayout()) end
	local keep = bar().winid()
	if not keep then
		vim.cmd("noautocmd botright new")
		keep = vim.api.nvim_get_current_win()
		cs.workspace.anchor = keep
	end
	local buffers = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(cs.workspace.tabpage)) do
		if win ~= keep then
			local buf = vim.api.nvim_win_get_buf(win)
			if buffers[buf] == nil then buffers[buf] = vim.bo[buf].bufhidden end
			vim.bo[buf].bufhidden = "hide"
		end
	end
	for _, view in ipairs(members(active)) do
		view.visible, view.suspended, view.winid = false, true, nil
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(cs.workspace.tabpage)) do
		-- Closing a popup layer can synchronously close its sibling windows.
		if win ~= keep and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
	end
	for buf, hidden in pairs(buffers) do
		if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].bufhidden = hidden end
	end
end

local function restore(tree, win, leaves)
	if tree.kind == "leaf" then
		if not vim.api.nvim_buf_is_valid(tree.buf) then tree.buf = vim.api.nvim_create_buf(false, true) end
		-- win_call changes window context without switching its working directory.
		vim.api.nvim_set_current_win(win)
		if tree.directory then
			vim.cmd.lcd({ args = { tree.directory }, mods = { noautocmd = true } })
		elseif vim.fn.haslocaldir() == 1 then
			local command = vim.fn.haslocaldir(-1) == 1 and "tcd" or "cd"
			vim.cmd[command]({ args = { vim.fn.getcwd(-1) }, mods = { noautocmd = true } })
		end
		vim.api.nvim_win_set_buf(win, tree.buf)
		tree.win = win
		leaves[#leaves + 1] = tree
		return
	end
	local windows = { win }
	for i = 2, #tree.children do
		vim.api.nvim_win_call(windows[i - 1], function()
			vim.cmd(tree.kind == "row" and "rightbelow vsplit" or "rightbelow split")
			windows[i] = vim.api.nvim_get_current_win()
		end)
	end
	for i, child in ipairs(tree.children) do restore(child, windows[i], leaves) end
end

local function show(layout)
	active, layout.incomplete = layout, true
	local anchor = cs.workspace.anchor
	cs.workspace.anchor = nil
	if not anchor then
		vim.api.nvim_win_call(bar().winid(), function()
			vim.cmd("botright new")
			anchor = vim.api.nvim_get_current_win()
		end)
		vim.wo[anchor].winhighlight = ""
		vim.wo[anchor].statusline = vim.api.nvim_get_option_value("statusline", { scope = "global" })
	end
	local leaves = {}
	restore(layout.tree, anchor, leaves)
	for _, leaf in ipairs(leaves) do
		if leaf.view and cs.valid(leaf.view) then
			leaf.view.suspended = nil
			if leaf.owned or not leaf.view.winid then chat().for_view(leaf.view).attach_window(leaf.win) end
		end
	end
	for _, leaf in ipairs(leaves) do
		pcall(vim.api.nvim_win_set_width, leaf.win, leaf.width)
		pcall(vim.api.nvim_win_set_height, leaf.win, leaf.height)
	end
	-- Saved pane heights may predate a resize; give the extra rows back to the content.
	local header = bar().winid()
	if header then vim.api.nvim_win_set_height(header, 1) end
	for _, leaf in ipairs(leaves) do
		for name, value in pairs(leaf.options or {}) do
			pcall(vim.api.nvim_set_option_value, name, value, { win = leaf.win, scope = "local" })
		end
		vim.api.nvim_win_call(leaf.win, function() vim.fn.winrestview(leaf.position) end)
		if leaf.focused then layout.focus_win = leaf.win end
	end
	layout.incomplete = nil
end

local function transition(run)
	local previous = active
	cs.workspace.switching = true
	local ok, err = xpcall(run, debug.traceback)
	if not ok and previous then
		local restored, restore_error = xpcall(function()
			-- A partial restore must never replace either saved layout tree.
			suspend(false)
			show(previous)
		end, debug.traceback)
		if not restored then err = err .. "\nCould not restore previous layout: " .. restore_error end
	end
	cs.workspace.switching = false
	return ok, err
end

local function focus_active()
	if active and active.last_view and active.last_view.visible then chat().focus_view(active.last_view) end
	if active and active.focus_win and vim.api.nvim_win_is_valid(active.focus_win) then
		vim.api.nvim_set_current_win(active.focus_win)
	end
	bar().update()
end

function M.select(id)
	local target
	for _, layout in ipairs(layouts) do if layout.id == id then target = layout; break end end
	if not target then return false end
	if target == active and not target.incomplete then
		if target.last_view then chat().focus_view(target.last_view) end
		return true
	end
	vim.api.nvim_set_current_tabpage(cs.workspace.tabpage)
	local ok, err = transition(function() suspend(); show(target) end)
	focus_active()
	if not ok then error(err) end
	return true
end

function M.create(session)
	if active and cs.workspace.tabpage and vim.api.nvim_tabpage_is_valid(cs.workspace.tabpage) then
		vim.api.nvim_set_current_tabpage(cs.workspace.tabpage)
	else
		chat().open()
	end
	local view, created
	local previous = active and active.last_view
	local winhighlight = previous and previous.winid and vim.api.nvim_win_is_valid(previous.winid)
		and vim.wo[previous.winid].winhighlight or ""
	local ok, err = transition(function()
		suspend()
		view = cs.new()
		view.session_id, view.session_name = session.id, session.title or session.name
		next_id = next_id + 1
		active = { id = next_id, session_id = session.id, last_view = view, root_view = view }
		created = active
		layouts[#layouts + 1] = active
		view.workspace_id = active.id
		chat().for_view(view).create()
		active.tree = { kind = "leaf", buf = view.bufnr, view = view, owned = true,
			width = vim.o.columns, height = vim.o.lines, position = { lnum = 1, col = 0, topline = 1 },
			options = { winhighlight = winhighlight } }
		show(active)
	end)
	if not ok then
		for index, layout in ipairs(layouts) do
			if layout == created then table.remove(layouts, index); break end
		end
		if view then
			view.suspended, view.workspace_id = nil, nil
			local owned = view.modules and view.modules.init
			if owned then owned.dispose()
			else
				for _, mod in pairs(view.modules or {}) do if mod.dispose then mod.dispose() end end
			end
			cs.remove(view)
		end
	end
	focus_active()
	if not ok then error(err) end
	return view
end

function M.cycle(direction)
	for i, layout in ipairs(layouts) do
		if layout == active then return M.select(layouts[((i - 1 + direction) % #layouts) + 1].id) end
	end
	return false
end

function M.reorder(id, direction)
	for index, layout in ipairs(layouts) do
		if layout.id == id then
			local target = math.max(1, math.min(#layouts, index + (direction < 0 and -1 or 1)))
			if target == index then return false end
			layouts[index], layouts[target] = layouts[target], layouts[index]
			bar().update()
			return true
		end
	end
	return false
end

local function prune(tree, layout)
	if not tree then return end
	if tree.kind == "leaf" then
		if not tree.view or (tree.view.workspace_id == layout.id and (tree.view.visible or tree.view.suspended)) then return tree end
		return
	end
	local children = {}
	for _, child in ipairs(tree.children) do
		local retained = prune(child, layout)
		if retained then children[#children + 1] = retained end
	end
	if #children == 1 then return children[1] end
	if #children > 1 then tree.children = children; return tree end
end

function M.reset()
	cs.workspace.switching = true
	for _, layout in ipairs(layouts) do
		for _, view in ipairs(members(layout)) do
			if view.suspended then
				view.suspended = nil
				chat().for_view(view).dispose()
				cs.remove(view)
			end
			view.workspace_id = nil
		end
	end
	layouts, active = {}, nil
	bar().remove()
	cs.workspace.switching = false
end

function M.after_close()
	if cs.workspace.switching then return end
	if cs.workspace.tabpage and not vim.api.nvim_tabpage_is_valid(cs.workspace.tabpage) then
		M.reset()
		cs.workspace.tabpage = nil
		return
	end
	for i = #layouts, 1, -1 do
		local layout = layouts[i]
		local remaining = vim.tbl_filter(function(view) return view.visible or view.suspended end, members(layout))
		if layout ~= active then layout.tree = prune(layout.tree, layout) end
		local has_files = layout ~= active and layout.tree ~= nil
		if layout == active and cs.workspace.tabpage then
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(cs.workspace.tabpage)) do
				if win ~= bar().winid() and vim.api.nvim_win_get_config(win).relative == "" then has_files = true; break end
			end
		end
		if #remaining == 0 and not has_files then
			for _, view in ipairs(members(layout)) do view.workspace_id = nil end
			table.remove(layouts, i)
			if active == layout then active = nil end
		elseif not cs.valid(layout.last_view) or not (layout.last_view.visible or layout.last_view.suspended) then
			layout.last_view = remaining[1]
		end
		if remaining[1] and not (layout.root_view.visible or layout.root_view.suspended) then
			layout.root_view = remaining[1]
			layout.session_id = cs.session(remaining[1]).id
		end
	end
	if not active and #layouts > 0 then M.select(layouts[1].id)
	elseif #layouts == 0 then
		local keep = bar().winid() or cs.workspace.anchor
		if keep and vim.api.nvim_win_is_valid(keep) and #vim.api.nvim_list_tabpages() == 1 then vim.cmd("tabnew") end
		bar().remove()
		if cs.workspace.anchor and vim.api.nvim_win_is_valid(cs.workspace.anchor) then vim.api.nvim_win_close(cs.workspace.anchor, true) end
		cs.workspace.anchor, cs.workspace.tabpage = nil, nil
	else bar().update() end
end

function M.close_current()
	if not active then return end
	local closing, replacement = active, nil
	local ids = {}
	cs.workspace.switching = true
	suspend()
	for _, view in ipairs(members(closing)) do
		local root = (view.session_stack or {})[1]
		local id = root and root.id or cs.session(view).id
		if id then ids[id] = true end
		view.suspended, view.workspace_id = nil, nil
		chat().for_view(view).dispose()
		cs.remove(view)
	end
	for i, layout in ipairs(layouts) do
		if layout == closing then
			table.remove(layouts, i)
			replacement = layouts[math.max(1, i - 1)]
			break
		end
	end
	active = nil
	cs.workspace.switching = false
	if replacement then M.select(replacement.id) end
	for id in pairs(ids) do require("opencode.actions").close_session({ session_id = id, silent = true }) end
	M.after_close()
end

function M.session_changed(view, session)
	for _, layout in ipairs(layouts) do
		if layout.root_view == view then layout.session_id = ((view.session_stack or {})[1] or session).id end
	end
	bar().update()
end

return M
