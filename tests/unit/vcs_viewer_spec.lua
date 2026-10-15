local viewer, actions = require("opencode.ui.vcs"), require("opencode.actions")
local state, pending = require("opencode.state"), require("opencode.session.pending")
local menu, float = require("opencode.ui.menu"), require("opencode.ui.float")
local registry = require("opencode.command_registry")

describe("VCS diff browser", function()
	local saved, files, calls, picker, input, origin, tabs
	local methods = { "get_vcs_base", "get_vcs_diff", "list_vcs_branches", "get_diff" }
	local function content(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
	local function key(view, lhs, win)
		vim.api.nvim_set_current_win(win or view.after_win)
		local mapping = vim.fn.maparg(lhs, "n", false, true)
		assert.is_function(mapping.callback, lhs)
		mapping.callback()
	end
	before_each(function()
		state.reset(); pending.clear_all()
		state.set_session("s", "Session")
		state.upsert_session({ id = "s", directory = "/project" }, { touch = false })
		state.set_config({ chat = { diff_view = "unified" } })
		saved, calls, picker, input = { menu = menu.open, input = float.create_input_popup, command = registry.get("diff.open"), columns = vim.o.columns, notify = vim.notify }, {}, nil, nil
		for _, method in ipairs(methods) do saved[method] = actions[method] end
		files = {
			{ file = "src/a.lua", status = "modified", additions = 2, deletions = 2, patch = "@@ -1 +1 @@\n-old\n+new\n@@ -10 +10 @@\n-last\n+next\n" },
			{ file = "README.md", status = "added", additions = 1, deletions = 0, patch = "@@ -0,0 +1 @@\n+hello\n" },
		}
		actions.get_vcs_base = function(opts, callback) calls[#calls + 1] = { method = "base", opts = opts }; callback(nil, { ref = "main", name = "main", source = "default" }) end
		actions.get_vcs_diff = function(opts, callback) calls[#calls + 1] = { method = "diff", opts = opts }; callback(nil, vim.deepcopy(files)) end
		actions.list_vcs_branches = function(opts, callback) calls[#calls + 1] = { method = "branches", opts = opts }; callback(nil, { "main", "release" }) end
		actions.get_diff = function(id, opts, callback) calls[#calls + 1] = { method = "turn", id = id, opts = opts }; callback(nil, vim.deepcopy(files)) end
		menu.open = function(opts) picker = opts end
		float.create_input_popup = function(opts) input = opts end
		origin, tabs = vim.api.nvim_get_current_win(), #vim.api.nvim_list_tabpages()
	end)
	after_each(function()
		viewer.close()
		for _, method in ipairs(methods) do actions[method] = saved[method] end
		menu.open, float.create_input_popup = saved.menu, saved.input
		vim.o.columns = saved.columns
		vim.notify = saved.notify
		registry.unregister("diff.open"); if saved.command then registry.register(saved.command) end
		state.reset(); pending.clear_all()
	end)
	it("uses aliases across diff buffers and reports disabled actions in help", function()
		state.set_config({ vcs = { keymaps = { next_file = { "r", "<F7>" }, close = false, help = "<F8>" } } })
		local notice
		vim.notify = function(message) notice = message end
		local view = viewer.open()
		for buf in pairs(view.buffers) do
			vim.api.nvim_buf_call(buf, function()
				assert.equals("", vim.fn.maparg("q", "n"))
				assert.equals("", vim.fn.maparg("n", "n"))
				assert.is_function(vim.fn.maparg("<F7>", "n", false, true).callback)
			end)
		end
		key(view, "r")
		assert.equals(2, view.index)
		key(view, "<F8>")
		assert.is_truthy(notice:find("r / <F7> next file", 1, true))
		assert.is_truthy(notice:find("(disabled) refresh", 1, true))
		assert.is_truthy(notice:find("(disabled) close", 1, true))
	end)

	it("shares /diff with the palette, requests the native base/source, and closes every owned buffer", function()
		viewer.register({ register = registry.register })
		assert.equals(registry.get("diff.open"), registry.get_slash("diff"))
		assert.is_true(registry.select("diff.open", { source = "completion" }))
		viewer.close()
		local original = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(original, 0, -1, false, { "user content" })
		local view = viewer.open()
		assert.equals(tabs + 1, #vim.api.nvim_list_tabpages())
		assert.same({ directory = "/project", mode = "branch", base = "main", context = 12 }, calls[#calls].opts)
		assert.matches("README.md", content(view.after_buf)); assert.matches("src/a.lua", content(view.after_buf))
		for buf in pairs(view.buffers) do assert.is_false(vim.bo[buf].modifiable); assert.is_true(vim.bo[buf].readonly); assert.equals("nofile", vim.bo[buf].buftype) end
		assert.is_false(pcall(vim.api.nvim_buf_set_lines, view.after_buf, 0, -1, false, { "write" }))
		key(view, "q")
		assert.equals(tabs, #vim.api.nvim_list_tabpages()); assert.equals(origin, vim.api.nvim_get_current_win())
		for buf in pairs(view.buffers) do assert.is_false(vim.api.nvim_buf_is_valid(buf)) end
		assert.equals("user content", content(original)); assert.is_true(vim.bo[original].modified)
		vim.bo[original].modified = false
	end)

	it("selects files through the real tree, supports single/all, and navigates hunks", function()
		local view = viewer.open()
		assert.matches("src/", content(view.tree_buf))
		local directory_row, file_row
		for row, entry in ipairs(view.tree_rows) do if entry.directory then directory_row = row elseif entry.index == 2 then file_row = row end end
		vim.api.nvim_win_set_cursor(view.tree_win, { directory_row, 0 }); key(view, "<CR>", view.tree_win)
		assert.is_nil(content(view.tree_buf):find("a.lua", 1, true))
		key(view, "<CR>", view.tree_win)
		vim.api.nvim_win_set_cursor(view.tree_win, { file_row, 0 }); key(view, "<CR>", view.tree_win)
		assert.equals(2, view.index)
		key(view, "A")
		assert.is_nil(content(view.after_buf):find("README.md", 1, true)); assert.matches("src/a.lua", content(view.after_buf))
		vim.api.nvim_win_set_cursor(view.after_win, { 1, 0 }); key(view, "]c")
		local first = vim.api.nvim_win_get_cursor(view.after_win)[1]
		assert.equals(view.hunks[1], first)
		key(view, "]c"); assert.equals(view.hunks[2], vim.api.nvim_win_get_cursor(view.after_win)[1])
		key(view, "[c"); assert.equals(first, vim.api.nvim_win_get_cursor(view.after_win)[1])
		key(view, "m"); assert.equals(view.files[2].patch, view.reviewed["src/a.lua"])
		key(view, "m"); assert.is_nil(view.reviewed["src/a.lua"])
		key(view, "t", view.tree_win); assert.matches("src/a.lua", content(view.tree_buf))
		key(view, "A"); assert.matches("README.md", content(view.after_buf))
	end)

	it("projects read-only paired hunks, toggles unified, and cleans up a directly closed window", function()
		state.set_config({ chat = { diff_view = "split" } })
		local view = viewer.open()
		assert.is_true(vim.api.nvim_win_is_valid(view.before_win))
		assert.equals(vim.api.nvim_buf_line_count(view.before_buf), vim.api.nvim_buf_line_count(view.after_buf))
		assert.matches("old", content(view.before_buf)); assert.is_nil(content(view.before_buf):find("new", 1, true))
		assert.matches("new", content(view.after_buf)); assert.is_nil(content(view.after_buf):find("old", 1, true))
		assert.is_true(vim.wo[view.after_win].scrollbind)
		local old_buf = view.before_buf
		key(view, "v")
		assert.is_nil(view.before_win); assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
		assert.matches("%-old", content(view.after_buf)); assert.equals("diff", vim.bo[view.after_buf].filetype)
		key(view, "v")
		assert.is_true(vim.api.nvim_win_is_valid(view.before_win))
		vim.api.nvim_win_close(view.tree_win, true)
		assert.is_true(vim.wait(500, function() return view.closed == true end, 1))
		assert.equals(tabs, #vim.api.nvim_list_tabpages())
		for buf in pairs(view.buffers) do assert.is_false(vim.api.nvim_buf_is_valid(buf)) end
	end)

	it("uses auto preference on resize without changing focus and lets the local toggle override it", function()
		state.set_config({ chat = { diff_view = "auto" } })
		vim.o.columns = 90
		local view = viewer.open()
		assert.equals("unified", view.layout)
		vim.api.nvim_set_current_win(origin)
		vim.o.columns = 180; vim.api.nvim_exec_autocmds("VimResized", {})
		assert.equals("split", view.layout); assert.equals(origin, vim.api.nvim_get_current_win())
		assert.is_true(vim.api.nvim_win_is_valid(view.before_win))
		key(view, "v")
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert.equals("unified", view.layout)
		assert.equals("auto", state.get_config().chat.diff_view)
	end)

	it("closes after direct tab removal and ignores cached key callbacks after a replacement viewer opens", function()
		local view = viewer.open()
		local mapping = vim.fn.maparg("n", "n", false, true).callback
		assert.is_function(mapping)
		vim.cmd("tabclose")
		assert.is_true(view.closed)
		assert.equals(tabs, #vim.api.nvim_list_tabpages())
		local next_view = viewer.open()
		mapping()
		assert.equals(1, next_view.index); assert.is_false(next_view.closed or false)
	end)

	it("offers all native sources and base refs including manual refs beyond the branch list", function()
		local view = viewer.open()
		key(view, "s")
		assert.same({ "branch", "committed", "working", "turn" }, vim.tbl_map(function(item) return item.value end, picker.items))
		picker.on_select(picker.items[3])
		assert.equals("working", calls[#calls].opts.mode); assert.is_nil(calls[#calls].opts.base)
		key(view, "s"); picker.on_select(picker.items[4])
		assert.same({ method = "turn", id = "s", opts = { context = 12 } }, calls[#calls])
		key(view, "s"); picker.on_select(picker.items[2])
		assert.equals("committed", calls[#calls].opts.mode); assert.equals("main", calls[#calls].opts.base)
		key(view, "b"); picker.on_select(picker.items[4])
		assert.equals("release", calls[#calls].opts.base)
		key(view, "b"); picker.on_select(picker.items[2]); input.on_submit(" refs/remotes/origin/other ")
		assert.equals("refs/remotes/origin/other", calls[#calls].opts.base)
		key(view, "b"); picker.on_select(picker.items[1])
		assert.is_nil(view.base); assert.equals("main", calls[#calls].opts.base)
	end)

	it("retains reviewed markers only for identical patches on refresh", function()
		local view = viewer.open()
		key(view, "m"); assert.equals(files[2].patch, view.reviewed["README.md"])
		key(view, "r"); assert.matches("✓ README.md", content(view.after_buf))
		files[2].patch = "@@ -0,0 +1 @@\n+different\n"
		key(view, "r"); assert.matches("○ README.md", content(view.after_buf))
	end)

	it("ignores superseded, closed, disconnected, and changed-session responses", function()
		local callbacks = {}
		actions.get_vcs_diff = function(_, callback) callbacks[#callbacks + 1] = callback end
		local view = viewer.open({ mode = "working" })
		key(view, "r")
		callbacks[2](nil, { files[2] }); callbacks[1](nil, files)
		assert.equals(1, #view.files)
		key(view, "r"); pending.invalidate(); callbacks[3](nil, files)
		assert.equals(1, #view.files)
		viewer.close()
		local next_view = viewer.open({ mode = "working" })
		state.set_session("other", "Other"); callbacks[4](nil, files)
		assert.equals(0, #next_view.files)
		viewer.close(); callbacks[4](nil, files)
		assert.is_true(next_view.closed)
	end)

	it("reports unsupported VCS endpoints and preserves authentication and last-turn errors", function()
		actions.get_vcs_diff = function(_, callback) callback({ status = 404, message = "Not found" }) end
		local view = viewer.open({ mode = "working" })
		assert.matches("does not provide", content(view.after_buf))
		actions.get_vcs_diff = function(_, callback) callback({ status = 401, message = "Authentication required" }) end
		key(view, "r"); assert.matches("Authentication required", content(view.after_buf))
		actions.get_diff = function(_, _, callback) callback({ status = 404, message = "Session not found" }) end
		key(view, "s"); picker.on_select(picker.items[4])
		assert.matches("Session not found", content(view.after_buf))
	end)

	it("allows explicit base after ambiguous inference and custom base when the branch endpoint is absent", function()
		actions.get_vcs_base = function(_, callback) callback({ status = 503, message = "Ambiguous base" }) end
		actions.list_vcs_branches = function(_, callback) callback({ status = 404, message = "Unsupported" }) end
		local view = viewer.open({ mode = "committed" })
		assert.matches("Choose a branch", content(view.after_buf))
		key(view, "b"); assert.equals(2, #picker.items)
		picker.on_select(picker.items[2]); input.on_submit("main")
		assert.equals("committed", calls[#calls].opts.mode); assert.equals("main", calls[#calls].opts.base)
		assert.matches("README.md", content(view.after_buf))
	end)
end)
