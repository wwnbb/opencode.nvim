describe("composer pane ownership", function()
	local input = require("opencode.ui.input")
	local history = require("opencode.ui.input.history")
	local app = require("opencode.state")
	local views = require("opencode.ui.chat.state")
	local panes, original_tab, tab, original_config, original_session, history_file
	local saved

	local function flush()
		local done = false
		vim.schedule(function() done = true end)
		assert.is_true(vim.wait(500, function() return done end, 5))
	end

	local function pane(id)
		local view = views.new()
		view.session_id, view.visible = id, true
		view.winid = vim.api.nvim_get_current_win()
		view.bufnr = vim.api.nvim_create_buf(false, true)
		vim.bo[view.bufnr].filetype = "opencode"
		vim.api.nvim_win_set_buf(view.winid, view.bufnr)
		panes[#panes + 1] = view
		return view
	end

	local function open(view, opts)
		app.set_session(view.session_id, view.session_id, { runtime = false })
		vim.api.nvim_set_current_win(view.winid)
		input.show(vim.tbl_extend("force", { view = view, session_id = view.session_id }, opts or {}))
		return input.get_winids()[1]
	end

	before_each(function()
		original_tab, original_config, original_session = vim.api.nvim_get_current_tabpage(), app.get_config(), app.get_session()
		history_file, panes = vim.fn.tempname(), {}
		saved = {}
		local cfg = vim.deepcopy(require("opencode.config").defaults)
		cfg.input.history_file = history_file
		app.set_config(cfg)
		history.configure(cfg.input); history.clear()
		vim.cmd("tabnew")
		tab = vim.api.nvim_get_current_tabpage()
		pane("pane-a")
		vim.cmd("vsplit")
		pane("pane-b")
	end)

	after_each(function()
		for _, entry in ipairs(saved) do entry[1][entry[2]] = entry[3] end
		input.close(false)
		for _, view in ipairs(panes) do views.remove(view) end
		if vim.api.nvim_tabpage_is_valid(tab) then
			vim.api.nvim_set_current_tabpage(tab)
			vim.cmd("tabclose!")
		end
		vim.api.nvim_set_current_tabpage(original_tab)
		for _, view in ipairs(panes) do
			if vim.api.nvim_buf_is_valid(view.bufnr) then vim.api.nvim_buf_delete(view.bufnr, { force = true }) end
		end
		history.clear()
		app.set_session(original_session.id, original_session.name, { runtime = false })
		app.set_config(original_config)
		flush()
	end)

	local function replace(module, name, fn)
		saved[#saved + 1] = { module, name, module[name] }
		module[name] = fn
	end

	it("discards clipboard results when the read opens another pane's composer", function()
		local a, b = panes[1], panes[2]
		open(a, { text = "Alpha" })
		replace(require("opencode.clipboard"), "read", function()
			open(b, { text = "Beta" })
			return { mime = "image/png", data = "YQ==", filename = "paste.png" }
		end)
		assert.is_false(input.paste_clipboard())
		assert.equals("Beta", input.get_pending_text())
		assert.same({}, input.get_pending_parts())
		assert.equals("Alpha", history.get_pending(a.session_id))
		assert.same({}, history.get_pending_parts(a.session_id))
	end)

	it("keeps rejected composer attachments separate from another session's hidden draft", function()
		vim.cmd("rightbelow split")
		local a, b = pane("failed-a"), panes[2]
		vim.api.nvim_win_set_height(a.winid, 3)
		local function image(name)
			return { type = "file", filename = name, mime = "image/png", url = "data:image/png;base64,YQ==", _marker = "[Image 1]" }
		end
		history.set_pending("[Image 1]", { image("b-existing.png") }, b.session_id)
		app.set_session(a.session_id, "A", { runtime = false })
		assert.is_false(input.show({ view = a, session_id = a.session_id, text = "[Image 1]", parts = { image("a.png") } }))
		assert.is_nil(input.owner_view())
		assert.equals("a.png", history.get_pending_parts(a.session_id)[1].filename)
		app.set_session(b.session_id, "B", { runtime = false })
		replace(require("opencode.clipboard"), "read", function()
			return { mime = "image/png", data = "Yg==", filename = "b-new.png" }
		end)
		assert.is_true(input.paste_clipboard())
		local parts = history.get_pending_parts(b.session_id)
		assert.equals(2, #parts)
		assert.equals("b-existing.png", parts[1].filename)
		assert.equals("b-new.png", parts[2].filename)
	end)

	it("reloads attachments when pasting into hidden drafts in different sessions", function()
		local a, b = panes[1], panes[2]
		history.set_pending("[Image 1]", { { type = "file", filename = "b-original.png",
			url = "data:image/png;base64,Yg==", _marker = "[Image 1]" } }, b.session_id)
		local content = { mime = "image/png", data = "YQ==", filename = "a-private.png" }
		replace(require("opencode.clipboard"), "read", function() return content end)
		app.set_session(a.session_id, "A", { runtime = false })
		assert.is_true(input.paste_clipboard())
		app.set_session(b.session_id, "B", { runtime = false })
		content = { mime = "image/png", data = "Yw==", filename = "b-new.png" }
		assert.is_true(input.paste_clipboard())
		local parts = history.get_pending_parts(b.session_id)
		assert.equals(2, #parts)
		assert.equals("b-original.png", parts[1].filename)
		assert.equals("data:image/png;base64,Yg==", parts[1].url)
		assert.equals("b-new.png", parts[2].filename)
		assert.equals("a-private.png", history.get_pending_parts(a.session_id)[1].filename)
	end)

	it("keeps a long draft inside its pane and scrollable after shrinking", function()
		vim.cmd("rightbelow split")
		local view = pane("pane-small")
		vim.api.nvim_win_set_height(view.winid, 12)
		local lines = {}; for i = 1, 40 do lines[i] = "Draft line " .. i end
		local win = open(view, { text = table.concat(lines, "\n") })
		flush()
		local function fits()
			vim.cmd("redraw!")
			local top = vim.api.nvim_win_get_position(view.winid)[1]
			local bottom = top + vim.api.nvim_win_get_height(view.winid)
			for _, id in ipairs(input.get_winids()) do
				local pos = vim.api.nvim_win_get_position(id)
				assert.is_true(pos[1] >= top)
				assert.is_true(pos[1] + vim.api.nvim_win_get_height(id) <= bottom,
					vim.inspect({ top = top, bottom = bottom, child = pos[1], height = vim.api.nvim_win_get_height(id) }))
			end
		end
		fits()
		vim.api.nvim_win_set_cursor(win, { 30, 0 })
		vim.cmd("normal! zt")
		local scroll = vim.fn.winsaveview().topline
		assert.is_true(scroll > 1)
		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = vim.api.nvim_win_get_buf(win) })
		flush()
		assert.equals(scroll, vim.fn.winsaveview().topline)
		vim.api.nvim_win_set_height(view.winid, 8)
		vim.api.nvim_exec_autocmds("WinResized", { data = { windows = { view.winid } } })
		flush()
		fits()
		assert.equals(win, vim.api.nvim_get_current_win())
		assert.equals(table.concat(lines, "\n"), input.get_pending_text())
		vim.api.nvim_win_set_height(view.winid, 3)
		vim.api.nvim_exec_autocmds("WinResized", { data = { windows = { view.winid } } })
		flush()
		assert.is_false(input.is_visible())
		assert.equals(table.concat(lines, "\n"), history.get_pending(view.session_id))
		assert.is_false(input.show({ view = view, session_id = view.session_id }))
		history.clear_pending(view.session_id)
		local draft = { text = "Deferred prompt", parts = { { type = "file", url = "file:///tmp/a" } }, mode = "shell", options = { tag = "saved" } }
		history.defer_pending(draft, view.session_id)
		vim.api.nvim_set_current_win(view.winid)
		views.activate(view)
		assert.is_true(views.module(view, require("opencode.ui.chat.pending_inputs")).resume_edit())
		assert.is_false(input.is_visible())
		assert.equals(draft.text, history.get_pending(view.session_id))
		assert.same(draft.parts, history.get_pending_parts(view.session_id))
		assert.equals(draft.mode, history.get_pending_mode(view.session_id))
		assert.same(draft.options, history.get_pending_options(view.session_id))
	end)

	it("defers a recovered queued draft when another pane owns the composer", function()
		local a, b = panes[1], panes[2]
		open(b, { text = "Beta" })
		local pending = views.module(a, require("opencode.ui.chat.pending_inputs"))
		local draft = { text = "Recovered Alpha", parts = {}, mode = "shell", options = { delivery = "queue" } }
		pending.restore_draft(draft, a.session_id)
		assert.equals("Beta", input.get_pending_text())
		assert.equals(b, input.owner_view())
		assert.same(draft, history.peek_deferred(a.session_id))
		assert.is_nil(history.peek_deferred(b.session_id))
	end)

	it("defers a late queued edit and resumes it in its original pane", function()
		local a, b = panes[1], panes[2]
		app.set_session(a.session_id, a.session_id, { runtime = false })
		vim.api.nvim_set_current_win(a.winid)
		views.activate(a)
		replace(views.module(a, require("opencode.ui.chat.widget_support")), "find_widget_context_at_cursor", function() return "queued-a" end)
		replace(require("opencode.selectors"), "pending_input", function() return { status = "queued" } end)
		local callback
		replace(require("opencode.actions"), "edit_pending_input", function(_, _, cb) callback = cb end)
		local pending = views.module(a, require("opencode.ui.chat.pending_inputs"))
		assert.is_true(pending.handle("edit"))
		open(b, { text = "Beta" })
		local draft = { text = "Queued Alpha", parts = { { type = "file", url = "file:///tmp/a" } }, mode = "normal", options = { delivery = "steer" } }
		callback(nil, draft)
		assert.equals("Beta", input.get_pending_text())
		assert.same(draft, history.peek_deferred(a.session_id))
		input.close()
		app.set_session(a.session_id, a.session_id, { runtime = false })
		vim.api.nvim_set_current_win(a.winid)
		views.activate(a)
		assert.is_true(pending.resume_edit())
		assert.equals(a, input.owner_view())
		assert.equals("Queued Alpha", input.get_pending_text())
		assert.same(draft.parts, input.get_pending_parts())
	end)

	it("keeps independent drafts and ignores another pane's close or stale send", function()
		local a, b = panes[1], panes[2]
		local parts = { { type = "file", filename = "reference.txt", url = "file:///tmp/reference.txt" } }
		local sent = 0
		local win = open(a, { text = "Alpha\nsecond line", parts = parts, mode = "shell", send_options = { delivery = "queue" },
			on_send = function() sent = sent + 1 end })
		vim.api.nvim_win_set_cursor(win, { 2, 3 })
		local stale_send = vim.fn.maparg("<C-g>", "n", false, true).callback
		input.close_for_view(b)
		assert.equals(a, input.owner_view())
		assert.is_true(input.is_visible())

		open(b, { text = "Beta", on_send = function() sent = sent + 1 end })
		stale_send()
		flush()
		assert.equals(0, sent)
		assert.equals(b, input.owner_view())
		assert.equals("Beta", input.get_pending_text())
		assert.equals("Alpha\nsecond line", history.get_pending("pane-a"))
		assert.same(parts, history.get_pending_parts("pane-a"))
		assert.equals("shell", history.get_pending_mode("pane-a"))
		assert.same({ delivery = "queue" }, history.get_pending_options("pane-a"))

		win = open(a)
		flush()
		assert.equals("Beta", history.get_pending("pane-b"))
		assert.equals("Alpha\nsecond line", input.get_pending_text())
		assert.same({ 2, 3 }, vim.api.nvim_win_get_cursor(win))
		input.close_for_view(a)
		assert.is_false(input.is_visible())
	end)

	it("saves input before native tab closure wipes its buffer", function()
		local view = panes[1]
		local win = open(view, { text = "Native close draft", mode = "shell", send_options = { delivery = "steer" } })
		vim.api.nvim_win_set_cursor(win, { 1, 6 })
		vim.cmd("tabclose!")
		flush()
		assert.is_false(input.is_visible())
		assert.equals("Native close draft", history.get_pending("pane-a"))
		assert.equals("shell", history.get_pending_mode("pane-a"))
		assert.same({ delivery = "steer" }, history.get_pending_options("pane-a"))
		assert.equals(6, history.get_pending_cursor("pane-a"))
		assert.equals(0, #vim.api.nvim_get_autocmds({ group = "OpenCodeInputResize" }))
	end)

	it("rejects callbacks after the owning view generation changes", function()
		local view = panes[1]
		local sent = 0
		open(view, { text = "Kept after removal", on_send = function() sent = sent + 1 end })
		local send = vim.fn.maparg("<C-g>", "n", false, true).callback
		views.remove(view)
		send()
		assert.equals(0, sent)
		assert.is_false(input.focus())
		assert.equals("Kept after removal", history.get_pending("pane-a"))
	end)

	it("keeps history navigation positions per session across composer openings", function()
		history.add("First", {}, "normal", "pane-a")
		history.add("Second", {}, "normal", "pane-a")
		history.add("Third", {}, "normal", "pane-a")
		assert.equals("Third", history.previous(nil, nil, nil, "pane-a"))
		assert.equals("Second", history.previous("Third", {}, "normal", "pane-a"))
		assert.equals("Third", history.previous(nil, nil, nil, "pane-b"))
		history.configure(app.get_config().input)
		assert.equals("First", history.previous("Second", {}, "normal", "pane-a"))
		assert.equals("", history.next("Third", {}, "normal", "pane-b"))
		assert.equals("Second", history.next("First", {}, "normal", "pane-a"))
	end)
end)
