describe("upstream navigation callers and review notes", function()
	local editor
	after_each(function() if editor then editor.close(); editor = nil end end)
	for _, route in ipairs({ "reopen-connect", "new-location", "session-picker", "undo-revert", "workspace-create",
		"palette-connect", "timeline-revert-native", "timeline-fork" }) do
		for _, delayed in ipairs({ false, true }) do
			it(route .. " keeps foreground behavior and later notes (delayed=" .. tostring(delayed) .. ")", function()
				editor = require("tests.helpers.embedded_editor").new()
				editor.lua([[
					local route, delayed = ...
					vim.o.lines, vim.o.columns = 55, 160
					local api, app, sessions = require("opencode"), require("opencode.state"), require("opencode.session")
					local chat, views, input = require("opencode.ui.chat"), require("opencode.ui.chat.state"), require("opencode.ui.input")
					local client, lifecycle, edits = require("opencode.client"), require("opencode.lifecycle"), require("opencode.edit.state")
					local sync, history = require("opencode.sync"), require("opencode.ui.input.history")
					local errors = {}
					vim.notify = function(message, level) if level == vim.log.levels.ERROR then errors[#errors + 1] = tostring(message) end end
					api.setup({ server = { auto_start = false, shared_filesystem = route == "timeline-revert-native" or nil }, lualine = { enabled = false },
						chat = { layout = "tab" }, input = { history_file = vim.fn.tempname() .. "-history.json" } })
					lifecycle.ensure_connected = function(callback) callback() end
					client.get_messages = function(_, _, callback) callback(nil, {}) end
					client.get_session_statuses = function(callback) callback(nil, {}) end
					local source = { id = "upstream-source", title = "Source", location = { directory = vim.fn.getcwd() } }
					local target = { id = "upstream-target", title = "Fresh target", location = source.location,
						model = { providerID = "upstream", modelID = "model" } }
					sessions.remember(source); sessions.set_active(source.id, source.title); chat.open()
					local view = chat.get_view()
					local messages = require("opencode.protocol.messages").page(source.id, {
						{ id = "upstream-turn", type = "user", text = "Historical prompt", time = { created = 1 },
							files = { { uri = "file:///historical.lua", name = "historical.lua", mime = "text/plain" } } },
					})
					sync.handle_session_messages(source.id, messages)
					client.get_messages = function(id, _, callback) callback(nil, id == source.id and messages or {}) end
					client.get_session = function(id, callback) callback(nil, id == source.id and source or target) end
					client.get_location = function(directory, callback) callback(nil, { directory = directory }) end
					client.get_all_sessions = function(_, callback) callback(nil, { target }) end
					client.list_projects = function(callback) callback(nil, { { id = "project", canonical = vim.fn.getcwd() } }) end
					client.list_worktrees = function(_, callback) callback(nil, { { directory = vim.fn.getcwd() .. "/feature" } }) end
					chat.focus_input()
					input.set_pending_draft("Normal draft\nSecond line", { { type = "file", url = "file:///normal.lua", filename = "normal.lua" } },
						{ options = { delivery = "steer" } }); input.close()
					edits.add_edit("upstream-note", source.id,
						{ { fileID = "f", filePath = vim.fn.tempname() .. ".lua", type = "add", before = "", after = "proposal\n" } },
						{ transport = "review_rpc", native_review = { status = "pending" }, message = "saved note" })
					chat.for_view(view).do_render()
					local function settle()
						vim.wait(70, function() return false end, 5)
						assert(#errors == 0, table.concat(errors, "\n"))
					end
					local function press(keys)
						vim.cmd("stopinsert"); vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false); settle()
					end
					local release
					local function hold(callback, value)
						release = function() callback(nil, value) end
						if not delayed then release() end
					end
					local context = { view = view, generation = view.generation, session_id = source.id }
					local generation, count, layouts = view.generation, #views.all(), #require("opencode.ui.chat.workspace").list()
					require("opencode.ui.palette").setup()
					local registry = require("opencode.command_registry")
					if not delayed then chat.focus_input() end
					if route == "palette-connect" then
						lifecycle.ensure_connected = function(callback) release = callback; if not delayed then release() end end
						api.command_palette()
					elseif route == "reopen-connect" then
						sessions.remember({ id = target.id, title = "Old target", location = source.location })
						assert(sessions.close(target.id, { silent = true }))
						lifecycle.ensure_connected = function(callback) release = callback; if not delayed then release() end end
						assert(registry.run("session.reopen", context))
					elseif route == "new-location" then
						client.get_location = function(directory, callback) hold(callback, { directory = directory }) end
						client.create_session = function(opts, callback) assert(opts.location.directory == source.location.directory); callback(nil, target) end
						assert(registry.run("session.new", vim.tbl_extend("force", context, { args = vim.fn.getcwd() })))
					elseif route == "session-picker" then
						client.get_all_sessions = function(_, callback) hold(callback, { target }) end
						assert(registry.run("session.list", context))
					elseif route == "timeline-fork" then
						client.fork_session = function(id, opts, callback)
							assert(id == source.id and opts.before == "upstream-turn"); hold(callback, target)
						end
						assert(require("opencode.ui.timeline").run("fork", source.id, "upstream-turn"))
					elseif route == "timeline-revert-native" then
						client.abort_session = function(_, callback) callback(nil) end
						client.wait_session = function(_, callback) callback(nil) end
						client.revert_message = function(_, message, _, callback) hold(callback, { messageID = message }) end
						assert(require("opencode.ui.timeline").run("revert", source.id, "upstream-turn"))
					elseif route == "undo-revert" then
						client.abort_session = function(_, callback) callback(nil) end
						client.wait_session = function(_, callback) callback(nil) end
						client.revert_message = function(_, message, _, callback) hold(callback, { messageID = message }) end
						require("opencode.slash").register_defaults()
						assert(registry.run("session.undo", context))
					else
						client.create_worktree = function(_, opts, callback)
							assert(opts.name == "review-branch"); hold(callback, { directory = vim.fn.getcwd() .. "/created" }) end
						assert(registry.run("session.worktrees", context))
						settle(); press("<CR>"); press("n"); press("Areview-branch<CR>")
					end
					settle(); assert(release, "expected held callback for " .. route)
					if delayed then
						vim.api.nvim_set_current_win(view.winid)
						vim.api.nvim_win_set_cursor(view.winid, { view.edits["upstream-note"].start_line + 1, 0 })
						if route == "timeline-revert-native" then
							local tabpage = vim.api.nvim_get_current_tabpage()
							press("dt")
							assert(require("opencode.ui.native_diff").is_active() and vim.api.nvim_get_current_tabpage() ~= tabpage)
						end
						press("m")
						local window = input.get_winids()[1]; assert(window and input.owner_view() == view)
						vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(window), 0, -1, false, { "UNSENT upstream note", "Second line" })
						vim.api.nvim_win_set_cursor(window, { 2, 3 })
						if route == "timeline-revert-native" then
							assert(history.get_pending(source.id) == "Normal draft\nSecond line")
							assert(history.get_pending_parts(source.id)[1].url == "file:///normal.lua")
							assert(vim.deep_equal({ delivery = "steer" }, history.get_pending_options(source.id)))
						end
						release(); settle()
						assert(input.is_visible() and input.get_winids()[1] == window and vim.api.nvim_get_current_win() == window)
						assert(input.get_pending_text() == "UNSENT upstream note\nSecond line")
						assert(vim.deep_equal({ 2, 3 }, vim.api.nvim_win_get_cursor(window)))
						assert(views.session(view).id == source.id and view.generation == generation)
						assert(#views.all() == count and #require("opencode.ui.chat.workspace").list() == layouts)
						press("<C-c>"); assert(edits.get_edit("upstream-note").message == "UNSENT upstream note\nSecond line")
						assert(history.get_pending(source.id) == "Normal draft\nSecond line")
						assert(history.get_pending_parts(source.id)[1].url == "file:///normal.lua")
						assert(vim.deep_equal({ delivery = "steer" }, history.get_pending_options(source.id)))
						if route == "undo-revert" or route == "timeline-revert-native" then
							local deferred = history.peek_deferred(source.id)
							assert(deferred.text == "Historical prompt" and deferred.parts[1].url == "file:///historical.lua")
						elseif route == "timeline-fork" then
							assert(history.get_pending(target.id) == "Historical prompt" and history.get_pending_parts(target.id)[1].url == "file:///historical.lua")
						end
					elseif route == "palette-connect" then
						assert(vim.wo.winhighlight:find("OpenCodePaletteNormal", 1, true))
						assert(history.get_pending(source.id) == "Normal draft\nSecond line")
						assert(history.get_pending_parts(source.id)[1].url == "file:///normal.lua")
						assert(vim.deep_equal({ delivery = "steer" }, history.get_pending_options(source.id)))
					elseif route == "undo-revert" or route == "timeline-revert-native" or route == "timeline-fork" then
						assert(input.is_visible() and input.get_pending_text() == "Historical prompt" and input.get_pending_parts()[1].url == "file:///historical.lua")
						if route == "timeline-revert-native" then assert(history.peek_deferred(source.id) == nil) end
					elseif route ~= "reopen-connect" and route ~= "new-location" then
						assert(vim.bo.filetype == "opencode_float")
						if route == "session-picker" then press("<CR>"); assert(app.get_session().id == target.id)
						else press("<Esc>") end
					end
					if route == "reopen-connect" or route == "new-location" or route == "timeline-fork" then
						assert(app.get_session_record(target.id).title == target.title)
						assert(vim.deep_equal(target.model, app.get_session_record(target.id).model))
						if not delayed then assert(app.get_session().id == target.id) end
					end
					if route == "reopen-connect" then
						assert(vim.deep_equal(delayed and { target.id } or {}, app.get_closed_session_order()))
						assert(app.is_runtime_session(target.id) == not delayed)
					end
					assert(sync.get_message(source.id, "upstream-turn"))
				]], { route, delayed })
			end)
		end
	end
end)

describe("public navigation entries from the unchanged editor", function()
	local editor
	after_each(function() if editor then editor.close(); editor = nil end end)
	for _, method in ipairs({ "command_palette", "active_sessions", "open" }) do
		do
			it(method .. " still opens in the foreground after a delayed connection", function()
				editor = require("tests.helpers.embedded_editor").new()
				editor.lua([[
					local method = ...
					vim.o.lines, vim.o.columns = 55, 160
					local api, app, sessions = require("opencode"), require("opencode.state"), require("opencode.session")
					local client, lifecycle = require("opencode.client"), require("opencode.lifecycle")
					api.setup({ server = { auto_start = false }, lualine = { enabled = false },
						chat = { layout = "tab" }, input = { history_file = vim.fn.tempname() .. "-history.json" } })
					client.get_messages = function(_, _, callback) callback(nil, {}) end
					client.get_session_statuses = function(callback) callback(nil, {}) end
					sessions.remember({ id = "editor-source", title = "Editor source", location = { directory = vim.fn.getcwd() } })
					sessions.set_active("editor-source", "Editor source")
					local history = require("opencode.ui.input.history")
					history.set_pending("Editor draft", { { type = "file", url = "file:///editor.lua" } }, "editor-source")
					history.set_pending_options({ delivery = "steer" }, "editor-source")
					local release
					lifecycle.ensure_connected = function(callback) release = callback end
					local window = vim.api.nvim_get_current_win()
					api[method]()
					assert(release and vim.api.nvim_get_current_win() == window); release()
					vim.wait(70, function() return false end, 5)
					assert(vim.api.nvim_get_current_win() ~= window)
					if method == "command_palette" then assert(vim.wo.winhighlight:find("OpenCodePaletteNormal", 1, true))
					elseif method == "active_sessions" then assert(vim.bo.filetype == "opencode_float")
					else
						local chat = require("opencode.ui.chat")
						assert(chat.is_visible() and vim.api.nvim_get_current_win() == chat.get_view().winid)
					end
					assert(app.get_session().id == "editor-source")
					assert(history.get_pending("editor-source") == "Editor draft")
					assert(history.get_pending_parts("editor-source")[1].url == "file:///editor.lua")
					assert(vim.deep_equal({ delivery = "steer" }, history.get_pending_options("editor-source")))
				]], { method })
			end)
		end
	end
end)
