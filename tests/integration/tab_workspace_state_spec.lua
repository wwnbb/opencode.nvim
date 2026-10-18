describe("tab workspace editor state", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.lua([[
			vim.o.lines, vim.o.columns = 60, 120
			function seed(id)
				local session = { id = id, title = id }
				require("opencode.session").remember(session)
				return session
			end
			function settle() vim.wait(50, function() return false end, 5) end
			function newfile(hidden)
				local buf = vim.api.nvim_create_buf(true, false)
				vim.bo[buf].bufhidden = hidden or ""
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "middle", "last" })
				return buf
			end
			function filepane(buf, command)
				vim.cmd(command or "rightbelow split")
				vim.api.nvim_win_set_buf(0, buf)
				return vim.api.nvim_get_current_win()
			end
			function locations(owner, buf)
				assert(vim.fn.setloclist(owner, {}, "r", { items = {
					{ bufnr = buf, lnum = 1, text = "first diagnostic" },
					{ bufnr = buf, lnum = 3, text = "last diagnostic" },
				}, idx = 2, title = "Workspace diagnostics" }) == 0)
			end
			function open(enabled)
				source = vim.api.nvim_get_current_buf()
				vim.api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
				vim.api.nvim_buf_set_lines(source, 0, -1, false, { "return 'workspace source'" })
				require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
					chat = { layout = "tab", session_tabs = { enabled = enabled, persist = false } } })
				require("opencode.client").get_messages = function(_, _, cb) cb(nil, {}) end
				chat = require("opencode.ui.chat")
				workspace = require("opencode.ui.chat.workspace")
				views = require("opencode.ui.chat.state")
				seed("state-a"); require("opencode.session").set_active("state-a", "A")
				chat.open(); settle()
				first, original = chat.get_view(), workspace.current().id
			end
		]])
	end)
	after_each(function() if editor then editor.close() end end)

	-- 2 headers × 3 bufhidden values × 2 modified states × 2 targets × 3 operations = 72.
	for _, enabled in ipairs({ false, true }) do
		for _, hidden in ipairs({ "hide", "wipe", "delete" }) do
			for _, modified in ipairs({ false, true }) do
				for _, location in ipairs({ false, true }) do
					for _, operation in ipairs({ "switch", "close", "recovery" }) do
						local label = ("header=%s hidden=%s modified=%s loclist=%s %s")
							:format(tostring(enabled), hidden, tostring(modified), tostring(location), operation)
						it("preserves both file-only layouts: " .. label, function()
							editor.lua([[
								local enabled, hidden, modified, location, operation = ...
								open(enabled)
								local target = newfile(hidden)
								local owner = filepane(target)
								vim.bo[target].modified = modified
								if location then locations(owner, target); vim.cmd("belowright 3lopen") end
								chat.close_view(first)
								local second = chat.create_layout(seed("matrix-b"))
								local other = workspace.current().id
								local outgoing = newfile(hidden)
								filepane(outgoing)
								vim.bo[outgoing].modified = modified
								chat.close_view(second)
								local function preserved()
									for _, buf in ipairs({ target, outgoing }) do
										assert(vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf), "file was unloaded/deleted")
										assert(vim.bo[buf].bufhidden == hidden, "bufhidden must be restored")
										assert(vim.bo[buf].modified == modified, "modified state must be retained")
										assert(vim.deep_equal({ "first", "middle", "last" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
									end
								end
								if operation == "recovery" then
									vim.api.nvim_create_autocmd("BufWinEnter", { buffer = target, once = true,
										callback = function() error("matrix BufWinEnter failure") end })
									local ok, err = pcall(workspace.select, original)
									assert(not ok and tostring(err):find("matrix BufWinEnter failure", 1, true), tostring(err))
									preserved()
									assert(workspace.current().id == other and not views.workspace.switching)
									assert(not workspace.current().incomplete, "failed switch must recover the outgoing layout")
								end
								if operation == "close" then workspace.close_current() else workspace.select(original) end
								preserved()
								assert(workspace.current().id == original and not views.workspace.switching)
								owner = vim.fn.win_findbuf(target)[1]
								assert(owner and vim.api.nvim_win_is_valid(owner))
								local list = vim.fn.getloclist(owner, { winid = 0, idx = 0 })
								assert((list.winid ~= 0) == location)
								if location then assert(list.idx == 2 and vim.api.nvim_get_current_win() == list.winid) end
								if operation ~= "close" then workspace.select(other); preserved() end
							]], { enabled, hidden, modified, location, operation })
						end)
					end
				end
			end
		end
	end

	for _, enabled in ipairs({ false, true }) do
		it("restores narrow mirrors before scroll and views without changing global minima (tabbar=" .. tostring(enabled) .. ")", function()
			editor.lua([[
				open(...)
				vim.o.winheight = 10
				local mirror = first.winid
				vim.cmd("rightbelow vsplit"); settle()
				assert(first.winid ~= mirror)
				local file = newfile("delete")
				local owner = filepane(file)
				local lines = {}
				for i = 1, 200 do lines[i] = "line " .. i end
				vim.api.nvim_buf_set_lines(file, 0, -1, false, lines)
				vim.wo[owner].scroll, vim.wo[owner].scrolloff = 9, 2
				vim.fn.winrestview({ lnum = 80, col = 2, topline = 70 })
				vim.api.nvim_win_set_width(mirror, 10)
				local position = vim.fn.winsaveview()
				local function geometry()
					local result = {}
					for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
						local buf = vim.api.nvim_win_get_buf(win)
						local role = win == first.winid and "chat" or buf == first.bufnr and "mirror"
							or buf == file and "file" or "bar"
						result[role] = { vim.api.nvim_win_get_position(win), vim.api.nvim_win_get_width(win),
							vim.api.nvim_win_get_height(win) }
					end
					return result
				end
				local expected = geometry()
				assert(expected.mirror[2] == 10 and vim.o.winwidth == 20)
				chat.create_layout(seed("narrow-b"))
				local other = workspace.current().id
				for _ = 1, 3 do
					workspace.select(original); settle()
					assert(vim.deep_equal(expected, geometry()), vim.inspect({ expected = expected, actual = geometry() }))
					assert(vim.api.nvim_get_current_buf() == file)
					assert(vim.deep_equal(position, vim.fn.winsaveview()), vim.inspect(vim.fn.winsaveview()))
					assert(vim.wo.scroll == 9 and vim.wo.scrolloff == 2)
					assert(vim.o.winwidth == 20 and vim.o.winheight == 10)
					workspace.select(other)
				end
			]], { enabled })
		end)

		for _, operation in ipairs({ "close", "reset" }) do
			for _, recovery_failure in ipairs({ false, true }) do
				it("restores hooks once after inner " .. operation .. " failure (tabbar=" .. tostring(enabled)
					.. " recovery failure=" .. tostring(recovery_failure) .. ")", function()
					editor.lua([[
						local enabled, operation, recovery_failure = ...
						open(enabled)
						local disposed = chat.create_layout(seed("hooks-disposed"))
						local survivor = chat.create_split(disposed, seed("hooks-survivor"), "vertical")
						local layout = workspace.current().id
						vim.cmd("rightbelow vsplit"); settle()
						local group = "OpenCodeChatResize_" .. survivor.id
						local hook_count = #vim.api.nvim_get_autocmds({ group = group })
						local current = chat.create_layout(seed("hooks-current"))
						if operation == "close" then workspace.select(layout) end
						local owned = chat.for_view(survivor)
						local render_state = views.module(survivor, require("opencode.ui.chat.render_state"))
						local dispose, create = render_state.dispose, owned.create
						render_state.dispose = function() error("injected inner disposal failure") end
						if recovery_failure then owned.create = function() error("injected recovery failure") end end
						local ok, err = pcall(operation == "close" and workspace.close_current or workspace.reset)
						render_state.dispose, owned.create = dispose, create
						assert(not ok and tostring(err):find("injected inner disposal failure", 1, true), tostring(err))
						if recovery_failure then assert(tostring(err):find("injected recovery failure", 1, true), tostring(err)) end
						assert(not views.workspace.switching and not views.valid(disposed) and views.valid(survivor))
						local other = workspace.current().id
						local events = require("opencode.events")
						local subscriptions
						for _ = 1, 3 do
							assert(workspace.select(layout)); settle()
							assert(not views.valid(disposed) and #views.windows(survivor) == 2)
							assert(#vim.api.nvim_get_autocmds({ group = group }) == hook_count)
							subscriptions = subscriptions or events.listener_count("chat_render")
							assert(events.listener_count("chat_render") == subscriptions)
							local calls, schedule = 0, owned.schedule_render
							owned.schedule_render = function(...) calls = calls + 1; return schedule(...) end
							events.emit("chat_render", { session_id = survivor.session_id, force = true }); settle()
							assert(calls == 1, "chat_render must reach the recovered view exactly once: " .. calls)
							calls = 0
							vim.api.nvim_exec_autocmds("VimResized", {}); settle()
							assert(calls == 1, "resize must reach the recovered view exactly once: " .. calls)
							owned.schedule_render = schedule
							workspace.select(other); settle()
						end
						if operation == "close" then workspace.select(layout); workspace.close_current()
						else workspace.select(current.workspace_id); workspace.reset() end
						settle()
						assert(not views.valid(survivor) and not views.for_session("hooks-survivor"))
						assert(not views.valid(disposed) and not views.for_session("hooks-disposed"))
						assert(not vim.api.nvim_buf_is_valid(survivor.bufnr) and not vim.api.nvim_buf_is_valid(disposed.bufnr))
					]], { enabled, operation, recovery_failure })
				end)
			end
		end

		it("does not allocate editor buffers or replace @buffer (tabbar=" .. tostring(enabled) .. ")", function()
			editor.lua([[
				open(...)
				chat.create_layout(seed("state-b")); settle()
				local other, count = workspace.current().id, #vim.api.nvim_list_bufs()
				for _ = 1, 20 do workspace.select(original); workspace.select(other) end
				settle()
				assert(#vim.api.nvim_list_bufs() == count, "switching must reuse buffers")
				local context = require("opencode.context")
				assert(context.source().bufnr == source, "switching must retain the real editor source")
				assert(context.capture().values.buffer.blocks[1].lines[1] == "return 'workspace source'")
			]], { enabled })
		end)

		it("restores native location-list contents, ownership, geometry and focus with the tabbar " .. tostring(enabled), function()
			editor.lua([[
				open(...)
				local file = vim.api.nvim_create_buf(true, false)
				vim.bo[file].bufhidden = "wipe"
				vim.api.nvim_buf_set_lines(file, 0, -1, false, { "first", "middle", "last" })
				vim.cmd("rightbelow vsplit")
				local owner = vim.api.nvim_get_current_win()
				vim.api.nvim_win_set_buf(owner, file)
				vim.fn.setloclist(owner, {}, "r", { items = {
					{ bufnr = file, lnum = 1, col = 1, text = "first diagnostic" },
					{ bufnr = file, lnum = 3, col = 2, text = "last diagnostic" },
				}, idx = 2, title = "Workspace diagnostics", context = { source = "state-a", data = { 7 } } })
				vim.cmd("belowright 6lopen")
				local expected = vim.fn.getloclist(owner, { items = 0, idx = 0, title = 0, context = 0, quickfixtextfunc = 0 })
				local function geometry()
					local result = {}
					for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
						local buf, info = vim.api.nvim_win_get_buf(win), vim.fn.getwininfo(win)[1]
						local name = info.loclist == 1 and "locations" or buf == file and "file"
							or buf == first.bufnr and "chat" or "bar"
						result[name] = { vim.api.nvim_win_get_position(win), vim.api.nvim_win_get_width(win),
							vim.api.nvim_win_get_height(win) }
					end
					return result
				end
				local dimensions = geometry()
				chat.create_layout(seed("state-b")); settle()
				assert(vim.api.nvim_buf_is_valid(file) and vim.bo[file].modified, "switching must preserve modified wipe-on-hide files")
				local other, listed = workspace.current().id, #vim.fn.getbufinfo({ buflisted = 1 })
				for _ = 1, 3 do
					workspace.select(original); settle()
					owner = vim.fn.win_findbuf(file)[1]
					local actual = vim.fn.getloclist(owner, { items = 0, idx = 0, title = 0, context = 0, quickfixtextfunc = 0 })
					assert(vim.deep_equal(expected, actual), vim.inspect(actual))
					assert(vim.fn.getloclist(first.winid, { id = 0 }).id == 0, "unrelated panes must not inherit a list")
					local locations = vim.fn.getloclist(owner, { winid = 0 }).winid
					assert(locations ~= 0 and vim.fn.getwininfo(locations)[1].loclist == 1, "must restore a native location-list window")
					assert(vim.fn.getloclist(locations, { filewinid = 0 }).filewinid == owner, "location window must retain its owner")
					assert(vim.api.nvim_get_current_win() == locations, "must restore location-window focus")
					assert(vim.deep_equal(dimensions, geometry()), vim.inspect(geometry()))
					vim.cmd("lprev")
					assert(vim.api.nvim_get_current_win() == owner and vim.api.nvim_win_get_cursor(owner)[1] == 1)
					vim.cmd("lnext")
					assert(vim.api.nvim_win_get_cursor(owner)[1] == 3 and vim.fn.getloclist(owner, { idx = 0 }).idx == 2)
					vim.api.nvim_set_current_win(locations)
					workspace.select(other); settle()
				end
				assert(#vim.fn.getbufinfo({ buflisted = 1 }) == listed, "location-list roundtrips must not allocate editor buffers")
				workspace.select(original)
				vim.cmd("lclose")
				workspace.select(other); workspace.select(original)
				owner = vim.fn.win_findbuf(file)[1]
				assert(vim.fn.getloclist(owner, { winid = 0 }).winid == 0, "a closed location window must stay closed")
				assert(vim.deep_equal(expected, vim.fn.getloclist(owner,
					{ items = 0, idx = 0, title = 0, context = 0, quickfixtextfunc = 0 })))
			]], { enabled })
		end)

		it("preserves wipe-on-hide files when a file-only layout switches or closes (tabbar=" .. tostring(enabled) .. ")", function()
			editor.lua([[
				open(...)
				local file = vim.api.nvim_create_buf(true, false)
				vim.bo[file].bufhidden = "wipe"
				vim.api.nvim_buf_set_lines(file, 0, -1, false, { "keep this unsaved file" })
				vim.cmd("rightbelow split")
				vim.api.nvim_win_set_buf(0, file)
				chat.close_view(first)
				chat.create_layout(seed("state-b"))
				workspace.close_current(); settle()
				assert(workspace.current().id == original)
				assert(vim.api.nvim_get_current_buf() == file, "must restore the file-only layout")
				workspace.close_current(); settle()
				assert(vim.api.nvim_buf_is_valid(file) and vim.bo[file].modified)
				assert(vim.bo[file].bufhidden == "wipe", "must restore the original buffer option")
				assert(vim.api.nvim_buf_get_lines(file, 0, -1, false)[1] == "keep this unsaved file")
				assert(#workspace.list() == 0 and not views.workspace.switching)
			]], { enabled })
		end)

		for _, hidden in ipairs({ "wipe", "delete" }) do
			it("preserves outgoing unsaved " .. hidden .. " buffers while restoring an open location list (tabbar=" .. tostring(enabled) .. ")", function()
				editor.lua([[
					local enabled, hidden = ...
					open(enabled)
					local file = newfile("hide")
					local owner = filepane(file)
					locations(owner, file); vim.cmd("belowright 3lopen")
					chat.create_layout(seed("state-b"))
					local other = workspace.current().id
					local outgoing = newfile(hidden)
					filepane(outgoing)
					vim.api.nvim_buf_set_lines(outgoing, 0, -1, false, { "UNSAVED MUST SURVIVE" })
					for _ = 1, 3 do
						workspace.select(original)
						assert(vim.api.nvim_buf_is_valid(outgoing) and vim.api.nvim_buf_is_loaded(outgoing))
						assert(vim.bo[outgoing].modified and vim.bo[outgoing].bufhidden == hidden)
						assert(vim.api.nvim_buf_get_lines(outgoing, 0, -1, false)[1] == "UNSAVED MUST SURVIVE")
						workspace.select(other)
						assert(vim.api.nvim_get_current_buf() == outgoing)
					end
				]], { enabled, hidden })
			end)
		end

		it("restores and leaves a valid minimum-height location-list layout without a spare pane (tabbar=" .. tostring(enabled) .. ")", function()
			editor.lua([[
				local enabled = ...
				open(enabled)
				local file = newfile("hide")
				local owner = filepane(file)
				locations(owner, file); vim.cmd("belowright 1lopen")
				vim.o.lines = enabled and 10 or 8
				settle()
				local lines, count = vim.o.lines, #vim.api.nvim_tabpage_list_wins(0)
				vim.o.lines = 60
				chat.create_layout(seed("state-b"))
				local other = workspace.current().id
				vim.o.lines = lines
				local peak = 0
				vim.api.nvim_create_autocmd("WinNew", { callback = function()
					peak = math.max(peak, #vim.api.nvim_tabpage_list_wins(0))
				end })
				for _ = 1, 3 do
					assert(workspace.select(original))
					assert(#vim.api.nvim_tabpage_list_wins(0) == count)
					owner = vim.fn.win_findbuf(file)[1]
					local list = vim.fn.getloclist(owner, { idx = 0, winid = 0 })
					assert(list.idx == 2 and vim.api.nvim_get_current_win() == list.winid)
					assert(vim.fn.getloclist(list.winid, { filewinid = 0 }).filewinid == owner)
					assert(workspace.select(other))
				end
				assert(peak <= count, "restoring a native list must not allocate an N+1 placeholder pane")
			]], { enabled })
		end)

		it("restores a valid single-row vertical location-list layout (tabbar=" .. tostring(enabled) .. ")", function()
			editor.lua([[
				local enabled = ...
				open(enabled)
				local file = newfile("delete")
				local owner = filepane(file, "rightbelow vsplit")
				locations(owner, file); vim.cmd("belowright 3lopen")
				assert(vim.fn.win_splitmove(vim.api.nvim_get_current_win(), owner, { vertical = true, rightbelow = true }) == 0)
				vim.o.lines = enabled and 6 or 4
				settle()
				local lines, count = vim.o.lines, #vim.api.nvim_tabpage_list_wins(0)
				vim.o.lines = 60
				chat.create_layout(seed("state-b"))
				local other = workspace.current().id
				vim.o.lines = lines
				for _ = 1, 3 do
					assert(workspace.select(original))
					assert(#vim.api.nvim_tabpage_list_wins(0) == count)
					owner = vim.fn.win_findbuf(file)[1]
					local list = vim.fn.getloclist(owner, { winid = 0 }).winid
					assert(vim.fn.getloclist(list, { filewinid = 0 }).filewinid == owner)
					assert(vim.api.nvim_get_current_win() == list)
					assert(workspace.select(other))
				end
			]], { enabled })
		end)

		it("roundtrips exact chat/file/list geometry in " .. (enabled and "10" or "8") .. " rows without resizing", function()
			editor.lua([[
				local enabled = ...
				open(enabled)
				local file = newfile("wipe")
				local owner = filepane(file)
				locations(owner, file); vim.cmd("belowright 1lopen")
				vim.o.lines = enabled and 10 or 8
				settle()
				local function geometry()
					local result = {}
					for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
						local buf = vim.api.nvim_win_get_buf(win)
						local label = vim.fn.getwininfo(win)[1].loclist == 1 and "locations"
							or buf == file and "file" or buf == first.bufnr and "chat" or "bar"
						result[label] = { vim.api.nvim_win_get_position(win), vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
					end
					return result
				end
				local expected, count = geometry(), #vim.api.nvim_tabpage_list_wins(0)
				chat.create_layout(seed("minimum-b"))
				local other, peak = workspace.current().id, 0
				vim.api.nvim_create_autocmd("WinNew", { callback = function()
					peak = math.max(peak, #vim.api.nvim_tabpage_list_wins(0))
				end })
				for _ = 1, 3 do
					workspace.select(original)
					assert(vim.deep_equal(expected, geometry()), vim.inspect({ expected = expected, actual = geometry() }))
					owner = vim.fn.win_findbuf(file)[1]
					local list = vim.fn.getloclist(owner, { winid = 0 }).winid
					assert(vim.api.nvim_get_current_win() == list and vim.fn.getloclist(list, { filewinid = 0 }).filewinid == owner)
					workspace.select(other)
				end
				assert(peak <= count, "native list creation must not need an additional pane")
			]], { enabled })
		end)

		it("retains rendered custom quickfixtextfunc output (tabbar=" .. tostring(enabled) .. ")", function()
			editor.lua([[
				open(...)
				function _G.WorkspaceLocationText(info)
					local result = {}
					for i = info.start_idx, info.end_idx do result[#result + 1] = "custom location " .. i end
					return result
				end
				local file = newfile("wipe")
				local owner = filepane(file)
				locations(owner, file)
				assert(vim.fn.setloclist(owner, {}, "a", { quickfixtextfunc = "v:lua.WorkspaceLocationText" }) == 0)
				vim.cmd("belowright 3lopen")
				local expected = vim.api.nvim_buf_get_lines(0, 0, -1, false)
				assert(expected[1] == "custom location 1" and expected[2] == "custom location 2")
				chat.create_layout(seed("state-b"))
				local other = workspace.current().id
				for _ = 1, 3 do
					workspace.select(original)
					owner = vim.fn.win_findbuf(file)[1]
					local win = vim.fn.getloclist(owner, { winid = 0 }).winid
					assert(vim.deep_equal(expected, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)))
					workspace.select(other)
				end
			]], { enabled })
		end)

		for _, callback in ipairs({ "partial", "lambda", "dictionary" }) do
			it("retains a native " .. callback .. " quickfixtextfunc without an external reference (tabbar=" .. tostring(enabled) .. ")", function()
				editor.lua([[
					local enabled, callback = ...
					open(enabled)
					local file = newfile("delete")
					local owner = filepane(file)
					locations(owner, file)
					vim.cmd([=[
						function! WorkspaceNativeText(prefix, info) abort
							return map(range(a:info.start_idx, a:info.end_idx), {_, idx -> a:prefix . idx})
						endfunction
						function! WorkspaceNativeDictText(info) dict abort
							return map(range(a:info.start_idx, a:info.end_idx), {_, idx -> self.prefix . idx})
						endfunction
					]=])
					local expression = callback == "partial" and "function('WorkspaceNativeText', ['native location '])"
						or callback == "dictionary" and "function('WorkspaceNativeDictText', [], {'prefix': 'native location '})"
						or "{info -> map(range(info.start_idx, info.end_idx), {_, idx -> 'native location ' . idx})}"
					vim.cmd(("call setloclist(%d, [], 'a', {'quickfixtextfunc': %s})"):format(owner, expression))
					vim.cmd("belowright 3lopen")
					local expected = vim.api.nvim_buf_get_lines(0, 0, -1, false)
					assert(vim.deep_equal(expected, { "native location 1", "native location 2" }))
					local native = vim.fn.eval(("string(getloclist(%d, {'quickfixtextfunc': 0}).quickfixtextfunc)"):format(owner))
					chat.create_layout(seed("callback-b"))
					local other = workspace.current().id
					for _ = 1, 3 do
						workspace.select(original)
						owner = vim.fn.win_findbuf(file)[1]
						assert(native == vim.fn.eval(("string(getloclist(%d, {'quickfixtextfunc': 0}).quickfixtextfunc)"):format(owner)))
						local win = vim.fn.getloclist(owner, { winid = 0 }).winid
						assert(vim.deep_equal(expected, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)))
						vim.cmd("lprevious"); assert(vim.api.nvim_get_current_win() == owner)
						vim.cmd("lnext"); assert(vim.api.nvim_win_get_cursor(owner)[1] == 3)
						workspace.select(other)
					end
				]], { enabled, callback })
			end)
		end

		for _, shared in ipairs({ false, true }) do
			it("keeps different native lists for multiple owners (shared file=" .. tostring(shared) .. ", tabbar=" .. tostring(enabled) .. ")", function()
				editor.lua([[
					local enabled, shared = ...
					open(enabled)
					local files = { newfile("wipe") }
					files[2] = shared and files[1] or newfile("delete")
					local owners = { filepane(files[1], "rightbelow vsplit") }
					owners[2] = filepane(files[2], "rightbelow vsplit")
					local expected = {}
					for i, owner in ipairs(owners) do
						vim.fn.setloclist(owner, {}, "r", { items = {
							{ bufnr = files[i], lnum = 1, text = "owner " .. i .. " first" },
							{ bufnr = files[i], lnum = 3, text = "owner " .. i .. " last" },
						}, idx = i, title = "Owner " .. i, context = { owner = i, nested = { "retained" } } })
						expected[i] = vim.fn.getloclist(owner, { items = 0, idx = 0, title = 0, context = 0 })
						vim.api.nvim_win_call(owner, function() vim.cmd("belowright 3lopen") end)
					end
					vim.api.nvim_set_current_win(vim.fn.getloclist(owners[2], { winid = 0 }).winid)
					local function geometry()
						local result = {}
						for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
							local info = vim.fn.getwininfo(win)[1]
							local list = vim.fn.getloclist(win, { title = 0 })
							local label = info.loclist == 1 and "list " .. list.title
								or list.title ~= "" and "file " .. list.title
								or vim.api.nvim_win_get_buf(win) == first.bufnr and "chat" or "header"
							result[label] = { vim.api.nvim_win_get_position(win), vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
						end
						return result
					end
					local dimensions = geometry()
					chat.create_layout(seed("owners-b"))
					local other = workspace.current().id
					local function check_owners(tree)
						if tree.kind == "leaf" then
							if tree.location_owner then assert(type(tree.location_owner) == "table" and tree.location_owner.kind == "leaf") end
						else for _, child in ipairs(tree.children) do check_owners(child) end end
					end
					check_owners(workspace.list()[1].tree)
					for _ = 1, 3 do
						workspace.select(original)
						assert(vim.deep_equal(dimensions, geometry()), vim.inspect({ expected = dimensions, actual = geometry() }))
						local found, focused = {}, vim.api.nvim_get_current_win()
						for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
							if vim.fn.getwininfo(win)[1].loclist == 0 and vim.api.nvim_win_get_buf(win) ~= first.bufnr then
								local list = vim.fn.getloclist(win, { items = 0, idx = 0, title = 0, context = 0, winid = 0 })
								if list.winid ~= 0 then
									local i = list.context.owner
									found[i] = true
									local locations = list.winid
									list.winid = nil
									assert(vim.deep_equal(expected[i], list), vim.inspect(list))
									assert(vim.fn.getloclist(locations, { filewinid = 0 }).filewinid == win)
									if i == 2 then assert(focused == locations) end
									vim.api.nvim_set_current_win(locations)
									if i == 1 then vim.cmd("lnext"); vim.cmd("lprevious")
									else vim.cmd("lprevious"); vim.cmd("lnext") end
									assert(vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_cursor(win)[1] == (i == 1 and 1 or 3))
								end
							end
						end
						assert(found[1] and found[2], "owners must not share their lists, even for the same buffer")
						vim.api.nvim_set_current_win(focused)
						workspace.select(other)
					end
				]], { enabled, shared })
			end)
		end

		it("preserves an empty native list and its open/closed state (tabbar=" .. tostring(enabled) .. ")", function()
			editor.lua([[
				open(...)
				local file = newfile("delete")
				local owner = filepane(file)
				vim.fn.setloclist(owner, {}, "r", { items = {}, title = "Empty diagnostics", context = { empty = true } })
				vim.cmd("belowright 2lopen")
				local expected = vim.fn.getloclist(owner, { items = 0, idx = 0, title = 0, context = 0 })
				chat.create_layout(seed("empty-b"))
				local other = workspace.current().id
				for _, opened in ipairs({ true, false }) do
					workspace.select(original)
					owner = vim.fn.win_findbuf(file)[1]
					assert(vim.deep_equal(expected, vim.fn.getloclist(owner, { items = 0, idx = 0, title = 0, context = 0 })))
					assert((vim.fn.getloclist(owner, { winid = 0 }).winid ~= 0) == opened)
					if opened then vim.cmd("lclose") end
					workspace.select(other)
				end
			]], { enabled })
		end)
	end

	for _, operation in ipairs({ "close", "reset" }) do
		it("releases native callback snapshots after " .. operation, function()
			editor.lua([[
				local operation = ...
				open(false)
				local file = newfile("hide")
				local owner = filepane(file)
				locations(owner, file)
				vim.cmd(("call setloclist(%d, [], 'a', {'quickfixtextfunc': {info -> ['callback']}})"):format(owner))
				vim.cmd("belowright 2lopen")
				chat.create_layout(seed("release-b"))
				local other = workspace.current().id
				for _ = 1, 5 do workspace.select(original); workspace.select(other) end
				assert(vim.fn.eval("len(g:opencode_workspace_location_text)") == 2, "one native snapshot per saved layout")
				if operation == "reset" then workspace.reset()
				else workspace.close_current(); workspace.close_current() end
				assert(vim.fn.eval("len(g:opencode_workspace_location_text)") == 0, "discarded layouts must release Funcrefs")
			]], { operation })
		end)
	end

	it("keeps saved file focus and narrow chat geometry when selecting a layout with chat navigation", function()
		editor.lua([[
			open(true)
			local file = newfile("delete")
			filepane(file, "rightbelow vsplit"); settle()
			vim.api.nvim_win_set_width(first.winid, 10)
			assert(vim.api.nvim_get_current_buf() == file and vim.api.nvim_win_get_width(first.winid) == 10)
			chat.create_layout(seed("header-b"))
			local other = workspace.current().id
			for _ = 1, 3 do
				chat.focus_view(chat.get_view())
				vim.api.nvim_feedkeys("1gt", "xt", false)
				settle()
				assert(workspace.current().id == original)
				assert(vim.api.nvim_get_current_buf() == file, "keyboard selection must preserve the saved file focus")
				assert(vim.api.nvim_win_get_width(first.winid) == 10, "keyboard selection must not enlarge the restored chat")
				assert(vim.o.winwidth == 20)
				workspace.select(other)
			end
		]])
	end)

	it("clears the switching guard after E36 before disposing any views and remains usable", function()
		editor.lua([[
			open(false)
			for i = 1, 5 do chat.create_split(chat.get_view(), seed("state-split-" .. i), "horizontal") end
			local second = chat.create_layout(seed("state-b"))
			local other = workspace.current().id
			vim.o.lines = 4
			local ok, err = pcall(workspace.close_current)
			assert(not ok and tostring(err):find("E36", 1, true), tostring(err))
			assert(not views.workspace.switching, "failed close must release the switching guard")
			assert(workspace.current().id == other and #workspace.list() == 2)
			assert(views.valid(second) and second.visible and vim.api.nvim_win_is_valid(second.winid))
			assert(first.suspended, "failed suspension must not dispose hidden views")
			vim.o.lines = 60
			assert(chat.focus_view(second))
			assert(workspace.select(original)); assert(workspace.select(other))
			workspace.close_current(); settle()
			assert(workspace.current().id == original and #workspace.list() == 1)
			assert(chat.focus_view(first))
		]])
	end)

	it("does not dispose the closing layout before its replacement fits", function()
		editor.lua([[
			open(true)
			for i = 1, 5 do chat.create_split(chat.get_view(), seed("state-split-" .. i), "horizontal") end
			local second = chat.create_layout(seed("state-b"))
			local other = workspace.current().id
			vim.o.lines = 10
			local ok, err = pcall(workspace.close_current)
			assert(not ok and tostring(err):find("E36", 1, true), tostring(err))
			assert(not views.workspace.switching and #workspace.list() == 2)
			assert(views.valid(second) and second.workspace_id == other and second.visible)
			assert(workspace.current().id == other and vim.api.nvim_win_is_valid(second.winid))
			vim.o.lines = 60
			workspace.close_current()
			assert(#workspace.list() == 1 and workspace.current().id == original and not views.valid(second))
		]])
	end)

	for _, operation in ipairs({ "select", "close" }) do
		it("restores buffer options and recovers same-layout selection after partial suspension fails in " .. operation, function()
			editor.lua([[
				local operation = ...
				open(false)
				local files = { newfile("delete"), newfile("wipe") }
				for _, file in ipairs(files) do filepane(file) end
				chat.create_layout(seed("state-b"))
				local other = workspace.current().id
				workspace.select(original)
				local close, calls = vim.api.nvim_win_close, 0
				vim.api.nvim_win_close = function(...)
					calls = calls + 1
					if calls == 2 then error("injected partial suspension failure") end
					return close(...)
				end
				local ok, err = pcall(function()
					if operation == "select" then workspace.select(other) else workspace.close_current() end
				end)
				vim.api.nvim_win_close = close
				assert(not ok and tostring(err):find("injected partial suspension failure", 1, true), tostring(err))
				assert(not views.workspace.switching)
				for i, hidden in ipairs({ "delete", "wipe" }) do
					local buf = files[i]
					assert(vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified)
					assert(vim.bo[buf].bufhidden == hidden)
				end
				assert(workspace.select(original) and first.visible and vim.api.nvim_win_is_valid(first.winid))
				assert(not workspace.current().incomplete)
				assert(workspace.select(other)); assert(workspace.select(original))
				workspace.close_current()
			]], { operation })
		end)
	end

	for _, failure in ipairs({ 1, 2 }) do
		it("retains failed disposals and prunes successful ones before retrying close: member " .. failure, function()
			editor.lua([[
				local failure = ...
				open(false)
				local second = chat.create_layout(seed("state-b"))
				local third = chat.create_split(second, seed("state-c"), "vertical")
				local other, failed = workspace.current().id, failure == 1 and second or third
				local owned, disposed = chat.for_view(failed)
				disposed = owned.dispose
				owned.dispose = function() error("injected disposal failure") end
				local ok, err = pcall(workspace.close_current)
				owned.dispose = disposed
				assert(not ok and tostring(err):find("injected disposal failure", 1, true), tostring(err))
				assert(not views.workspace.switching and failed.workspace_id == other and views.valid(failed))
				if failure == 2 then assert(not views.valid(second)) end
				assert(workspace.select(other))
				assert(#vim.api.nvim_tabpage_list_wins(0) == 3 - failure, "disposed members must not leave blank panes")
				assert(workspace.current().last_view == (failure == 1 and third or failed))
				if failure == 2 then assert(workspace.current().root_view == third) end
				workspace.close_current(); settle()
				assert(not views.valid(second) and not views.valid(third))
				assert(not views.for_session("state-b") and not views.for_session("state-c"))
				assert(#workspace.list() == 1 and workspace.current().id == original)
			]], { failure })
		end)
	end

	it("reconciles partially reset trees and keeps the visible layout attached", function()
		editor.lua([[
			open(true)
			local second = chat.create_layout(seed("state-b"))
			local other = workspace.current().id
			locations(second.winid, newfile("hide")); vim.cmd("belowright 3lopen")
			local third = chat.create_split(second, seed("state-c"), "vertical")
			local current = chat.create_layout(seed("state-d"))
			local selected = workspace.current().id
			local owned = chat.for_view(third)
			local dispose = owned.dispose
			owned.dispose = function() error("injected partial reset failure") end
			local ok, err = pcall(workspace.reset)
			owned.dispose = dispose
			assert(not ok and tostring(err):find("injected partial reset failure", 1, true), tostring(err))
			assert(not views.workspace.switching and not views.valid(second))
			assert(current.workspace_id == selected and current.visible and workspace.current().id == selected)
			settle()
			assert(workspace.select(other))
			assert(workspace.current().root_view == third and workspace.current().last_view == third)
			assert(#vim.api.nvim_tabpage_list_wins(0) == 1 and vim.api.nvim_get_current_buf() == third.bufnr)
			workspace.close_current(); workspace.reset()
			assert(#workspace.list() == 0 and not views.workspace.switching)
		]])
	end)

	it("restores a moved location-list pane before its owner without changing nested geometry", function()
		editor.lua([[
			open(true)
			local file = newfile("delete")
			local owner = filepane(file, "rightbelow vsplit")
			locations(owner, file); vim.cmd("belowright 3lopen")
			assert(vim.fn.win_splitmove(vim.api.nvim_get_current_win(), first.winid, { vertical = false, rightbelow = false }) == 0)
			local function geometry()
				local result = {}
				for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					local buf, info = vim.api.nvim_win_get_buf(win), vim.fn.getwininfo(win)[1]
					local name = info.loclist == 1 and "locations" or buf == file and "file" or buf == first.bufnr and "chat" or "bar"
					result[name] = { vim.api.nvim_win_get_position(win), vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
				end
				return result
			end
			local expected = geometry()
			chat.create_layout(seed("state-b"))
			local other = workspace.current().id
			for _ = 1, 3 do
				workspace.select(original)
				assert(vim.deep_equal(expected, geometry()), vim.inspect({ expected = expected, actual = geometry() }))
				owner = vim.fn.win_findbuf(file)[1]
				local list = vim.fn.getloclist(owner, { winid = 0 }).winid
				assert(vim.fn.getloclist(list, { filewinid = 0 }).filewinid == owner)
				assert(vim.api.nvim_get_current_win() == list)
				workspace.select(other)
			end
		]])
	end)

	for _, switching in ipairs({ false, true }) do
		it("restores the prior switching guard on reset failure: " .. tostring(switching), function()
			editor.lua([[
				local switching = ...
				open(false)
				chat.create_layout(seed("state-b"))
				local owned = chat.for_view(first)
				local dispose = owned.dispose
				owned.dispose = function() error("injected reset failure") end
				views.workspace.switching = switching
				local ok, err = pcall(workspace.reset)
				owned.dispose = dispose
				assert(not ok and tostring(err):find("injected reset failure", 1, true), tostring(err))
				assert(views.workspace.switching == switching, "reset must restore the prior switching guard")
				views.workspace.switching = false
				assert(workspace.select(original))
				assert(chat.focus_view(first))
				workspace.reset()
				assert(not views.workspace.switching and #workspace.list() == 0)
			]], { switching })
		end)
	end
end)
