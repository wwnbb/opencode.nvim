-- Read-only VCS/turn patches, independent of edit proposals and review RPC.
local M = {}
local keymaps = require("opencode.util.keymap")
local actions, app = require("opencode.actions"), require("opencode.state")
local patch = require("opencode.vcs")
local active, serial = nil, 0
local ns = vim.api.nvim_create_namespace("opencode_vcs")
local sources = {
	{ value = "branch", label = "All", description = "Branch commits and local changes" },
	{ value = "committed", label = "Committed", description = "Branch commits only" },
	{ value = "working", label = "Uncommitted", description = "Working copy vs HEAD" },
	{ value = "turn", label = "Last turn", description = "Latest session turn" },
}

require("opencode.ui.highlights").register("opencode.ui.vcs", function()
	for name, link in pairs({ Added = "DiffAdd", Deleted = "DiffDelete", Header = "Title", Current = "PmenuSel", Reviewed = "Comment" }) do
		vim.api.nvim_set_hl(0, "OpenCodeVCS" .. name, { link = link, default = true })
	end
end)

local function current(view)
	return active == view and require("opencode.session.pending").is_current(view.token)
		and app.get_session().id == view.session_id
		and (app.get_session_directory(view.session_id) or vim.fn.getcwd()) == view.directory
end

local function write(buf, lines, marks)
	vim.bo[buf].readonly, vim.bo[buf].modifiable = false, true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, #lines > 0 and lines or { "" })
	vim.bo[buf].modified, vim.bo[buf].modifiable, vim.bo[buf].readonly = false, false, true
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, mark in ipairs(marks or {}) do
		vim.api.nvim_buf_set_extmark(buf, ns, mark.row - 1, 0, { line_hl_group = mark.group, hl_eol = true })
	end
end

local function close(view)
	if not view or view.closed then return end
	view.closed = true
	if active == view then active = nil end
	if view.group then vim.api.nvim_del_augroup_by_id(view.group) end
	for _, win in pairs({ view.before_win, view.after_win, view.tree_win }) do
		if win and vim.api.nvim_win_is_valid(win) then
			local buf = vim.api.nvim_win_get_buf(win)
			if view.buffers[buf] then pcall(vim.api.nvim_win_close, win, true) end
		end
	end
	for buf in pairs(view.buffers) do if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end end
	if view.origin and vim.api.nvim_win_is_valid(view.origin) then vim.api.nvim_set_current_win(view.origin) end
end

function M.close() close(active) end

local function selected(view)
	local win = vim.api.nvim_get_current_win()
	local row = vim.api.nvim_win_get_cursor(win)[1]
	if win == view.tree_win then
		local entry = view.tree_rows[row]
		return entry and entry.index or view.index
	end
	return view.file_rows[row] or view.index
end

local render, load, choose_source, choose_base

local function reveal(view)
	vim.api.nvim_set_current_win(view.after_win)
	if view.all then
		for row, index in ipairs(view.file_rows) do if index == view.index then vim.api.nvim_win_set_cursor(view.after_win, { row, 0 }); break end end
	end
end

local function map_buffer(view, buf)
	local bind, apply = keymaps.mapper("vcs", buf)
	local function map(action, callback)
		bind("n", action, function() if active == view and not view.closed then callback() end end)
	end
	map("close", function() close(view) end)
	map("source", function() choose_source(view) end)
	map("base", function() choose_base(view) end)
	map("refresh", function() load(view) end)
	map("layout", function() view.auto_layout = false; view.layout = view.layout == "split" and "unified" or "split"; render(view) end)
	map("all", function() view.all = not view.all; render(view) end)
	map("tree", function() view.flat = not view.flat; render(view) end)
	map("reviewed", function()
		if vim.api.nvim_get_current_win() == view.tree_win then
			local entry = view.tree_rows[vim.api.nvim_win_get_cursor(view.tree_win)[1]]
			if not entry or not entry.index then return end
		end
		local file = view.files[selected(view)]
		if not file then return end
		if view.reviewed[file.file] == file.patch then view.reviewed[file.file] = nil else view.reviewed[file.file] = file.patch end
		render(view)
	end)
	map("select", function()
		local entry = vim.api.nvim_get_current_win() == view.tree_win and view.tree_rows[vim.api.nvim_win_get_cursor(view.tree_win)[1]]
		if entry and entry.directory then view.collapsed[entry.directory] = not view.collapsed[entry.directory]; render(view); return end
		view.index = selected(view)
		render(view)
		reveal(view)
	end)
	for key, direction in pairs({ next_file = 1, prev_file = -1 }) do
		map(key, function()
			if #view.files == 0 then return end
			view.index = ((selected(view) - 1 + direction) % #view.files) + 1
			render(view)
			reveal(view)
		end)
	end
	for key, direction in pairs({ next_hunk = 1, prev_hunk = -1 }) do
		map(key, function()
			local win = vim.api.nvim_get_current_win() == view.before_win and view.before_win or view.after_win
			local row = vim.api.nvim_win_get_cursor(win)[1]
			for _ = 1, vim.v.count1 do
				local target
				for _, hunk in ipairs(view.hunks) do
					if direction == 1 and hunk > row then target = hunk; break end
					if direction == -1 and hunk < row then target = hunk end
				end
				if not target then break end
				row = target
			end
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(win, { row, 0 })
		end)
	end
	map("help", function()
		local hints = {}
		for _, action in ipairs({ "source", "base", "tree", "select", "all", "layout", "next_file", "prev_file", "next_hunk", "prev_hunk", "reviewed", "refresh", "close" }) do
			hints[#hints + 1] = keymaps.label("vcs", action) .. " " .. action:gsub("_", " ")
		end
		vim.notify("VCS diff: " .. table.concat(hints, ", "), vim.log.levels.INFO)
	end)
	apply()
end

local function buffer(view, kind)
	local buf = vim.api.nvim_create_buf(false, true)
	view.buffers[buf] = true
	vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].modifiable = "wipe", false, false
	vim.bo[buf].readonly = true
	vim.api.nvim_buf_set_name(buf, "OpenCode VCS " .. serial .. " " .. kind)
	map_buffer(view, buf)
	return buf
end

render = function(view)
	if active ~= view or view.closed or not vim.api.nvim_win_is_valid(view.after_win) then return end
	local focused = vim.api.nvim_get_current_win()
	view.relayout = true
	if view.layout == "split" and not (view.before_win and vim.api.nvim_win_is_valid(view.before_win)) then
		vim.api.nvim_set_current_win(view.after_win)
		vim.cmd("leftabove vsplit")
		view.before_win = vim.api.nvim_get_current_win()
		view.before_buf = buffer(view, "before")
		vim.api.nvim_win_set_buf(view.before_win, view.before_buf)
	elseif view.layout ~= "split" and view.before_win then
		if vim.api.nvim_win_is_valid(view.before_win) then vim.api.nvim_win_close(view.before_win, true) end
		view.before_win, view.before_buf = nil, nil
	end
	local tree_lines, tree_marks, directories = {}, {}, {}
	view.tree_rows = {}
	for index, file in ipairs(view.files) do
		local pieces = vim.split(file.file, "/", { plain = true })
		local path, hidden = "", false
		if not view.flat then
			for depth = 1, #pieces - 1 do
				path = path == "" and pieces[depth] or path .. "/" .. pieces[depth]
				if not directories[path] then
					directories[path] = true
					if not hidden then
						tree_lines[#tree_lines + 1] = string.rep("  ", depth - 1) .. (view.collapsed[path] and "▸ " or "▾ ") .. pieces[depth] .. "/"
						view.tree_rows[#tree_lines] = { directory = path }
					end
				end
				hidden = hidden or view.collapsed[path] == true
			end
		end
		if not hidden then
			local reviewed = view.reviewed[file.file] == file.patch
			tree_lines[#tree_lines + 1] = (view.flat and "" or string.rep("  ", #pieces - 1)) .. (reviewed and "✓ " or "  ") .. (view.flat and file.file or pieces[#pieces])
			view.tree_rows[#tree_lines] = { index = index }
			tree_marks[#tree_marks + 1] = { row = #tree_lines, group = "OpenCodeVCS" .. (index == view.index and "Current" or reviewed and "Reviewed" or "Header") }
		end
	end
	write(view.tree_buf, tree_lines, tree_marks)
	local before, after, before_marks, after_marks = {}, {}, {}, {}
	view.file_rows, view.hunks = {}, {}
	for index, file in ipairs(view.files) do
		if view.all or index == view.index then
			local header = string.format("%s %s  +%d -%d", view.reviewed[file.file] == file.patch and "✓" or "○", file.file, file.additions, file.deletions)
			before[#before + 1], after[#after + 1] = header, header
			before_marks[#before_marks + 1] = { row = #before, group = "OpenCodeVCSHeader" }
			after_marks[#after_marks + 1] = { row = #after, group = "OpenCodeVCSHeader" }
			view.file_rows[#after] = index
			if view.layout == "split" then
				if not file.projection or file.projection.patch ~= file.patch then
					local rows, err = patch.project(file.patch)
					if not rows then rows = { { before = err .. "; use unified view", after = err .. "; use unified view", kind = "meta" } } end
					file.projection = { patch = file.patch, rows = rows }
				end
				local rows = file.projection.rows
				for _, row in ipairs(rows) do
					before[#before + 1] = row.before_line and string.format("%6d %s %s", row.before_line, row.kind == "change" and "-" or " ", row.before) or row.before
					after[#after + 1] = row.after_line and string.format("%6d %s %s", row.after_line, row.kind == "change" and "+" or " ", row.after) or row.after
					view.file_rows[#after] = index
					if row.hunk then view.hunks[#view.hunks + 1] = #after end
					if row.kind == "change" then
						if row.before_line then before_marks[#before_marks + 1] = { row = #before, group = "OpenCodeVCSDeleted" } end
						if row.after_line then after_marks[#after_marks + 1] = { row = #after, group = "OpenCodeVCSAdded" } end
					end
				end
			else
				for _, line in ipairs(file.patch == "" and { "No textual patch" } or vim.split(file.patch, "\n", { plain = true })) do
					after[#after + 1] = line
					view.file_rows[#after] = index
					if line:match("^@@ ") then view.hunks[#view.hunks + 1] = #after end
				end
			end
			before[#before + 1], after[#after + 1] = "", ""
			view.file_rows[#after] = index
		end
	end
	if #after == 0 then after, before = { view.error or "No changed files" }, { view.error or "No changed files" } end
	write(view.after_buf, after, after_marks)
	vim.bo[view.after_buf].filetype = view.layout == "unified" and "diff" or "text"
	if view.before_buf then write(view.before_buf, before, before_marks) end
	local reviewed = 0
	for _, file in ipairs(view.files) do if view.reviewed[file.file] == file.patch then reviewed = reviewed + 1 end end
	local title = string.format(" %s · %s · %d/%d reviewed · %s · ? help", view.mode, view.base or view.resolved_base or "automatic base", reviewed, #view.files, view.all and "all files" or "single file")
	for _, win in ipairs({ view.after_win, view.before_win }) do
		if win and vim.api.nvim_win_is_valid(win) then
			vim.wo[win].winbar = title:gsub("%%", "%%%%")
			vim.wo[win].scrollbind, vim.wo[win].cursorbind, vim.wo[win].wrap = view.layout == "split", view.layout == "split", false
		end
	end
	pcall(vim.api.nvim_win_set_width, view.tree_win, math.max(16, math.min(34, math.floor(vim.o.columns / 4))))
	view.relayout = false
	if vim.api.nvim_win_is_valid(focused) then vim.api.nvim_set_current_win(focused)
	elseif vim.api.nvim_win_is_valid(view.after_win) then vim.api.nvim_set_current_win(view.after_win) end
end

load = function(view)
	if not current(view) then return end
	view.request = view.request + 1
	local request = view.request
	view.error = "Loading diff…"
	render(view)
	local function done(err, files)
		if not current(view) or request ~= view.request then return end
		local invalid
		if not err then files, invalid = patch.files(files) end
		view.error = err and require("opencode.events.util").format_session_error(err) or invalid
		if err and (err.status == 404 or err.status == 405 or err.status == 501 or err.status == 503) then
			view.error = (view.mode == "turn" and "Session diff is unavailable" or "This server does not provide the requested diff endpoint")
				.. (err.message and (": " .. err.message) or "")
		end
		view.files = not err and files or {}
		table.sort(view.files, function(a, b) return a.file < b.file end)
		view.index = math.max(1, math.min(view.index, #view.files))
		render(view)
	end
	if view.mode == "turn" then
		if not view.session_id then done({ message = "Select a session to inspect its last turn" }); return end
		actions.get_diff(view.session_id, { context = 12 }, done)
		return
	end
	local function diff(base)
		if not current(view) or request ~= view.request then return end
		view.resolved_base = base
		actions.get_vcs_diff({ directory = view.directory, mode = view.mode, base = base, context = 12 }, done)
	end
	if view.mode == "working" then diff(); return end
	if view.base then diff(view.base); return end
	actions.get_vcs_base({ directory = view.directory }, function(err, base)
		if not current(view) or request ~= view.request then return end
		if not err and type(base) == "table" and type(base.ref) == "string" then diff(base.ref)
		elseif view.mode == "committed" then done({ message = "No review base reported. Choose a branch with b." })
		else diff() end
	end)
end

choose_source = function(view)
	if not current(view) then return end
	local items = {}
	for _, source in ipairs(sources) do if source.value ~= "turn" or view.session_id then items[#items + 1] = vim.deepcopy(source) end end
	require("opencode.ui.menu").open({ items = items, title = " Diff Source ", sort = false, refocus_chat = false,
		on_select = function(item)
			if not current(view) then return end
			view.mode, view.files, view.reviewed = item.value, {}, {}
			load(view)
		end,
	})
end

choose_base = function(view)
	if not current(view) then return end
	actions.list_vcs_branches({ directory = view.directory }, function(err, branches)
		if not current(view) then return end
		local items = { { label = "Automatic review base", value = "auto" }, { label = "Enter branch or ref…", value = "custom" } }
		if not err then
			for _, name in ipairs(branches or {}) do if type(name) == "string" then items[#items + 1] = { label = name, value = "branch", ref = name } end end
		end
		local function select(ref)
			if not current(view) then return end
			view.base, view.files, view.reviewed = ref, {}, {}
			load(view)
		end
		require("opencode.ui.menu").open({ items = items, title = " Diff Base ", searchable = true, sort = false, refocus_chat = false,
			message = err and "Branch list unavailable; enter a ref directly" or nil,
			on_select = function(item)
				if not current(view) then return end
				if item.value == "custom" then
					require("opencode.ui.float").create_input_popup({ title = " Diff Base ", prompt = "Branch or ref:", on_submit = function(value)
						value = vim.trim(value or "")
						if value ~= "" then select(value) end
					end })
				else select(item.ref) end
			end,
		})
	end)
end

function M.open(opts)
	opts = opts or {}
	M.close()
	serial = serial + 1
	local session_id = app.get_session().id
	local preference = (app.get_config().chat or {}).diff_view or "auto"
	local view = { session_id = session_id, directory = app.get_session_directory(session_id) or vim.fn.getcwd(),
		token = require("opencode.session.pending").token(session_id), origin = vim.api.nvim_get_current_win(),
		mode = opts.mode or "branch", base = opts.base, auto_layout = preference == "auto", layout = preference == "auto" and (vim.o.columns >= 120 and "split" or "unified") or preference,
		index = 1, files = {}, buffers = {}, reviewed = {}, collapsed = {}, all = true, request = 0 }
	active = view
	vim.cmd("tabnew")
	view.tab, view.tree_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
	local initial_buf = vim.api.nvim_get_current_buf()
	view.tree_buf = buffer(view, "tree")
	vim.api.nvim_win_set_buf(view.tree_win, view.tree_buf)
	if vim.api.nvim_buf_is_valid(initial_buf) and not vim.bo[initial_buf].modified then vim.api.nvim_buf_delete(initial_buf, {}) end
	vim.cmd("rightbelow vsplit")
	view.after_win = vim.api.nvim_get_current_win()
	view.after_buf = buffer(view, "after")
	vim.api.nvim_win_set_buf(view.after_win, view.after_buf)
	pcall(vim.api.nvim_win_set_width, view.tree_win, math.max(16, math.min(34, math.floor(vim.o.columns / 4))))
	view.group = vim.api.nvim_create_augroup("OpenCodeVCS" .. serial, { clear = true })
	vim.api.nvim_create_autocmd("TabClosed", { group = view.group, callback = function()
		if not vim.api.nvim_tabpage_is_valid(view.tab) then close(view) end
	end })
	vim.api.nvim_create_autocmd("WinClosed", { group = view.group, callback = function(event)
		local win = tonumber(event.match)
		if not view.relayout and (win == view.tree_win or win == view.after_win or win == view.before_win) then vim.schedule(function() close(view) end) end
	end })
	vim.api.nvim_create_autocmd("VimResized", { group = view.group, callback = function()
		if not view.auto_layout then return end
		view.layout = vim.o.columns >= 120 and "split" or "unified"
		render(view)
	end })
	load(view)
	return view
end

function M.register(palette)
	palette.register({ id = "diff.open", title = "Open Diff Viewer", description = "Browse VCS and last-turn diffs",
		category = "actions", slash = { name = "diff" }, on_select = function(context) return context.run() end,
		run = function() M.open() end })
end

return M
