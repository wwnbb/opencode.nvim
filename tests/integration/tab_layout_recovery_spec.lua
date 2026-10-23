describe("tab layout recovery", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.lua([[
			vim.o.lines, vim.o.columns = 60, 120
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab" } })
			require("opencode.client").get_messages = function(_, _, cb) cb(nil, {}) end
			chat = require("opencode.ui.chat")
			workspace = require("opencode.ui.chat.workspace")
			views = require("opencode.ui.chat.state")
			function seed(id)
				local session = { id = id, title = id }
				require("opencode.session").remember(session)
				return session
			end
			seed("recovery-a"); require("opencode.session").set_active("recovery-a", "A")
			chat.open()
			first, original = chat.get_view(), workspace.current().id
		]])
	end)
	after_each(function() if editor then editor.close() end end)

	it("preserves both layouts when the terminal cannot fit the saved splits", function()
		editor.lua([[
			for i = 1, 6 do chat.create_split(chat.get_view(), seed("split-" .. i), "horizontal") end
			chat.create_layout(seed("recovery-b"))
			local second = workspace.current().id
			vim.o.lines = 10
			local ok, err = pcall(workspace.select, original)
			assert(not ok and tostring(err):find("E36", 1, true), tostring(err))
			assert(workspace.current().id == second, "failed restore must retain the previous layout")
			assert(chat.get_view().visible and vim.api.nvim_win_is_valid(chat.get_view().winid))
			vim.o.lines = 60
			for _ = 1, 2 do
				assert(workspace.select(original))
				assert(#vim.api.nvim_tabpage_list_wins(0) == 7, "all seven panes must survive the failed restore")
				assert(workspace.select(second))
			end
		]])
	end)

	it("recovers when both the initial restore and its rollback fail", function()
		editor.lua([[
			for i = 1, 5 do chat.create_split(chat.get_view(), seed("first-" .. i), "horizontal") end
			chat.create_layout(seed("recovery-b"))
			local second = workspace.current().id
			for i = 1, 5 do chat.create_split(chat.get_view(), seed("second-" .. i), "horizontal") end
			local set_buf = vim.api.nvim_win_set_buf
			vim.api.nvim_win_set_buf = function() error("injected restore failure") end
			local ok = pcall(workspace.select, original)
			vim.api.nvim_win_set_buf = set_buf
			assert(not ok)
			assert(workspace.select(second))
			assert(#vim.api.nvim_tabpage_list_wins(0) == 6)
			assert(workspace.select(original))
			assert(#vim.api.nvim_tabpage_list_wins(0) == 6)
		]])
	end)

	it("dismisses inline proposals before switching while preserving manual file edits", function()
		editor.lua([[
			local edits = views.module(first, require("opencode.ui.chat.edits"))
			local path = vim.fn.tempname()
			vim.fn.writefile({ "before" }, path)
			edits.open_inline_diff_split({ filepath = path, before = "before\n", after = "after\n" })
			local actual = vim.api.nvim_get_current_buf()
			vim.bo[actual].bufhidden = "wipe"
			vim.api.nvim_buf_set_lines(actual, 0, -1, false, { "manual unsaved edit" })
			chat.create_layout(seed("recovery-b"))
			workspace.select(original)
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				assert(not vim.wo[win].diff, "restored panes must not retain an orphaned diff")
				assert(not edits.is_inline_diff_window(win))
				assert(not vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("[proposed]", 1, true))
			end
			assert(vim.api.nvim_buf_is_valid(actual) and vim.bo[actual].modified)
			assert(vim.api.nvim_buf_get_lines(actual, 0, -1, false)[1] == "manual unsaved edit")
			vim.fn.delete(path)
		]])
	end)

	it("leaves the original layout usable when new-view setup fails", function()
		editor.lua([[
			for _, method in ipairs({ "nvim_create_buf", "nvim_win_set_buf" }) do
				local saved, failed = vim.api[method], false
				vim.api[method] = function(...)
					if not failed then failed = true; error("injected layout failure") end
					return saved(...)
				end
				local ok = pcall(chat.create_layout, seed("failed-" .. method))
				vim.api[method] = saved
				assert(not ok)
				assert(#workspace.list() == 1, "failed creation must not leave a layout behind")
				assert(workspace.current().id == original)
				assert(first.visible and vim.api.nvim_win_is_valid(first.winid))
				assert(#views.all() == 1, "failed creation must release its view")
			end
			chat.create_layout(seed("recovery-success"))
			assert(#workspace.list() == 2)
			assert(workspace.select(original))
		]])
	end)

	it("restores resize and tab-refresh hooks after closing and reopening the default view", function()
		editor.lua([[
			workspace.close_current()
			chat.open()
			assert(chat.get_view() == first)
			for _, prefix in ipairs({ "OpenCodeChatResize_", "OpenCodeSessionTabs_" }) do
				assert(#vim.api.nvim_get_autocmds({ group = prefix .. first.id }) > 0)
			end
			local owned, renders = chat.for_view(first), 0
			local render = owned.do_render
			owned.do_render = function(...) renders = renders + 1; return render(...) end
			vim.api.nvim_exec_autocmds("VimResized", {})
			assert(vim.wait(1000, function() return renders > 0 end, 5), "reopened view must respond to resize")
		]])
	end)

	for _, scoped in ipairs({ false, true }) do
		it("preserves window directories and inherited " .. (scoped and "tab" or "global") .. " scope", function()
			editor.lua([[
				local scoped = ...
				local global = vim.fn.getcwd(-1, -1)
				local root = vim.fn.tempname()
				for _, dir in ipairs({ "one", "two", "shared" }) do vim.fn.mkdir(root .. "/" .. dir, "p") end
				root = vim.uv.fs_realpath(root)
				local second = chat.create_split(first, seed("cwd-b"), "vertical")
				local third = chat.create_split(second, seed("cwd-c"), "horizontal")
				vim.api.nvim_win_call(first.winid, function() vim.cmd.lcd(root .. "/one") end)
				vim.api.nvim_win_call(second.winid, function() vim.cmd.lcd(root .. "/two") end)
				chat.create_layout(seed("cwd-d"))
				if scoped then vim.cmd.tcd(root .. "/shared") end
				assert(workspace.select(original))
				local function cwd(view)
					return { vim.fn.getcwd(view.winid), vim.fn.haslocaldir(view.winid) }
				end
				assert(vim.deep_equal({ root .. "/one", 1 }, cwd(first)), vim.inspect(cwd(first)))
				assert(vim.deep_equal({ root .. "/two", 1 }, cwd(second)), vim.inspect(cwd(second)))
				assert(vim.deep_equal({ scoped and root .. "/shared" or global, 0 }, cwd(third)),
					"unscoped pane must inherit the current tab/global directory: " .. vim.inspect({ cwd(third), global }))
				assert(vim.fn.getcwd(-1, -1) == global, vim.inspect({ vim.fn.getcwd(-1, -1), global }))
				vim.cmd.cd(global)
				vim.fn.delete(root, "rf")
			]], { scoped })
		end)
	end
end)

describe("tab layout lifecycle recovery", function()
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
			function open(enabled)
				require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
					chat = { layout = "tab", session_tabs = { enabled = enabled } } })
				require("opencode.client").get_messages = function(_, _, cb) cb(nil, {}) end
				chat, workspace = require("opencode.ui.chat"), require("opencode.ui.chat.workspace")
				views = require("opencode.ui.chat.state")
				seed("recovery-a"); require("opencode.session").set_active("recovery-a", "A")
				chat.open()
				first, original = chat.get_view(), workspace.current().id
			end
			function filepane(hidden)
				local buf = vim.api.nvim_create_buf(true, false)
				vim.bo[buf].bufhidden = hidden
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "UNSAVED " .. hidden })
				vim.cmd("rightbelow split")
				vim.api.nvim_win_set_buf(0, buf)
				return buf, vim.api.nvim_get_current_win()
			end
			function coherent()
				for _, view in ipairs(views.all()) do
					if view.workspace_id then
						local found = false
						for _, layout in ipairs(workspace.list()) do if layout.id == view.workspace_id then found = true end end
						assert(found, "orphaned view")
					end
				end
				for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					assert(vim.api.nvim_win_get_config(win).relative == "", "ghost preparation float")
				end
			end
			function inline_review()
				local path = vim.fn.tempname() .. ".lua"
				vim.fn.writefile({ "before" }, path)
				local reviews = require("opencode.edit.state")
				local record = reviews.add_edit("inline-lifecycle", "recovery-a", {
					{ fileID = "inline-file", filePath = path, before = "before\n", after = "after\n", type = "update" },
				}, { transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
				reviews.set_message("inline-lifecycle", "KEEP review note")
				local edits = views.module(first, require("opencode.ui.chat.edits"))
				edits.open_inline_diff_split({ filepath = path, before = "before\n", after = "after\n" },
					{ edit_id = "inline-lifecycle", file_index = 1 })
				local actual, proposed, buf
				for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					if edits.is_inline_diff_window(win) then
						local b = vim.api.nvim_win_get_buf(win)
						if vim.bo[b].buftype == "nofile" then proposed = win else actual, buf = win, b end
					end
				end
				assert(actual and proposed and buf, "fixture must open a real inline diff pair")
				vim.bo[buf].bufhidden = "wipe"
				vim.bo[buf].shiftwidth, vim.bo[buf].tabstop, vim.bo[buf].fileformat = 3, 5, "dos"
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "UNSAVED inline actual" })
				return { edits = edits, path = path, actual = actual, proposed = proposed, buf = buf,
					proposal_buf = vim.api.nvim_win_get_buf(proposed), record = vim.deepcopy(record) }
			end
			function inline_intact(diff)
				assert(vim.api.nvim_buf_is_loaded(diff.buf) and vim.bo[diff.buf].modified and vim.bo[diff.buf].bufhidden == "wipe")
				assert(vim.bo[diff.buf].shiftwidth == 3 and vim.bo[diff.buf].tabstop == 5 and vim.bo[diff.buf].fileformat == "dos")
				assert(vim.deep_equal(vim.api.nvim_buf_get_lines(diff.buf, 0, -1, false), { "UNSAVED inline actual" }))
				assert(vim.deep_equal(vim.fn.readfile(diff.path), { "before" }), "cleanup wrote the unsaved file")
				assert(vim.deep_equal(require("opencode.edit.state").get_edit("inline-lifecycle"), diff.record), "cleanup changed review data/notes")
				assert(not vim.api.nvim_win_is_valid(diff.proposed) and not vim.api.nvim_buf_is_valid(diff.proposal_buf))
				for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					assert(not diff.edits.is_inline_diff_window(win) and not vim.wo[win].diff, "orphaned inline diff")
				end
				coherent()
			end
		]])
	end)
	after_each(function() if editor then editor.close() end end)

	it("clears invalid anchor references after a final native WinClosed error", function()
		editor.lua([[
			open(false)
			local file, anchor = filepane("wipe")
			chat.close_view(first)
			vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(anchor), once = true,
				callback = function() error("final anchor WinClosed failure") end })
			local ok, err = pcall(workspace.close_current)
			assert(not ok and tostring(err):find("final anchor WinClosed failure", 1, true), tostring(err))
			assert(vim.api.nvim_buf_is_loaded(file) and vim.bo[file].modified and vim.bo[file].bufhidden == "wipe")
			assert(not views.workspace.anchor or vim.api.nvim_win_is_valid(views.workspace.anchor), "stale anchor")
			assert(not views.workspace.tabpage or vim.api.nvim_tabpage_is_valid(views.workspace.tabpage), "stale native tab")
			chat.open()
			chat.create_layout(seed("after-final-close")); workspace.close_current()
			coherent()
		]])
	end)

	it("does not retain a deleted active layout when failed creation cannot finish rollback", function()
		editor.lua([[
			open(true)
			local set_option, attempts = vim.api.nvim_set_option_value, 0
			vim.api.nvim_set_option_value = function(name, value, opts)
				if name == "winhighlight" and opts and opts.scope == "local" then
					attempts = attempts + 1
					if attempts > 1 then error("native failed-creation rollback error") end
					return set_option("opencode_invalid_window_option", value, opts)
				end
				return set_option(name, value, opts)
			end
			local ok, err = pcall(chat.create_layout, seed("deleted-active-layout"))
			vim.api.nvim_set_option_value = set_option
			assert(not ok and tostring(err):find("opencode_invalid_window_option", 1, true), tostring(err))
			assert(tostring(err):find("native failed-creation rollback error", 1, true), tostring(err))
			assert(#workspace.list() == 1 and workspace.current().id == original)
			assert(workspace.current().incomplete and not views.workspace.switching)
			assert(not views.for_session("deleted-active-layout"))
			assert(workspace.select(original) and chat.focus_view(first))
			assert(not workspace.current().incomplete)
			chat.create_layout(seed("after-creation-rollback")); workspace.close_current()
			coherent()
		]])
	end)

	it("respects a file-only native winfixbuf lock without changing data or options", function()
		editor.lua([[
			open(false)
			local file, win = filepane("wipe")
			chat.close_view(first)
			vim.wo[win].winfixbuf = true
			local layout = workspace.current()
			for attempt = 1, 2 do
				local ok, err = pcall(chat.create_layout, seed("locked-file-" .. attempt))
				assert(not ok and tostring(err):find("E1513", 1, true), tostring(err))
				assert(not views.workspace.switching and workspace.current() == layout and not layout.incomplete)
				assert(#workspace.list() == 1 and vim.api.nvim_win_get_buf(win) == file and vim.wo[win].winfixbuf)
				assert(vim.api.nvim_buf_is_loaded(file) and vim.bo[file].modified and vim.bo[file].bufhidden == "wipe")
				assert(vim.api.nvim_buf_get_lines(file, 0, -1, false)[1] == "UNSAVED wipe")
				coherent()
			end
		]])
	end)

	for _, enabled in ipairs({ false, true }) do
		it("preserves inline unsaved-refusal and successful reusable-window contracts: header=" .. tostring(enabled), function()
			editor.lua([[
				open(...)
				local diff = inline_review()
				local ok, err, reusable, buf = diff.edits.close_inline_diff_split({ check_unsaved = true, silent = true })
				assert(not ok and err == "unsaved_changes" and not reusable and not buf)
				assert(vim.api.nvim_win_is_valid(diff.actual) and vim.api.nvim_win_is_valid(diff.proposed))
				local closed, close_err, actual, actual_buf = diff.edits.close_inline_diff_split({ preserve_actual = true, silent = true })
				assert(closed and not close_err and actual == diff.actual and actual_buf == diff.buf)
				inline_intact(diff)
				vim.fn.delete(diff.path)
			]], { enabled })
		end)

		it("returns the first native inline close error without losing reusable actual: header=" .. tostring(enabled), function()
			editor.lua([[
				open(...)
				local diff = inline_review()
				vim.api.nvim_win_call(diff.proposed, function() vim.cmd("rightbelow vsplit") end)
				local proposals = {}
				for _, win in ipairs(vim.fn.win_findbuf(diff.proposal_buf)) do
					vim.api.nvim_win_set_var(win, "opencode_inline_diff_split", first.id)
					proposals[#proposals + 1] = win
				end
				assert(#proposals == 2)
				local reached = {}
				for _, win in ipairs(proposals) do
					vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = function()
						local err = "native proposal WinClosed " .. win
						reached[#reached + 1] = err
						error(err)
					end })
				end
				local ok, err, reusable, buf = diff.edits.close_inline_diff_split({ preserve_actual = true, silent = true })
				assert(#reached == 2, "safe cleanup stopped before closing the other proposal")
				assert(ok and tostring(err):find(reached[1], 1, true), tostring(err))
				assert(reusable == diff.actual and buf == diff.buf, "error changed the successful reusable-window contract")
				inline_intact(diff)
				local closed, retry_err, retry_win, retry_buf = diff.edits.close_inline_diff_split({ preserve_actual = true })
				assert(closed and not retry_err and not retry_win and not retry_buf)
				chat.create_layout(seed("inline-direct-retry")); assert(workspace.select(original))
				inline_intact(diff)
				vim.fn.delete(diff.path)
			]], { enabled })
		end)

		for _, operation in ipairs({ "create", "select", "close" }) do
			for _, prior in ipairs({ "unset", "false", "true" }) do
				it(("propagates native inline WinClosed through %s: header=%s guard=%s"):format(operation, tostring(enabled), prior), function()
					editor.lua([[
						local enabled, operation, prior = ...
						open(enabled)
						local replacement = chat.create_layout(seed("inline-replacement"))
						local other = workspace.current().id
						assert(workspace.select(original))
						local diff = inline_review()
						local current, generation = workspace.current(), first.generation
						local native = 0
						vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(diff.proposed), once = true, callback = function()
							native = native + 1
							error("native lifecycle proposal WinClosed")
						end })
						local previous
						if prior ~= "unset" then previous = prior == "true" end
						views.workspace.switching = previous
						local function run()
							if operation == "create" then return chat.create_layout(seed("inline-created")) end
							if operation == "select" then return workspace.select(other) end
							return workspace.close_current()
						end
						local ok, err = pcall(run)
						assert(not ok and tostring(err):find("native lifecycle proposal WinClosed", 1, true), tostring(err))
						assert(native == 1 and views.workspace.switching == previous, "lost native fault or prior switching guard")
						assert(workspace.current() == current and #workspace.list() == 2 and not current.incomplete)
						assert(views.valid(first, generation) and first.workspace_id == original and first.visible and not first.suspended)
						assert(views.valid(replacement) and replacement.suspended and replacement.workspace_id == other)
						assert(chat.focus_view(first))
						inline_intact(diff)
						run()
						assert(views.workspace.switching == previous)
						if operation == "close" then
							assert(#workspace.list() == 1 and workspace.current().id == other and not first.workspace_id)
						else
							assert(workspace.select(original) and chat.focus_view(first))
						end
						inline_intact(diff)
						vim.fn.delete(diff.path)
					]], { enabled, operation, prior })
				end)
			end
		end

		it("propagates native surviving-proposal normalization errors: header=" .. tostring(enabled), function()
			editor.lua([[
				open(...)
				local diff = inline_review()
				-- Leave only the scratch proposal marked, but keep the unsaved actual visible.
				vim.api.nvim_win_call(diff.actual, function()
					vim.cmd("rightbelow split")
					pcall(vim.api.nvim_win_del_var, 0, "opencode_inline_diff_split")
				end)
				vim.api.nvim_win_close(diff.actual, true)
				local reached = false
				vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(diff.proposed), once = true, callback = function()
					reached = true
					error("native surviving proposal WinClosed")
				end })
				local ok, err = pcall(chat.create_layout, seed("inline-surviving"))
				assert(reached and not ok and tostring(err):find("native surviving proposal WinClosed", 1, true), tostring(err))
				assert(not views.workspace.switching and workspace.current().id == original and first.visible and #workspace.list() == 1)
				inline_intact(diff)
				chat.create_layout(seed("inline-surviving")); assert(workspace.select(original) and chat.focus_view(first))
				inline_intact(diff)
				vim.fn.delete(diff.path)
			]], { enabled })
		end)

		for _, owner in ipairs({ "default", "nondefault" }) do
			for _, stage in ipairs({ "before", "unsubscribe", "refresh", "complete" }) do
				it(("recovers public suspended close_view after %s disposal: header=%s owner=%s"):format(stage, tostring(enabled), owner), function()
					editor.lua([[
						local enabled, owner, stage = ...
						open(enabled)
						local second = chat.create_split(first, seed("boundary-second"), "vertical")
						local failed = owner == "default" and first or second
						local remaining = failed == first and second or first
						chat.focus_view(failed)
						failed.expanded_tools["boundary-expansion"] = true
						vim.cmd("rightbelow vsplit") -- A native copy is the same view, not another owner.
						vim.wait(30, function() return false end, 5)
						local file, filewin = filepane("wipe")
						vim.fn.setloclist(filewin, {}, "r", { items = { { bufnr = file, lnum = 1, text = "retained file" } } })
						vim.cmd("belowright 2lopen")
						local layout = workspace.current()
						local current = chat.create_layout(seed("boundary-visible"))
						local selected, focused = workspace.current(), vim.api.nvim_get_current_win()
						local tree, generation = layout.tree, failed.generation
						local root, last = layout.root_view, layout.last_view
						local events = require("opencode.events")
						local function listeners()
							local result = {}
							for _, event in ipairs(events.list_event_types()) do result[event] = events.listener_count(event) end
							return result
						end
						local function hooks()
							local result = {}
							for _, prefix in ipairs({ "OpenCodeChatResize_", "OpenCodeSessionTabs_" }) do
								local ok, value = pcall(vim.api.nvim_get_autocmds, { group = prefix .. failed.id })
								result[prefix] = ok and #value or 0
							end
							return result
						end
						local function count_leaves(node)
							if node.kind == "leaf" then return 1 end
							local count = 0
							for _, child in ipairs(node.children) do count = count + count_leaves(child) end
							return count
						end
						local before, registered = listeners(), hooks()
						local owned, tabs = chat.for_view(failed), views.module(failed, require("opencode.ui.chat.session_tabs"))
						local dispose, tab_dispose, off, after = owned.dispose, tabs.dispose, events.off, chat.after_close
						local reconciled, calls, armed = 0, 0, false
						local function native_failure() vim.api.nvim_win_get_buf(-1) end
						chat.after_close = function(...) reconciled = reconciled + 1; return after(...) end
						if stage == "before" then owned.dispose = native_failure
						elseif stage == "unsubscribe" then
							events.off = function(...)
								off(...)
								calls = calls + 1
								if armed and calls == 3 then armed = false; native_failure() end
							end
						elseif stage == "refresh" then
							tabs.dispose = function() tab_dispose(); native_failure() end
						else owned.dispose = function() dispose(); native_failure() end end
						for attempt = 1, 2 do
							armed, calls = true, 0
							local ok, err = pcall(chat.close_view, failed, { all_windows = true })
							assert(not ok and tostring(err):find("Invalid window id", 1, true), tostring(err))
							assert(views.valid(failed, generation) and failed.suspended and failed.workspace_id == layout.id)
							assert(views.for_session(failed.session_id) == failed, "failed close lost session ownership")
							assert(reconciled >= attempt, "failed public close must still reconcile")
							assert(layout.tree == tree and count_leaves(tree) == 5, "failed disposal pruned a retryable leaf")
							assert(layout.root_view == root and layout.last_view == last)
							assert(workspace.current() == selected and current.visible and vim.api.nvim_get_current_win() == focused)
							assert(vim.deep_equal(before, listeners()), "lost or duplicate event subscriptions: " .. vim.inspect(listeners()))
							assert(vim.deep_equal(registered, hooks()), "partially disposed refresh hooks were not restored")
							vim.wait(30, function() return false end, 5)
							assert(vim.api.nvim_buf_is_loaded(failed.bufnr), "deferred disposal deleted the retained transcript")
						end
						owned.dispose, tabs.dispose, events.off, chat.after_close = dispose, tab_dispose, off, after
						assert(workspace.select(original) and chat.focus_view(failed))
						assert(failed.expanded_tools["boundary-expansion"] and #views.windows(failed) == 2)
						assert(#vim.api.nvim_tabpage_list_wins(0) == 5)
						local notice = "boundary-" .. stage
						events.emit("local_notice", { session_id = failed.session_id, role = "system", content = notice })
						assert(vim.wait(1000, function()
							return table.concat(vim.api.nvim_buf_get_lines(failed.bufnr, 0, -1, false), "\n"):find(notice, 1, true) ~= nil
						end, 5), "restored view no longer receives events")
						local notices = 0
						for _, item in ipairs(failed.local_notices) do if item.content == notice then notices = notices + 1 end end
						assert(notices == 1, "repair duplicated subscriptions")
						local renders, render = 0, owned.do_render
						owned.do_render = function(...) renders = renders + 1; return render(...) end
						vim.api.nvim_exec_autocmds("VimResized", {})
						assert(vim.wait(1000, function() return renders > 0 end, 5), "restored resize hook is inert")
						owned.do_render = render
						workspace.select(selected.id)
						chat.close_view(failed, { all_windows = true })
						assert(not failed.workspace_id and not failed.suspended and not views.for_session(failed.session_id))
						assert(workspace.select(original) and chat.focus_view(remaining))
						assert(layout.root_view == remaining and layout.last_view == remaining)
						assert(#vim.api.nvim_tabpage_list_wins(0) == 3, "retry left native-copy or empty ghost panes")
						assert(vim.api.nvim_buf_is_loaded(file) and vim.bo[file].modified and vim.bo[file].bufhidden == "wipe")
						coherent()
					]], { enabled, owner, stage })
				end)
			end
		end

		it("preserves disposal, repair and reconciliation errors during public suspended close: header=" .. tostring(enabled), function()
			editor.lua([[
				local enabled = ...
				open(enabled)
				local layout = workspace.current()
				local current = chat.create_layout(seed("boundary-diagnostics"))
				local selected, tree, generation = workspace.current(), layout.tree, first.generation
				local owned = chat.for_view(first)
				local dispose, create, after = owned.dispose, owned.create, chat.after_close
				local reconciled = false
				owned.dispose = function() dispose(); vim.api.nvim_win_get_buf(-1) end
				owned.create = function() vim.api.nvim_get_option_value("opencode_boundary_repair_failure", {}) end
				chat.after_close = function()
					reconciled = true
					after()
					vim.api.nvim_get_option_value("opencode_boundary_reconcile_failure", {})
				end
				local ok, err = pcall(chat.close_view, first)
				owned.dispose, owned.create, chat.after_close = dispose, create, after
				assert(not ok and tostring(err):find("Invalid window id", 1, true), tostring(err))
				assert(tostring(err):find("Could not restore suspended chat", 1, true), tostring(err))
				assert(tostring(err):find("opencode_boundary_repair_failure", 1, true), tostring(err))
				assert(reconciled and tostring(err):find("opencode_boundary_reconcile_failure", 1, true), tostring(err))
				assert(views.valid(first, generation) and first.suspended and first.workspace_id == layout.id)
				assert(layout.tree == tree and workspace.current() == selected and current.visible)
				vim.wait(30, function() return false end, 5)
				assert(vim.api.nvim_buf_is_loaded(first.bufnr))
				owned.create()
				assert(workspace.select(original) and chat.focus_view(first))
				assert(workspace.select(selected.id))
				chat.close_view(first)
				assert(not first.workspace_id and not first.suspended and #workspace.list() == 1)
				assert(workspace.current() == selected and current.visible)
				coherent()
			]], { enabled })
		end)

		for _, operation in ipairs({ "select", "close" }) do
			for _, prior in ipairs({ "unset", "false", "true" }) do
				it(("recovers native WinClosed errors: header=%s operation=%s guard=%s"):format(tostring(enabled), operation, prior), function()
					editor.lua([[
						local enabled, operation, prior = ...
						open(enabled)
						local file = filepane("wipe")
						filepane("delete")
						chat.create_layout(seed("recovery-b"))
						local other = workspace.current().id
						workspace.select(original)
						local closed = vim.fn.win_findbuf(file)[1]
						vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(closed), once = true,
							callback = function() error("native WinClosed failure") end })
						local previous
						if prior ~= "unset" then previous = prior == "true" end
						views.workspace.switching = previous
						local ok, err = pcall(function()
							if operation == "select" then workspace.select(other) else workspace.close_current() end
						end)
						assert(not ok and tostring(err):find("native WinClosed failure", 1, true), tostring(err))
						assert(views.workspace.switching == previous, "must restore the exact prior guard")
						assert(vim.api.nvim_buf_is_loaded(file) and vim.bo[file].modified and vim.bo[file].bufhidden == "wipe")
						assert(vim.api.nvim_buf_get_lines(file, 0, -1, false)[1] == "UNSAVED wipe")
						assert(workspace.select(original) and chat.focus_view(first))
						assert(not workspace.current().incomplete and not first.suspended)
						assert(workspace.select(other) and workspace.select(original))
						workspace.close_current()
						assert(views.workspace.switching == previous)
						coherent()
					]], { enabled, operation, prior })
				end)
			end
		end

		it("keeps the first layout usable when capture fails before any windows change: header=" .. tostring(enabled), function()
			editor.lua([[
				open(...)
				local win = first.winid
				local get = vim.api.nvim_get_option_value
				local armed = true
				vim.api.nvim_get_option_value = function(name, opts)
					if armed and opts and opts.win then
						armed = false
						return get("opencode_invalid_window_option", opts)
					end
					return get(name, opts)
				end
				local ok, err = pcall(chat.create_layout, seed("capture-b"))
				vim.api.nvim_get_option_value = get
				assert(not ok and tostring(err):find("opencode_invalid_window_option", 1, true), tostring(err))
				assert(first.winid == win and vim.api.nvim_win_is_valid(win), "failed capture must not destroy the only usable layout")
				assert(not workspace.current().incomplete and not first.suspended)
				assert(#workspace.list() == 1 and workspace.select(original) and chat.focus_view(first))
				chat.create_layout(seed("capture-c")); workspace.close_current()
				coherent()
			]], { enabled })
		end)

		for _, operation in ipairs({ "select", "close" }) do
			it("recovers a real E36 before disposing file/chat panes: header=" .. tostring(enabled) .. " " .. operation, function()
				editor.lua([[
					local enabled, operation = ...
					open(enabled)
					for i = 1, 5 do chat.create_split(chat.get_view(), seed("large-" .. i), "horizontal") end
					local second = chat.create_layout(seed("small-b"))
					local other = workspace.current().id
					local file = filepane("delete")
					vim.o.lines = 8
					local ok, err = pcall(function()
						if operation == "select" then workspace.select(original) else workspace.close_current() end
					end)
					assert(not ok and tostring(err):find("E36", 1, true), tostring(err))
					assert(not views.workspace.switching and workspace.current().id == other and not workspace.current().incomplete)
					assert(views.valid(second) and second.workspace_id == other and second.visible)
					assert(vim.api.nvim_buf_is_loaded(file) and vim.bo[file].modified and vim.bo[file].bufhidden == "delete")
					assert(vim.api.nvim_buf_get_lines(file, 0, -1, false)[1] == "UNSAVED delete")
					assert(workspace.select(other) and chat.focus_view(second))
					coherent()
					vim.o.lines = 60
					assert(workspace.select(original) and workspace.select(other))
					workspace.close_current()
					assert(workspace.current().id == original and not views.valid(second))
				]], { enabled, operation })
			end)
		end

		it("retains membership if cleanup of a failed new layout also fails: header=" .. tostring(enabled), function()
			editor.lua([[
				open(...)
				local set_option, for_view = vim.api.nvim_set_option_value, chat.for_view
				local failed, armed = nil, true
				chat.for_view = function(view)
					local owned = for_view(view)
					if view ~= first and not failed then
						failed = view
						local dispose = owned.dispose
						owned.dispose = function()
							owned.dispose = dispose
							vim.api.nvim_buf_delete(-1, { force = true })
						end
					end
					return owned
				end
				vim.api.nvim_set_option_value = function(name, value, opts)
					if armed and name == "winhighlight" and opts and opts.scope == "local" then
						armed = false
						return set_option("opencode_invalid_window_option", value, opts)
					end
					return set_option(name, value, opts)
				end
				local ok, err = pcall(chat.create_layout, seed("failed-new"))
				vim.api.nvim_set_option_value, chat.for_view = set_option, for_view
				assert(not ok and tostring(err):find("Could not dispose failed layout", 1, true), tostring(err))
				assert(tostring(err):find("opencode_invalid_window_option", 1, true) and tostring(err):find("Invalid buffer id", 1, true))
				assert(views.valid(failed) and failed.workspace_id and failed.suspended)
				assert(#workspace.list() == 2 and workspace.current().id == original and first.visible)
				assert(workspace.select(failed.workspace_id) and chat.focus_view(failed))
				workspace.close_current()
				assert(#workspace.list() == 1 and not views.valid(failed) and workspace.current().id == original)
				coherent()
			]], { enabled })
		end)

		for _, failure in ipairs({ 1, 2 }) do
			it("recovers partial disposal of the only layout: header=" .. tostring(enabled) .. " member=" .. failure, function()
				editor.lua([[
					local enabled, failure = ...
					open(enabled)
					local second = chat.create_split(first, seed("only-b"), "vertical")
					local failed = failure == 1 and first or second
					local owned, dispose = chat.for_view(failed)
					dispose = owned.dispose
					owned.dispose = function() vim.api.nvim_win_get_buf(-1) end
					local ok, err = pcall(workspace.close_current)
					owned.dispose = dispose
					assert(not ok and tostring(err):find("Invalid window id", 1, true), tostring(err))
					assert(not views.workspace.switching and failed.workspace_id == original)
					assert(workspace.select(original))
					assert(#vim.api.nvim_tabpage_list_wins(0) == 3 - failure)
					if failure == 2 then
						assert(not first.workspace_id and not views.for_session("recovery-a"))
						assert(workspace.current().root_view == second and workspace.current().last_view == second)
					end
					coherent()
					workspace.close_current()
					assert(#workspace.list() == 0 and not views.workspace.switching)
				]], { enabled, failure })
			end)
		end

		for _, operation in ipairs({ "close", "reset" }) do
			for _, failure in ipairs({ 1, 2 }) do
				it(("prunes partial %s after a native disposal API error: header=%s member=%d"):format(operation, tostring(enabled), failure), function()
					editor.lua([[
						local enabled, operation, failure = ...
						open(enabled)
						local second = chat.create_layout(seed("dispose-b"))
						local third = chat.create_split(second, seed("dispose-c"), "vertical")
						local closing = workspace.current().id
						if operation == "reset" then chat.create_layout(seed("dispose-visible")) end
						local visible = workspace.current()
						local failed = failure == 1 and second or third
						local owned = chat.for_view(failed)
						local dispose = owned.dispose
						owned.dispose = function()
							dispose() -- Fail after the real disposer has already done partial work.
							vim.api.nvim_buf_delete(-1, { force = true })
						end
						local ok, err = pcall(operation == "close" and workspace.close_current or workspace.reset)
						owned.dispose = dispose
						assert(not ok and tostring(err):find("Invalid buffer id", 1, true), tostring(err))
						assert(not views.workspace.switching and failed.workspace_id == closing and views.valid(failed))
						if failure == 2 then assert(not views.valid(second) and not second.workspace_id) end
						if operation == "reset" then assert(workspace.current() == visible and visible.last_view.visible) end
						workspace.select(closing)
						assert(#vim.api.nvim_tabpage_list_wins(0) == 3 - failure, "stale leaf resurrected a disposed view")
						if failure == 2 then assert(workspace.current().last_view == third and workspace.current().root_view == third) end
						workspace.close_current()
						if operation == "reset" then workspace.reset() end
						assert(not views.for_session("dispose-b") and not views.for_session("dispose-c"))
						coherent()
					]], { enabled, operation, failure })
				end)
			end
		end
	end
end)
