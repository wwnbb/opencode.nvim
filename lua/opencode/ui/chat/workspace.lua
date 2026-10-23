-- Virtual layouts share one Neovim tab; hidden layouts retain their chat views.
local M = {}
local cs = require("opencode.ui.chat.state")
local layouts, active, next_id = {}, nil, 0
local next_snapshot = 0
local parked, tab_directory = false, nil
local function chat() return require("opencode.ui.chat") end
local function bar() return require("opencode.ui.chat.workspace_bar") end

function M.list() return layouts end
function M.current() return active end
function M.is_parked() return parked end

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
	bar().update()
end

local function release_callbacks(layout)
	if layout.callbacks then
		vim.cmd("unlet! " .. layout.callbacks)
		layout.callbacks = nil
	end
end

local function capture(node, windows, callbacks)
	if node[1] ~= "leaf" then
		local children = {}
		for _, child in ipairs(node[2]) do
			local saved = capture(child, windows, callbacks)
			if saved then children[#children + 1] = saved end
		end
		if #children == 1 then return children[1] end
		if #children > 0 then return { kind = node[1], children = children } end
		return
	end
	local win = node[2]
	local buf = vim.api.nvim_win_get_buf(win)
	local view = cs.for_window(win)
	if view and view.bufnr ~= buf then view = nil end
	local options = {}
	for name, info in pairs(vim.api.nvim_get_all_options_info()) do
		if info.scope == "win" then options[name] = vim.api.nvim_get_option_value(name, { win = win, scope = "local" }) end
	end
	-- Only the current list's writable state; list IDs and history belong to Neovim.
	local location = vim.fn.getloclist(win, { id = 0, items = 0, idx = 0, title = 0,
		context = 0, quickfixtextfunc = 0, filewinid = 0 })
	local location_owner = location.filewinid ~= 0 and location.filewinid or nil
	local location_callback
	if location.id == 0 or location_owner then location = nil
	else
		location.id, location.filewinid = nil, nil
		-- Lua cannot hold native Funcrefs. Keep the actual reference, including bound
		-- arguments/dictionaries and anonymous functions, for this snapshot's lifetime.
		if location.quickfixtextfunc == vim.NIL then
			location_callback = callbacks .. "[" .. win .. "]"
			vim.cmd(("let %s = getloclist(%d, {'quickfixtextfunc': 0}).quickfixtextfunc"):format(location_callback, win))
			location.quickfixtextfunc = nil
		end
	end
	local leaf = { kind = "leaf", buf = buf, view = view, owned = view and view.winid == win,
		location_list = location, location_owner = location_owner, location_callback = location_callback,
		focused = win == vim.api.nvim_get_current_win(), options = options,
		directory = vim.fn.haslocaldir(win) == 1 and vim.fn.getcwd(win) or nil,
		width = vim.api.nvim_win_get_width(win), height = vim.api.nvim_win_get_height(win),
		position = vim.api.nvim_win_call(win, vim.fn.winsaveview) }
	windows[win] = leaf
	return leaf
end

local function save_layout(layout)
	next_snapshot = next_snapshot + 1
	local snapshot = { callbacks = "g:opencode_workspace_location_text[" .. next_snapshot .. "]" }
	vim.cmd("let g:opencode_workspace_location_text = get(g:, 'opencode_workspace_location_text', {})")
	vim.cmd("let " .. snapshot.callbacks .. " = {}")
	local ok, err = xpcall(function()
		local windows = {}
		snapshot.tree = capture(vim.fn.winlayout(), windows, snapshot.callbacks)
		for _, leaf in pairs(windows) do
			if leaf.location_owner then
				leaf.location_owner = assert(windows[leaf.location_owner], "Could not save location-list owner")
			end
		end
	end, debug.traceback)
	if not ok then release_callbacks(snapshot); error(err, 0) end
	release_callbacks(layout)
	layout.tree, layout.callbacks = snapshot.tree, snapshot.callbacks
end

local function suspend(save_tree, preserve_external_input)
	if not active then return end
	local input = require("opencode.ui.input")
	local close_input = not preserve_external_input
	if preserve_external_input then
		for _, win in ipairs(input.get_winids()) do
			if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == cs.workspace.tabpage then
				close_input = true
				break
			end
		end
	end
	for _, view in ipairs(members(active)) do
		if close_input then input.close_for_view(view) end
		local details = package.loaded["opencode.ui.chat.execute_details"]
		if details then cs.module(view, details).close(false) end
		local edits = package.loaded["opencode.ui.chat.edits"]
		if edits then
			local _, err = cs.module(view, edits).close_inline_diff_split({ preserve_actual = true })
			if err then error(err, 0) end
		end
	end
	if save_tree ~= false and not active.incomplete then save_layout(active) end
	local keep
	-- Reuse a normal pane: even a valid layout may have no room for an extra anchor.
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(cs.workspace.tabpage)) do
		if vim.api.nvim_win_get_config(win).relative == "" and vim.fn.getwininfo(win)[1].loclist == 0 then
			keep = win
			break
		end
	end
	assert(keep, "Could not retain a workspace anchor")
	cs.workspace.anchor = keep
	local buffers = {}
	active.incomplete = true
	local ok, err = xpcall(function()
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(cs.workspace.tabpage)) do
			local buf = vim.api.nvim_win_get_buf(win)
			if buffers[buf] == nil then buffers[buf] = vim.bo[buf].bufhidden end
			vim.bo[buf].bufhidden = "hide"
		end
		for _, view in ipairs(members(active)) do
			view.visible, view.suspended, view.winid = false, true, nil
		end
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(cs.workspace.tabpage)) do
			-- Closing a popup layer can synchronously close its sibling windows.
			if win ~= keep and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
		end
	end, debug.traceback)
	for buf, hidden in pairs(buffers) do
		if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].bufhidden = hidden end
	end
	if not ok then error(err, 0) end
end

local function preserve_buffer(win, run)
	local buf = vim.api.nvim_win_get_buf(win)
	local hidden = vim.bo[buf].bufhidden
	local ok, err = pcall(function()
		vim.bo[buf].bufhidden = "hide"
		run()
	end)
	if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].bufhidden = hidden end
	if not ok then error(err, 0) end
end

local function restore_directory(tree, win)
	-- win_call changes window context without switching its working directory.
	vim.api.nvim_set_current_win(win)
	if tree.directory then
		vim.cmd.lcd({ args = { tree.directory }, mods = { noautocmd = true } })
	elseif vim.fn.haslocaldir() == 1 then
		local command = vim.fn.haslocaldir(-1) == 1 and "tcd" or "cd"
		vim.cmd[command]({ args = { vim.fn.getcwd(-1) }, mods = { noautocmd = true } })
	end
end

local function collect(tree, leaves)
	if tree.kind == "leaf" then
		leaves[#leaves + 1] = tree
		return
	end
	for _, child in ipairs(tree.children) do collect(child, leaves) end
end

local function prepare_windows(leaves, anchor)
	local floating = { relative = "editor", row = 0, col = 0, width = 1, height = 1 }
	local anchored = false
	for _, leaf in ipairs(leaves) do
		if not leaf.location_owner then
			if not vim.api.nvim_buf_is_valid(leaf.buf) then leaf.buf = vim.api.nvim_create_buf(false, true) end
			if not anchored then
				leaf.win = anchor
				preserve_buffer(anchor, function() vim.api.nvim_win_set_buf(anchor, leaf.buf) end)
				anchored = true
			else leaf.win = vim.api.nvim_open_win(leaf.buf, false, floating) end
			restore_directory(leaf, leaf.win)
			-- Native splits copy their source window's list, even into unrelated panes.
			vim.fn.setloclist(leaf.win, {}, "f")
			if leaf.location_list then
				assert(vim.fn.setloclist(leaf.win, {}, "r", leaf.location_list) == 0, "Could not restore location list")
			end
			if leaf.location_callback then
				assert(vim.fn.eval(("setloclist(%d, [], 'a', {'quickfixtextfunc': %s})"):format(leaf.win, leaf.location_callback)) == 0,
					"Could not restore location-list callback")
			end
		end
	end
	for _, leaf in ipairs(leaves) do
		if leaf.location_owner then
			local owner = assert(leaf.location_owner.win, "Could not restore location-list owner")
			-- Create native list windows before filling the saved slots, never an N+1 pane.
			vim.api.nvim_win_call(owner, function()
				local opened, err = pcall(vim.cmd, "botright 1lopen")
				if not opened then
					if not tostring(err):find("Vim(lopen):E36", 1, true) or vim.fn.getloclist(owner, { winid = 0 }).winid ~= 0 then
						error(err, 0)
					end
					-- A valid vertical layout can have only one screen row available.
					vim.cmd("vertical botright 1lopen")
				end
			end)
			local win = vim.fn.getloclist(owner, { winid = 0 }).winid
			assert(win ~= 0, "Could not open location-list window")
			vim.api.nvim_win_set_config(win, floating)
			leaf.win, leaf.buf = win, vim.api.nvim_win_get_buf(win)
			restore_directory(leaf, win)
		end
	end
end

local function representatives(tree, anchor)
	if tree.kind == "leaf" then return tree.win end
	tree.win = nil
	for _, child in ipairs(tree.children) do
		local win = representatives(child, anchor)
		if not tree.win or win == anchor then tree.win = win end
	end
	return tree.win
end

local function restore(tree)
	if tree.kind == "leaf" then return end
	local pivot
	for i, child in ipairs(tree.children) do if child.win == tree.win then pivot = i; break end end
	local function place(i, split)
		vim.api.nvim_win_set_config(tree.children[i].win, { split = split, win = tree.win })
	end
	for i = 1, pivot - 1 do place(i, tree.kind == "row" and "left" or "above") end
	for i = #tree.children, pivot + 1, -1 do place(i, tree.kind == "row" and "right" or "below") end
	for _, child in ipairs(tree.children) do restore(child) end
end

local function show(layout)
	active, layout.incomplete = layout, true
	local anchor = assert(cs.workspace.anchor, "Could not restore workspace anchor")
	cs.workspace.anchor = nil
	local leaves = {}
	collect(layout.tree, leaves)
	for _, view in ipairs(members(layout)) do chat().for_view(view).create() end
	prepare_windows(leaves, anchor)
	representatives(layout.tree, anchor)
	restore(layout.tree)
	for _, leaf in ipairs(leaves) do
		if leaf.view and cs.valid(leaf.view) then
			leaf.view.suspended = nil
			if leaf.owned or not leaf.view.winid then chat().for_view(leaf.view).attach_window(leaf.win) end
		end
	end
	for _, leaf in ipairs(leaves) do
		restore_directory(leaf, leaf.win)
		for name, value in pairs(leaf.options or {}) do
			if name ~= "scroll" then vim.api.nvim_set_option_value(name, value, { win = leaf.win, scope = "local" }) end
		end
		if leaf.focused then layout.focus_win = leaf.win end
	end
	if layout.last_view and layout.last_view.visible and not layout.last_view.suspended then
		chat().focus_view(layout.last_view)
	end
	if layout.focus_win and vim.api.nvim_win_is_valid(layout.focus_win) then
		vim.api.nvim_set_current_win(layout.focus_win)
	end
	bar().update()
	-- Focusing a narrow pane can enlarge it to 'winwidth'; size only after all focus hops.
	for _, leaf in ipairs(leaves) do
		vim.api.nvim_win_set_width(leaf.win, leaf.width)
		vim.api.nvim_win_set_height(leaf.win, leaf.height)
	end
	for _, leaf in ipairs(leaves) do
		if leaf.options and leaf.options.scroll then
			vim.wo[leaf.win].scroll = math.min(leaf.options.scroll, vim.api.nvim_win_get_height(leaf.win))
		end
		vim.api.nvim_win_call(leaf.win, function() vim.fn.winrestview(leaf.position) end)
	end
	layout.incomplete = nil
end

local function with_switching(run)
	local switching = cs.workspace.switching
	cs.workspace.switching = true
	local ok, err = xpcall(run, debug.traceback)
	cs.workspace.switching = switching
	if not ok then error(err, 0) end
end

local function transition(run)
	local previous = active
	local switching = cs.workspace.switching
	cs.workspace.switching = true
	local ok, err = xpcall(run, debug.traceback)
	if not ok and previous and (active ~= previous or previous.incomplete) then
		local restored, restore_error = xpcall(function()
			-- A partial restore must never replace either saved layout tree.
			suspend(false)
			show(previous)
		end, debug.traceback)
		if not restored then err = err .. "\nCould not restore previous layout: " .. restore_error end
	end
	cs.workspace.switching = switching
	return ok, err
end

local function leave_workspace()
	if vim.api.nvim_get_current_tabpage() ~= cs.workspace.tabpage then return end
	local window = cs.workspace.return_winid
	if window and vim.api.nvim_win_is_valid(window)
		and vim.api.nvim_win_get_tabpage(window) ~= cs.workspace.tabpage then
		vim.api.nvim_set_current_win(window)
		return
	end
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		if tab ~= cs.workspace.tabpage then vim.api.nvim_set_current_tabpage(tab); return end
	end
	vim.cmd("tabnew")
	cs.workspace.return_winid = vim.api.nvim_get_current_win()
end

local function close_anchor()
	local anchor = cs.workspace.anchor
	if anchor and vim.api.nvim_win_is_valid(anchor) then
		preserve_buffer(anchor, function() vim.api.nvim_win_close(anchor, true) end)
	end
end

local function mark_parked()
	parked = true
	cs.workspace.tabpage, cs.workspace.anchor = nil, nil
	for _, layout in ipairs(layouts) do
		for _, view in ipairs(members(layout)) do view.tabpage = nil end
	end
	bar().remove()
end

function M.park()
	if parked then return true end
	local tab = cs.workspace.tabpage
	if not active or not tab or not vim.api.nvim_tabpage_is_valid(tab) then return false end
	local ok, err = pcall(with_switching, function()
		leave_workspace()
		local window = vim.api.nvim_tabpage_get_win(tab)
		vim.api.nvim_win_call(window, function()
			local number = vim.api.nvim_tabpage_get_number(tab)
			-- Native copies retain Funcrefs; the original t: dictionary is cleared on close.
			vim.cmd("let g:opencode_workspace_tabvars = copy(gettabvar(" .. number .. ", ''))")
			tab_directory = vim.fn.haslocaldir(-1, number) == 1 and vim.fn.getcwd(-1, number) or nil
			suspend(nil, true)
		end)
		close_anchor()
	end)
	if not vim.api.nvim_tabpage_is_valid(tab) then
		-- A closing autocmd may report an error after the native tab has gone.
		mark_parked()
	elseif not ok and active.incomplete then
		local window = vim.api.nvim_get_current_win()
		local restored, restore_error = pcall(with_switching, function()
			vim.api.nvim_set_current_tabpage(tab)
			suspend(false)
			show(active)
		end)
		if vim.api.nvim_win_is_valid(window) then
			with_switching(function() vim.api.nvim_set_current_win(window) end)
		end
		if not restored then err = err .. "\nCould not restore workspace: " .. restore_error end
	end
	if not ok then error(err, 0) end
	return parked
end

function M.resume()
	if not active then return false end
	if not parked then
		if not cs.workspace.tabpage or not vim.api.nvim_tabpage_is_valid(cs.workspace.tabpage) then return false end
		vim.api.nvim_set_current_tabpage(cs.workspace.tabpage)
		if active.incomplete then
			local ok, err = transition(function() suspend(false); show(active) end)
			if not ok then error(err, 0) end
		end
		bar().update()
		return true
	end
	local editor = vim.api.nvim_get_current_win()
	cs.workspace.return_winid = editor
	local ok, err = pcall(with_switching, function()
		local previous = vim.api.nvim_list_tabpages()
		local created, create_error = pcall(vim.cmd, "tabnew")
		local added = vim.tbl_filter(function(tab) return not vim.tbl_contains(previous, tab) end, vim.api.nvim_list_tabpages())
		if #added == 1 then
			cs.workspace.tabpage = added[1]
			cs.workspace.anchor = vim.api.nvim_tabpage_get_win(added[1])
			parked = false
		end
		if not created then error(create_error, 0) end
		assert(#added == 1 and vim.api.nvim_get_current_tabpage() == added[1], "OpenCode tab creation changed focus")
		vim.cmd("call extend(t:, get(g:, 'opencode_workspace_tabvars', {}), 'force')")
		if tab_directory then vim.cmd.tcd({ args = { tab_directory }, mods = { noautocmd = true } })
		else vim.cmd.cd({ args = { vim.fn.getcwd(-1, -1) }, mods = { noautocmd = true } }) end
		bar().update()
		show(active)
	end)
	if not ok then
		local tab = cs.workspace.tabpage
		local restored, restore_error = pcall(with_switching, function()
			if tab and vim.api.nvim_tabpage_is_valid(tab) then
				vim.api.nvim_win_call(vim.api.nvim_tabpage_get_win(tab), function() suspend(false) end)
				if vim.api.nvim_win_is_valid(editor) then vim.api.nvim_set_current_win(editor) end
				close_anchor()
			end
		end)
		if not tab or not vim.api.nvim_tabpage_is_valid(tab) then mark_parked() end
		if vim.api.nvim_win_is_valid(editor) then
			with_switching(function() vim.api.nvim_set_current_win(editor) end)
		end
		if not restored then err = err .. "\nCould not retain parked workspace: " .. restore_error end
		error(err, 0)
	end
	return true
end

function M.select(id)
	local target
	for _, layout in ipairs(layouts) do if layout.id == id then target = layout; break end end
	if not target then return false end
	if parked then M.resume() end
	local suspended = false
	for _, view in ipairs(members(target)) do if view.suspended then suspended = true; break end end
	if target == active and not target.incomplete and not suspended then
		if target.last_view then chat().focus_view(target.last_view) end
		return true
	end
	vim.api.nvim_set_current_tabpage(cs.workspace.tabpage)
	local ok, err = transition(function() suspend(); show(target) end)
	if not ok then error(err) end
	return true
end

function M.create(session)
	local existing = cs.for_session(session.id)
	if existing then chat().focus_view(existing); return existing end
	if parked then M.resume()
	elseif active and cs.workspace.tabpage and vim.api.nvim_tabpage_is_valid(cs.workspace.tabpage) then
		vim.api.nvim_set_current_tabpage(cs.workspace.tabpage)
	else
		chat().open()
	end
	local view, created
	local previous_layout = active
	local previous = previous_layout and previous_layout.last_view
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
		local cleaned, cleanup_error = xpcall(function()
			if view then
				local owned = view.modules and view.modules.init
				if owned then owned.dispose()
				else
					for _, mod in pairs(view.modules or {}) do if mod.dispose then mod.dispose() end end
				end
				view.suspended, view.workspace_id = nil, nil
				cs.remove(view)
			end
			for index, layout in ipairs(layouts) do
				if layout == created then
					release_callbacks(layout)
					table.remove(layouts, index)
					if active == created then active = previous_layout end
					break
				end
			end
		end, debug.traceback)
		if not cleaned then err = err .. "\nCould not dispose failed layout: " .. cleanup_error end
	end
	bar().update()
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

local function retained(view, layout)
	return cs.valid(view) and view.workspace_id == layout.id and (view.visible or view.suspended)
end

local function prune(tree, layout, owners)
	if not tree then return end
	if not owners then
		local leaves = {}
		collect(tree, leaves)
		owners = {}
		for _, leaf in ipairs(leaves) do
			if not leaf.view or retained(leaf.view, layout) then owners[leaf] = true end
		end
	end
	if tree.kind == "leaf" then
		if tree.location_owner and not owners[tree.location_owner] then return end
		if not tree.view or retained(tree.view, layout) then return tree end
		if tree.location_callback then vim.cmd("unlet! " .. tree.location_callback) end
		return
	end
	local children = {}
	for _, child in ipairs(tree.children) do
		local saved = prune(child, layout, owners)
		if saved then children[#children + 1] = saved end
	end
	if #children == 1 then return children[1] end
	if #children > 1 then tree.children = children; return tree end
end

local function reconcile_layouts()
	for i = #layouts, 1, -1 do
		local layout = layouts[i]
		local remaining = vim.tbl_filter(function(view) return view.visible or view.suspended end, members(layout))
		local saved = parked or layout ~= active or layout.incomplete
		if saved then layout.tree = prune(layout.tree, layout) end
		local has_files = saved and layout.tree ~= nil
		if not saved and cs.workspace.tabpage and vim.api.nvim_tabpage_is_valid(cs.workspace.tabpage) then
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(cs.workspace.tabpage)) do
				if vim.api.nvim_win_get_config(win).relative == "" then has_files = true; break end
			end
		end
		if #remaining == 0 and not has_files then
			for _, view in ipairs(members(layout)) do view.workspace_id = nil end
			release_callbacks(layout)
			table.remove(layouts, i)
			if active == layout then active = nil end
		elseif not retained(layout.last_view, layout) then
			layout.last_view = remaining[1]
		end
		if not retained(layout.root_view, layout) then
			layout.root_view = remaining[1]
			if remaining[1] then layout.session_id = cs.session(remaining[1]).id end
		end
	end
end

function M.reset()
	local ok, err = pcall(with_switching, function()
		for _, layout in ipairs(layouts) do
			for _, view in ipairs(members(layout)) do
				if view.suspended then
					chat().for_view(view).dispose()
					view.suspended, view.workspace_id = nil, nil
					cs.remove(view)
				end
			end
		end
		-- Visible views are only detached once all fallible hidden-view disposal succeeds.
		for _, layout in ipairs(layouts) do
			for _, view in ipairs(members(layout)) do view.workspace_id = nil end
			release_callbacks(layout)
		end
		layouts, active = {}, nil
		parked, tab_directory = false, nil
		vim.cmd("unlet! g:opencode_workspace_tabvars")
		bar().remove()
	end)
	if not ok then reconcile_layouts(); error(err, 0) end
end

function M.after_close()
	if cs.workspace.switching then return end
	if cs.workspace.tabpage and not vim.api.nvim_tabpage_is_valid(cs.workspace.tabpage) then
		M.reset()
		cs.workspace.tabpage = nil
		return
	end
	reconcile_layouts()
	if parked then
		active = active or layouts[1]
		if not active then M.reset() end
		return
	end
	if not active and #layouts > 0 then M.select(layouts[1].id)
	elseif #layouts == 0 then
		local ok, err = pcall(function()
			local keep = cs.workspace.anchor
			if keep and vim.api.nvim_win_is_valid(keep) and #vim.api.nvim_list_tabpages() == 1 then vim.cmd("tabnew") end
			bar().remove()
			if cs.workspace.anchor and vim.api.nvim_win_is_valid(cs.workspace.anchor) then
				preserve_buffer(cs.workspace.anchor, function() vim.api.nvim_win_close(cs.workspace.anchor, true) end)
			end
		end)
		-- WinClosed can report an error after the anchor/tab has already gone.
		if cs.workspace.anchor and not vim.api.nvim_win_is_valid(cs.workspace.anchor) then cs.workspace.anchor = nil end
		if cs.workspace.tabpage and not vim.api.nvim_tabpage_is_valid(cs.workspace.tabpage) then cs.workspace.tabpage = nil end
		if not ok then error(err, 0) end
		cs.workspace.anchor, cs.workspace.tabpage = nil, nil
		tab_directory = nil
		vim.cmd("unlet! g:opencode_workspace_tabvars")
	else bar().update() end
end

function M.close_current()
	if not active then return end
	local closing, replacement = active, nil
	for i, layout in ipairs(layouts) do
		if layout == closing then replacement = layouts[i > 1 and i - 1 or 2]; break end
	end
	local ids = closing.closing_ids or {}
	closing.closing_ids = ids
	local ok, err = pcall(with_switching, function()
		-- Prepare the replacement while the closing views can still be restored intact.
		if not parked then
			local prepared, prepare_error = transition(function()
				suspend()
				if replacement then show(replacement) end
			end)
			if not prepared then error(prepare_error, 0) end
		end
		for _, view in ipairs(members(closing)) do
			local root = (view.session_stack or {})[1]
			local id = root and root.id or cs.session(view).id
			chat().for_view(view).dispose()
			if id then ids[id] = true end
			view.suspended, view.workspace_id = nil, nil
			cs.remove(view)
		end
		for i, layout in ipairs(layouts) do
			if layout == closing then
				release_callbacks(layout)
				table.remove(layouts, i)
				break
			end
		end
		if active == closing then active = parked and replacement or nil end
	end)
	if not ok then
		-- Successful disposals stay committed; failed members remain attached and retryable.
		reconcile_layouts()
		bar().update()
		error(err, 0)
	end
	for id in pairs(ids) do require("opencode.actions").close_session({ session_id = id, silent = true }) end
	M.after_close()
end

function M.session_changed(view, session)
	for _, layout in ipairs(layouts) do
		if layout.root_view == view then layout.session_id = ((view.session_stack or {})[1] or session).id end
	end
	bar().update()
end

local group = vim.api.nvim_create_augroup("OpenCodeWorkspace", { clear = true })
vim.api.nvim_create_autocmd("TabLeave", { group = group, callback = function()
	local tab = cs.workspace.tabpage
	if cs.workspace.switching or parked or tab ~= vim.api.nvim_get_current_tabpage() then return end
	vim.schedule(function()
		if cs.workspace.switching or parked or cs.workspace.tabpage ~= tab
			or not vim.api.nvim_tabpage_is_valid(tab) or vim.api.nvim_get_current_tabpage() == tab then return end
		local ok, err = pcall(M.park)
		if not ok then vim.notify("Could not hide OpenCode workspace: " .. tostring(err), vim.log.levels.ERROR) end
	end)
end })
vim.api.nvim_create_autocmd("TabClosed", { group = group, callback = function()
	local tab = cs.workspace.tabpage
	if cs.workspace.switching or parked or not tab then return end
	vim.schedule(function()
		if not cs.workspace.switching and not parked and cs.workspace.tabpage == tab
			and not vim.api.nvim_tabpage_is_valid(tab) then chat().after_close() end
	end)
end })

return M
