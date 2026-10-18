-- Compositional checks only: native protocol/state -> pane ownership -> workspace/UI.
describe("tab cross-group regressions", function()
	local editor, directory
	before_each(function()
		directory = vim.fn.tempname()
		vim.fn.mkdir(directory .. "/one", "p")
		vim.fn.mkdir(directory .. "/two", "p")
		directory = vim.uv.fs_realpath(directory)
		editor = require("tests.helpers.embedded_editor").new()
		editor.lua([[
			root = ...
			vim.o.lines, vim.o.columns = 60, 160
			vim.fn.chdir(root .. "/one")
			api, actions = require("opencode"), require("opencode.actions")
			app, sync = require("opencode.state"), require("opencode.sync")
			sessions, pending = require("opencode.session"), require("opencode.session.pending")
			chat, views = require("opencode.ui.chat"), require("opencode.ui.chat.state")
			workspace, input = require("opencode.ui.chat.workspace"), require("opencode.ui.input")
			history, client = require("opencode.ui.input.history"), require("opencode.client")
			events, projection = require("opencode.events"), require("opencode.protocol.messages")
			records, native_history, inboxes, requests, reviews, errors = {}, {}, {}, {}, {}, {}
			deleted, sequence = {}, 1000
			vim.notify = function(message, level)
				if level == vim.log.levels.ERROR then errors[#errors + 1] = tostring(message) end
			end
			function settle()
				vim.wait(40, function() return false end, 5)
				assert(#errors == 0, table.concat(errors, "\n"))
			end
			function event(kind, data)
				sequence = sequence + 1
				events.emit("server_event", { id = "evt-cross-" .. sequence, type = kind,
					created = sequence, location = { directory = root .. "/one" }, data = data })
			end
			function seed(id, parent)
				local record = { id = id, title = id, parentID = parent, location = { directory = root .. "/one" },
					agent = "build", model = { providerID = "test", modelID = "model" } }
				records[id] = record
				sessions.remember(record, { touch = not parent })
				return record
			end
			function load(id)
				local done = false
				actions.load_session_messages(id, function(err) assert(not err, vim.inspect(err)); done = true end)
				assert(vim.wait(500, function() return done end, 5), "history callback missing")
				settle()
			end
			function press(key)
				vim.cmd("stopinsert")
				local mapping = vim.fn.maparg(key, "n", false, true)
				assert(type(mapping.callback) == "function", "missing public mapping: " .. key)
				mapping.callback()
				settle()
			end
			function enqueue(id)
				local item = { type = "user", delivery = "queue", payload = { text = "Queued for " .. id } }
				inboxes[id] = { { id = id .. "-queued", sessionID = id, type = item.type,
					delivery = item.delivery, payload = item.payload, time = { created = sequence + 1 } } }
				event("session.inbox.enqueued", { sessionID = id, inboxID = id .. "-queued", item = item })
				return pending.token(id)
			end
			function launch(id, mid, call, child)
				local function emit(kind, data)
					event("session." .. kind, vim.tbl_extend("force", { sessionID = id, assistantMessageID = mid }, data))
				end
				emit("step.started", { started = sequence, agent = "build", model = { providerID = "test", id = "model" } })
				emit("tool.input.started", { id = call, name = child and "subagent" or "shell" })
				emit("tool.called", { id = call, input = child and { agent = "explore", prompt = "Inspect " .. child }
					or { command = "sleep 60" } })
				if child then
					emit("tool.success", { id = call, metadata = { sessionID = child }, content = { { type = "text", text = "Delegated" } } })
					emit("step.ended", { finish = "tool-calls" })
				end
				native_history[id] = native_history[id] or {}
				native_history[id][#native_history[id] + 1] = vim.deepcopy(sync.get_message(id, mid)._native)
				return projection.part_id(id, mid, "tool", call)
			end
			function filepane(name)
				vim.cmd("rightbelow vsplit")
				local buf, win = vim.api.nvim_create_buf(true, false), vim.api.nvim_get_current_win()
				vim.api.nvim_buf_set_name(buf, root .. "/" .. name .. ".lua")
				vim.api.nvim_win_set_buf(win, buf)
				vim.bo[buf].bufhidden, vim.bo[buf].filetype = "wipe", "lua"
				vim.bo[buf].tabstop, vim.bo[buf].shiftwidth, vim.bo[buf].expandtab = 3, 3, true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first unsaved line", "middle", "last unsaved line" })
				return buf, win
			end
			function file_state(buf)
				local result = { lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false) }
				for _, name in ipairs({ "bufhidden", "modified", "filetype", "tabstop", "shiftwidth", "expandtab", "modifiable", "readonly" }) do
					result[name] = vim.bo[buf][name]
				end
				return result
			end
			function resources()
				local timers = 0
				vim.uv.walk(function(handle)
					if handle:get_type() == "timer" and not handle:is_closing() and handle:is_active() then timers = timers + 1 end
				end)
				return { windows = #vim.api.nvim_list_wins(), buffers = #vim.api.nvim_list_bufs(), timers = timers }
			end
			function integrity()
				local layouts, owners = {}, {}
				for _, layout in ipairs(workspace.list()) do layouts[layout.id] = true end
				for _, view in ipairs(views.all()) do
					if view.workspace_id then assert(layouts[view.workspace_id], "orphan workspace view") end
					if view.visible or view.suspended then
						local id = views.session(view).id
						assert(not owners[id], "duplicate owner for " .. tostring(id)); owners[id] = view
						if view.visible then
							assert(vim.api.nvim_win_is_valid(view.winid) and vim.api.nvim_win_get_buf(view.winid) == view.bufnr, "ghost visible view")
						else assert(#views.windows(view) == 0, "suspended view left a native mirror") end
					end
				end
				assert(not views.workspace.switching, "switching guard was not released")
			end
			require("opencode.lifecycle").ensure_connected = function(callback) callback() end
			-- Stub transport replies, not projection/reducers, ownership, navigation or workspace cleanup.
			client.get_messages = function(id, _, callback) callback(nil, projection.page(id, native_history[id] or {})) end
			client.get_session = function(id, callback) callback(nil, vim.deepcopy(assert(records[id], "unknown server session " .. id))) end
			client.get_location = function(path, callback) callback(nil, { directory = path }) end
			client.get_session_statuses = function(callback) callback(nil, {}) end
			client.get_inbox = function(id, callback) callback(nil, vim.deepcopy(inboxes[id] or {})) end
			client.list_permissions = function(opts, callback) callback(nil, vim.deepcopy(requests[opts.session_id] or {})) end
			client.list_questions = function(_, callback) callback(nil, {}) end
			client.get_permission = function(id, request, callback)
				for _, item in ipairs(requests[id] or {}) do if item.id == request then callback(nil, vim.deepcopy(item)); return end end
				callback({ status = 404 })
			end
			client.review_rpc = function(method, params, _, callback)
				if method == "capabilities" then callback(nil, { protocolVersion = 2, review = true })
				elseif method == "policyList" then callback(nil, {})
				elseif method == "reviewList" then callback(nil, { reviews = vim.deepcopy(reviews[params.sessionID] or {}) })
				else error("unexpected review RPC " .. method) end
			end
			client.delete_session = function(id, callback) deleted[#deleted + 1] = id; callback(nil, true) end
			api.setup({ server = { auto_start = false, shared_filesystem = true }, lualine = { enabled = false },
				input = { history_file = root .. "/history.json" },
				chat = { layout = "tab", session_tabs = { scope = "cwd", file = root .. "/tabs.json" } } })
			seed("cross-source"); sessions.set_active("cross-source", "cross-source", { preserve_cache = true })
			chat.open(); settle()
			first, original = chat.get_view(), workspace.current().id
		]], { directory })
	end)
	after_each(function()
		if editor then editor.close(); editor = nil end
		if directory then vim.fn.delete(directory, "rf"); directory = nil end
	end)

	it("closes a protocol-projected fork layout without clearing its source child's live work", function()
		editor.lua([[
			seed("cross-child", "cross-source")
			native_history["cross-child"] = { { id = "msg-child", type = "assistant", time = { created = 1, completed = 2 },
				content = { { type = "text", text = "Source child transcript" } } } }
			load("cross-child")
			local token = enqueue("cross-child")
			requests["cross-child"] = { { id = "cross-permission", sessionID = "cross-child", action = "shell",
				resources = { "echo source" }, metadata = { tool = "shell", input = { command = "echo source" } } } }
			event("permission.asked", requests["cross-child"][1])
			local part = launch("cross-source", "msg-source-launch", "source-launch", "cross-child")
			chat.for_view(first).do_render(); settle()
			assert(first.tasks[part], "native launch must render a navigable task")
			vim.api.nvim_win_set_cursor(first.winid, { first.tasks[part].start_line + 1, 0 })
			press("gd")
			assert(views.session(first).id == "cross-child", "gd must use the real child navigation flow")
			local before = { metadata = app.get_session_record("cross-child"), messages = vim.deepcopy(sync.get_messages("cross-child")),
				parts = vim.deepcopy(sync.get_parts("msg-child")), pending = pending.list("cross-child"),
				permission = vim.deepcopy(require("opencode.permission.state").get_permission("cross-permission")) }
			assert(before.permission and before.permission.status == "pending")
			client.fork_session = function(id, _, callback)
				assert(id == "cross-source")
				records["cross-fork"] = { id = "cross-fork", title = "Fork", location = records[id].location,
					fork = { sessionID = id, boundary = { type = "after", messageID = "msg-source-launch" } } }
				-- The native server changes message identity, not the copied tool metadata.
				native_history["cross-fork"] = vim.deepcopy(native_history[id])
				native_history["cross-fork"][1].id = "msg-fork-copy"
				event("session.forked", { sessionID = "cross-fork", parentID = id,
					boundary = records["cross-fork"].fork.boundary })
				callback(nil, vim.deepcopy(records["cross-fork"]))
			end
			local opened = false
			actions.fork_session("cross-source", {}, function(err, fork)
				assert(not err, vim.inspect(err))
				actions.open_session(fork.id, { view = first }, function(open_err) assert(not open_err, vim.inspect(open_err)); opened = true end)
			end)
			assert(vim.wait(500, function() return opened end, 5)); settle()
			local fork = views.for_session("cross-fork")
			assert(fork and fork.workspace_id ~= original and first.suspended)
			local copied = projection.part_id("cross-fork", "msg-fork-copy", "tool", "source-launch")
			assert(sync.get_task_child_session("msg-fork-copy", copied) == "cross-child")
			seed("cross-fork-child", "cross-fork")
			launch("cross-fork", "msg-fork-launch", "fork-launch", "cross-fork-child")
			native_history["cross-fork-child"] = { { id = "msg-fork-child", type = "assistant", time = { created = 3, completed = 4 },
				content = { { type = "text", text = "Fork child committed transcript" } } } }
			load("cross-fork-child")
			local own_message, own_parts = sync.get_message("cross-fork-child", "msg-fork-child"), sync.get_parts("msg-fork-child")
			assert(own_message and own_message.role == "assistant" and not own_message.provisional and own_message.time.completed == 4,
				"fork descendant must have committed native history before close")
			assert(#own_parts == 1 and own_parts[1].id == projection.part_id("cross-fork-child", "msg-fork-child", "text", 0)
				and own_parts[1].text == "Fork child committed transcript", "committed descendant part missing")
			local own_token = enqueue("cross-fork-child")
			requests["cross-fork-child"] = { { id = "cross-fork-permission", sessionID = "cross-fork-child", action = "shell",
				resources = { "echo fork child" }, metadata = { tool = "shell", input = { command = "echo fork child" } } } }
			event("permission.asked", requests["cross-fork-child"][1]); settle()
			local permissions = require("opencode.permission.state")
			local own_permission = permissions.get_permission("cross-fork-permission")
			assert(own_permission and own_permission.session_id == "cross-fork-child" and own_permission.status == "pending",
				"fork descendant must have its own pending permission before close")
			assert(app.get_session_pending_counts("cross-fork").permissions == 1)
			assert(#sync.get_messages("cross-fork-child") == 2 and pending.get("cross-fork-child", "cross-fork-child-queued").status == "queued")
			assert(vim.deep_equal({ "cross-fork", "cross-fork-child" }, sync.collect_session_tree("cross-fork")))
			press("x")
			assert(workspace.current().id == original and views.session(first).id == "cross-child")
			assert(vim.deep_equal(before.metadata, app.get_session_record("cross-child")), "source metadata changed")
			assert(vim.deep_equal(before.messages, sync.get_messages("cross-child")), "source transcript changed")
			assert(vim.deep_equal(before.parts, sync.get_parts("msg-child")))
			assert(vim.deep_equal(before.pending, pending.list("cross-child")))
			assert(vim.deep_equal(before.permission, require("opencode.permission.state").get_permission("cross-permission")))
			assert(pending.is_current(token) and app.get_session_pending_counts("cross-source").permissions == 1)
			assert(sync.get_task_parent_session("cross-child") == "cross-source")
			assert(#sync.get_messages("cross-fork-child") == 0 and next(pending.list("cross-fork-child")) == nil)
			assert(sync.get_message("cross-fork-child", "msg-fork-child") == nil and #sync.get_parts("msg-fork-child") == 0,
				"local close must clear the fork descendant's committed history and parts")
			assert(not pending.is_current(own_token) and not views.for_session("cross-fork"))
			assert(records["cross-fork"] and records["cross-fork-child"] and #deleted == 0, "x must not delete server sessions")
			integrity()
			-- Local close drops runtime caches, not unanswered requests or their user notes needed on reopen.
			assert(permissions.get_permission("cross-fork-permission") == own_permission and own_permission.status == "pending"
				and own_permission.reply == nil and not own_permission.submitting,
				"local close must preserve own descendant pending permission without replying or deleting it")
		]])
	end)

	it("roundtrips an unsaved wipe file, native locations and its chat draft through layout close", function()
		editor.lua([[
			chat.focus_input()
			local draft, attachments = "Normal draft\nSecond line", { { type = "file", url = "file:///cross-context.lua", filename = "cross-context.lua" } }
			input.set_pending_draft(draft, attachments)
			vim.api.nvim_win_set_cursor(input.get_winids()[1], { 2, 3 }); input.close()
			local file, owner = filepane("locations")
			local expected_file, callbacks = file_state(file), 0
			function _G.CrossGroupLocations(info)
				callbacks = callbacks + 1
				local rows = {}; for i = info.start_idx, info.end_idx do rows[#rows + 1] = "custom diagnostic " .. i end
				return rows
			end
			assert(vim.fn.setloclist(owner, {}, "r", { items = {
				{ bufnr = file, lnum = 1, col = 1, text = "first" }, { bufnr = file, lnum = 3, col = 2, text = "last" },
			}, idx = 2, title = "Cross-group locations", context = { session = "cross-source", nested = { 7, 9 } },
				quickfixtextfunc = "v:lua.CrossGroupLocations" }) == 0)
			vim.cmd("belowright 4lopen")
			local query = { items = 0, idx = 0, title = 0, context = 0, quickfixtextfunc = 0 }
			local expected_list = vim.fn.getloclist(owner, query)
			local expected_rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
			local function check()
				assert(vim.api.nvim_buf_is_loaded(file) and vim.deep_equal(expected_file, file_state(file)), "unsaved file/options lost")
				local restored = assert(vim.fn.win_findbuf(file)[1], "file owner missing")
				assert(vim.deep_equal(expected_list, vim.fn.getloclist(restored, query)), "native list data changed")
				local list = vim.fn.getloclist(restored, { winid = 0 }).winid
				assert(list ~= 0 and vim.fn.getwininfo(list)[1].loclist == 1)
				assert(vim.fn.getloclist(list, { filewinid = 0 }).filewinid == restored, "native list owner changed")
				assert(vim.deep_equal(expected_rows, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(list), 0, -1, false)))
				assert(vim.api.nvim_get_current_win() == list, "location-list focus was not restored")
			end
			local second = chat.create_layout(seed("cross-locations-other"))
			for i = 1, 3 do
				assert(workspace.select(original)); settle(); check()
				assert(workspace.select(second.workspace_id))
				chat.create_layout(seed("cross-locations-close-" .. i)); press("x")
				assert(views.current() == second)
			end
			assert(workspace.select(original)); settle(); check()
			assert(callbacks > 1, "restored native lists must execute their text callback")
			chat.focus_view(first); chat.focus_input(); settle()
			assert(input.get_pending_text() == draft and vim.deep_equal(attachments, input.get_pending_parts()))
			assert(vim.deep_equal({ 2, 3 }, vim.api.nvim_win_get_cursor(input.get_winids()[1])))
			input.close(); chat.focus_view(first); press("q")
			local list = vim.fn.getloclist(vim.fn.win_findbuf(file)[1], { winid = 0 }).winid
			vim.api.nvim_set_current_win(list)
			assert(workspace.select(second.workspace_id)); press("x")
			check()
			assert(history.get_pending("cross-source") == draft and vim.deep_equal(expected_file, file_state(file)))
			integrity()
		]])
	end)

	it("keeps a native diff note and the underlying draft when a late catalog result restores layouts", function()
		editor.lua([[
			local remote, response, completed = seed("cross-catalog-remote")
			client.get_location = function(path, callback) response = function() callback(nil, { directory = path }) end end
			actions.open_session(remote.id, { view = first }, function(err) assert(not err, vim.inspect(err)); completed = true end)
			assert(response, "catalog location request must be in flight")
			local other = chat.create_layout(seed("cross-review"))
			local selected = workspace.current().id
			chat.focus_input()
			local draft, parts = "Underlying normal draft\nKeep attachments", { { type = "file", url = "file:///cross-draft.lua", filename = "cross-draft.lua" } }
			input.set_pending_draft(draft, parts, { options = { delivery = "steer" } })
			vim.api.nvim_win_set_cursor(input.get_winids()[1], { 2, 4 }); input.close()
			local path = root .. "/review.lua"
			vim.fn.writefile({ "before" }, path)
			local review = { protocolVersion = 2, reviewID = "cross-review-note", revision = 1,
				sessionID = other.session_id, status = "pending", created = sequence,
				location = { directory = root .. "/one" }, files = {
					{ fileID = "file", filePath = path, before = "before\n", after = "after\n" },
				} }
			reviews[other.session_id] = { review }
			event("rpc.opencode_nvim.review.created", { sessionID = other.session_id, review = review })
			chat.for_view(other).do_render(); settle()
			local position = assert(other.edits[review.reviewID], "native review must render")
			vim.api.nvim_win_set_cursor(other.winid, { position.start_line + 1, 0 }); press("dt")
			local diff = require("opencode.ui.native_diff")
			assert(diff.is_active(), "dt must open the real native diff")
			local diff_tab = vim.api.nvim_get_current_tabpage()
			press(require("opencode.util.keymap").label("native_diff", "note"))
			local note = "Unsaved diff note\nSecond note line"
			local note_buf = vim.api.nvim_win_get_buf(input.get_winids()[1])
			vim.api.nvim_buf_set_lines(note_buf, 0, -1, false, vim.split(note, "\n", { plain = true }))
			vim.api.nvim_win_set_cursor(input.get_winids()[1], { 2, 5 })
			response(); settle()
			assert(completed and views.for_session(remote.id), "late catalog result must still open in the background")
			assert(workspace.current().id == selected and first.suspended and first.session_id == "cross-source")
			assert(diff.is_active() and vim.api.nvim_get_current_tabpage() == diff_tab, "catalog stole native diff focus")
			assert(input.is_visible() and input.owner_view() == other and input.get_winids()[1] == vim.api.nvim_get_current_win())
			assert(input.get_pending_text() == note and vim.deep_equal({ 2, 5 }, vim.api.nvim_win_get_cursor(0)))
			assert(history.get_pending(other.session_id) == draft and vim.deep_equal(parts, history.get_pending_parts(other.session_id)))
			press("<C-g>")
			assert(require("opencode.edit.state").get_edit(review.reviewID).message == note, "real native diff submit callback was lost")
			assert(not input.is_visible() and vim.api.nvim_get_current_tabpage() == diff_tab)
			-- Native diff close itself restores the normal composer; do not refocus it twice.
			diff.close(); settle()
			assert(input.is_visible() and input.owner_view() == other, "native diff close must reopen its normal draft")
			assert(input.get_pending_text() == draft and vim.deep_equal(parts, input.get_pending_parts()))
			assert(vim.deep_equal({ delivery = "steer" }, input.get_pending_options()))
			assert(vim.deep_equal({ 2, 4 }, vim.api.nvim_win_get_cursor(input.get_winids()[1])))
			assert(#input.get_history() == 0, "temporary note must not enter normal prompt history")
		]])
	end)

	it("keeps cwd-scoped hidden and file-only layouts usable after a failed restore", function()
		editor.lua([[
			history.set_pending("Hidden source draft", {}, "cross-source")
			local other = chat.create_layout(seed("cross-file-only"))
			local selected = workspace.current().id
			local file = filepane("cwd-file")
			local expected = file_state(file)
			chat.focus_view(other); press("q")
			assert(first.suspended and not other.visible and #workspace.list() == 2)
			local order, token = app.get_runtime_session_order(), pending.token("cross-source")
			vim.cmd.cd(root .. "/two"); require("opencode.session.tabs").refresh_scope(); settle()
			assert(vim.deep_equal(order, app.get_runtime_session_order()) and #workspace.list() == 2)
			local set_buf, injected = vim.api.nvim_win_set_buf, false
			vim.api.nvim_win_set_buf = function(...)
				if not injected then injected = true; error("cross-group injected restore failure") end
				return set_buf(...)
			end
			local ok, err = pcall(workspace.select, original)
			vim.api.nvim_win_set_buf = set_buf
			assert(not ok and tostring(err):find("cross-group injected restore failure", 1, true), tostring(err))
			assert(workspace.current().id == selected and not views.workspace.switching)
			assert(vim.deep_equal(order, app.get_runtime_session_order()) and pending.is_current(token))
			assert(vim.deep_equal(expected, file_state(file)))
			for _ = 1, 3 do
				assert(workspace.select(original)); settle()
				assert(first.visible and vim.api.nvim_get_current_buf() == first.bufnr)
				assert(history.get_pending("cross-source") == "Hidden source draft")
				assert(workspace.select(selected)); settle()
				assert(vim.api.nvim_get_current_buf() == file and vim.deep_equal(expected, file_state(file)))
			end
			local scopes = require("opencode.util.json_file").read(root .. "/tabs.json").scopes
			assert(vim.tbl_count(scopes) == 1, "cwd change must not persist hidden workspace sessions under a new scope")
			integrity()
		]])
	end)

	for _, operation in ipairs({ "close", "reset" }) do
		it("retries a partial " .. operation .. " with live work and editor state without ghosts or resource growth", function()
			editor.lua([[
				local operation = ...
				local second = chat.create_layout(seed("cross-retry-work"))
				local third = chat.create_split(second, seed("cross-retry-peer"), "vertical")
				local layout = workspace.current().id
				launch(third.session_id, "msg-running-shell", "running-shell")
				chat.for_view(third).do_render(); settle()
				local timer = assert(third.task_anim_timer, "running native shell must own a real animation timer")
				local token = enqueue(third.session_id)
				chat.focus_view(third); chat.focus_input()
				local parts = { { type = "file", url = "file:///retry-context.lua", filename = "retry-context.lua" } }
				input.set_pending_draft("Retry draft", parts)
				vim.api.nvim_win_set_cursor(input.get_winids()[1], { 1, 3 }); input.close()
				chat.focus_view(third); vim.cmd("vsplit")
				assert(#views.windows(third) == 2, "fixture must contain a real native chat mirror")
				local file = filepane("retry-file")
				local expected = file_state(file)
				local current = chat.create_layout(seed("cross-retry-current"))
				local current_layout = workspace.current().id
				if operation == "close" then assert(workspace.select(layout)) end
				settle()
				local ceiling = resources()
				local owned = chat.for_view(third)
				local dispose = owned.dispose
				owned.dispose = function() error("cross-group injected disposal failure") end
				local ok, err = pcall(operation == "close" and workspace.close_current or workspace.reset)
				owned.dispose = dispose
				assert(not ok and tostring(err):find("cross-group injected disposal failure", 1, true), tostring(err))
				settle(); integrity()
				assert(not views.valid(second) and views.valid(third), "only successfully disposed members may be pruned")
				assert(pending.is_current(token) and pending.get(third.session_id, third.session_id .. "-queued").status == "queued")
				assert(vim.deep_equal(expected, file_state(file)))
				assert(history.get_pending(third.session_id) == "Retry draft" and vim.deep_equal(parts, history.get_pending_parts(third.session_id)))
				assert(workspace.select(layout)); settle(); integrity()
				assert(#views.windows(third) == 2 and not views.for_session(second.session_id), "partial disposal left a ghost pane")
				assert(#vim.api.nvim_tabpage_list_wins(0) == 3, "retry must contain only two mirrors and the file")
				chat.focus_view(third); chat.focus_input(); settle()
				assert(input.get_pending_text() == "Retry draft" and vim.deep_equal({ 1, 3 }, vim.api.nvim_win_get_cursor(input.get_winids()[1])))
				input.close()
				if operation == "close" then
					workspace.close_current(); settle()
					assert(not pending.is_current(token) and next(pending.list(third.session_id)) == nil)
				else
					assert(workspace.select(current_layout)); workspace.reset(); settle()
					assert(#workspace.list() == 0 and current.visible and not current.workspace_id)
				end
				assert(not views.valid(third) and not views.for_session(third.session_id))
				assert(timer:is_closing() and not third.task_anim_timer, "disposed view leaked its animation timer")
				assert(not vim.api.nvim_buf_is_valid(second.bufnr) and not vim.api.nvim_buf_is_valid(third.bufnr))
				assert(vim.deep_equal(expected, file_state(file)) and #deleted == 0)
				integrity()
				-- Warm a healthy transition once, then require a fixed resource bound on repeats.
				chat.focus_view(current)
				if operation == "reset" then workspace.ensure(current) end
				local healthy = chat.create_layout(seed("cross-retry-healthy"))
				assert(workspace.select(current.workspace_id)); assert(workspace.select(healthy.workspace_id)); settle()
				local bound = resources()
				for _ = 1, 3 do
					assert(workspace.select(current.workspace_id)); assert(workspace.select(healthy.workspace_id)); settle(); integrity()
					assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "healthy layout must not inherit ghost panes")
					local actual = resources()
					assert(actual.windows <= bound.windows and actual.buffers <= bound.buffers and actual.timers <= bound.timers,
						"retry caused unbounded resources: " .. vim.inspect({ bound = bound, actual = actual }))
				end
				local final = resources()
				assert(final.windows <= ceiling.windows + 2 and final.buffers <= ceiling.buffers + 2 and final.timers <= ceiling.timers)
			]], { operation })
		end)
	end
end)
