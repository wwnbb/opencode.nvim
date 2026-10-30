local native = require("opencode.ui.native_diff")
local edits = require("opencode.edit.state")
local state = require("opencode.state")
local menu = require("opencode.ui.menu")
local input = require("opencode.ui.input")
describe("native review file actions", function()
	local path, notify, menu_open, chat_edits, input_show, shown, leader
	local function read() return table.concat(vim.fn.readfile(path, "b"), "\n") end
	local function open(kind, view, on_close)
		vim.fn.writefile({ "before" }, path)
		edits.add_edit("r", "s", { { fileID = "f", filePath = path, before = "before\n", after = "after\n", type = kind or "update" } },
			{ transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
		native.show({ { filePath = path, before = "before\n", after = "after\n", type = kind or "update", edit_file_index = 1 } }, { edit_id = "r", view = view, on_close = on_close })
	end
	before_each(function()
		path = vim.fn.tempname(); notify, menu_open = vim.notify, menu.open
		leader = vim.g.mapleader
		input_show, shown = input.show, nil
		input.show = function(opts) shown = opts end
		vim.notify = function() end
		chat_edits = package.loaded["opencode.ui.chat.edits"]
		package.loaded["opencode.ui.chat.edits"] = { refresh_edit = function() end }
		state.set_config({ server = { shared_filesystem = true } }); state.set_connection("connected")
	end)
	after_each(function()
		for _, file in ipairs({ path, path .. ".target" }) do
			local buf = vim.fn.bufnr(file)
			if buf >= 0 then vim.bo[buf].modified = false end
		end
		native.close(); edits.clear_all(); require("opencode.artifact.changes").clear()
		for _, file in ipairs({ path, path .. ".target" }) do
			local buf = vim.fn.bufnr(file)
			if buf >= 0 and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
		end
		vim.fn.delete(path); vim.fn.delete(path .. ".target"); vim.notify, menu.open = notify, menu_open
		input.show = input_show
		vim.g.mapleader = leader
		package.loaded["opencode.ui.chat.edits"] = chat_edits; state.set_connection("idle")
	end)
	local function mapping(buf, key)
		return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(key, "n", false, true) end)
	end
	it("remaps native help aliases and reports disabled review actions", function()
		state.set_config({ server = { shared_filesystem = true }, native_diff = {
			keymaps = { confirm = false, help = { "<F8>", "<F9>" }, close = "<F10>" },
		} })
		local notice
		vim.notify = function(message) notice = message end
		open()
		local buf = vim.fn.bufnr(path)
		assert.same({}, mapping(buf, "<C-a>")); assert.same({}, mapping(buf, "?"))
		assert.is_function(mapping(buf, "<F8>").callback)
		mapping(buf, "<F9>").callback()
		assert.is_truthy(notice:find("(disabled) - Confirm current file", 1, true))
		assert.is_truthy(notice:find("<F8> / <F9> - Show this help", 1, true))
		mapping(buf, "<F10>").callback()
		assert.is_false(native.is_active())
	end)
	it("restores Lua and string mappings and removes temporary keys on close", function()
		vim.fn.writefile({ "before" }, path)
		local buf = vim.fn.bufadd(path); vim.fn.bufload(buf)
		vim.keymap.set("n", "m", function() return "h" end, { buffer = buf, expr = true, nowait = true, desc = "User expression" })
		vim.keymap.set("n", "<C-a>", "j", { buffer = buf, remap = true, desc = "User increment" })
		local note, increment = mapping(buf, "m"), mapping(buf, "<C-a>")
		open()
		native.close()
		assert.same(note, mapping(buf, "m"))
		assert.same(increment, mapping(buf, "<C-a>"))
		assert.same({}, mapping(buf, "q"))
		assert.same({}, mapping(buf, "<C-x>"))
	end)
	it("removes navigation mappings even if mapleader changes", function()
		vim.g.mapleader = ","
		open()
		local buf = vim.fn.bufnr(path)
		assert.is_function(mapping(buf, ",on").callback)
		vim.g.mapleader = " "
		native.close()
		assert.same({}, mapping(buf, ",on"))
		assert.same({}, mapping(buf, ",op"))
	end)
	it("preserves a user mapping replaced while the diff was open", function()
		open()
		local buf = vim.fn.bufnr(path)
		local user = function() end
		vim.keymap.set("n", "m", user, { buffer = buf })
		native.close()
		assert.equals(user, mapping(buf, "m").callback)
	end)
	it("restores the previous file's mappings while navigating", function()
		open()
		vim.fn.writefile({ "before" }, path .. ".target")
		local files = {
			{ fileID = "f", filePath = path, before = "before\n", after = "after\n", type = "update", edit_file_index = 1 },
			{ fileID = "second", filePath = path .. ".target", before = "before\n", after = "after\n", type = "update", edit_file_index = 2 },
		}
		edits.add_edit("r", "s", files, { transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
		native.show(files, { edit_id = "r" })
		local first = vim.fn.bufnr(path)
		mapping(first, "<leader>on").callback()
		local second = vim.fn.bufnr(path .. ".target")
		assert.same({}, mapping(first, "<C-a>"))
		assert.is_function(mapping(second, "<C-a>").callback)
		native.close()
		assert.same({}, mapping(second, "<C-a>"))
	end)
	it("restores mappings when the diff tab is closed directly", function()
		open()
		local buf = vim.fn.bufnr(path)
		vim.cmd("tabclose")
		assert.is_false(native.is_active())
		assert.same({}, mapping(buf, "m"))
	end)
	it("ignores a cached keymap callback from a closed diff", function()
		open()
		local close = mapping(vim.fn.bufnr(path), "q").callback
		native.close()
		open()
		close()
		assert.is_true(native.is_active())
	end)
	it("restores the previous window and then runs on_close once", function()
		local before, calls = vim.api.nvim_get_current_win(), {}
		open(nil, nil, function(ctx) calls[#calls + 1] = ctx end)
		assert.are_not.equal(before, vim.api.nvim_get_current_win())
		native.close()
		assert.is_true(vim.wait(100, function() return #calls > 0 end))
		vim.wait(20, function() return false end)
		assert.equals(1, #calls)
		assert.is_true(calls[1].restored)
		assert.equals(before, vim.api.nvim_get_current_win())
	end)
	it("reports an unrestored focus to on_close when the previous window is gone", function()
		vim.cmd("split")
		local before, ctx = vim.api.nvim_get_current_win(), nil
		open(nil, nil, function(value) ctx = value end)
		vim.api.nvim_win_close(before, true)
		native.close()
		assert.is_true(vim.wait(100, function() return ctx ~= nil end))
		assert.is_false(ctx.restored)
	end)
	it("leaves focus alone and skips on_close when focus moved before the restore", function()
		local calls = 0
		open(nil, nil, function() calls = calls + 1 end)
		native.close()
		vim.cmd("split")
		local moved = vim.api.nvim_get_current_win()
		vim.wait(50, function() return false end)
		assert.equals(0, calls)
		assert.equals(moved, vim.api.nvim_get_current_win())
		vim.api.nvim_win_close(moved, true)
	end)

	local function open_note()
		open()
		local mapping = vim.fn.maparg("m", "n", false, true)
		assert.is_function(mapping.callback)
		mapping.callback()
		assert.is_function(shown.on_send)
	end
	it("saves the current native diff note", function()
		open_note()
		shown.on_send("Current note")
		assert.equals("Current note", edits.get_edit("r").message)
	end)
	it("ignores a native diff note and mutation keys after the owning pane is reassigned", function()
		local views = require("opencode.ui.chat.state")
		local view = views.new()
		view.session_id = "s"
		local ok, err = xpcall(function()
			open(nil, view)
			local buf = vim.fn.bufnr(path)
			mapping(buf, "m").callback()
			assert.equals(view, shown.view)
			view.generation = view.generation + 1
			shown.on_send("Stale note")
			mapping(buf, "<C-y>").callback()
			assert.equals("", edits.get_edit("r").message)
			assert.same({ "before" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
			native.close()
		end, debug.traceback)
		views.remove(view)
		assert.is_true(ok, err)
	end)
	for _, switch in ipairs({ false, true }) do
		it("ignores an old native diff note after " .. (switch and "opening another review" or "session invalidation"), function()
			open_note()
			if switch then
				native.close()
				edits.add_edit("other", "s", { { fileID = "f", filePath = path, before = "before\n", after = "after\n" } },
					{ transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
				native.show({ { filePath = path, before = "before\n", after = "after\n" } }, { edit_id = "other" })
				assert.is_true(edits.set_message("other", "New note"))
			else require("opencode.session.pending").clear_session("s") end
			shown.on_send("Old note")
			assert.equals("", edits.get_edit("r").message)
			if switch then assert.equals("New note", edits.get_edit("other").message) end
		end)
	end

	it("does not flush a manual diff buffer after connection loss", function()
		open()
		local buf = vim.fn.bufnr(path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "manual" })
		state.set_connection("idle")
		native._confirm_current()
		assert.equals("before\n", read()); assert.is_true(vim.bo[buf].modified)
		assert.equals("pending", edits.get_edit("r").files[1].status)
	end)
	it("does not save a manual buffer through a replacement symlink", function()
		open()
		local buf = vim.fn.bufnr(path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "manual" })
		local target = path .. ".target"
		vim.fn.writefile({ "before" }, target)
		assert(os.remove(path))
		assert(vim.uv.fs_symlink(target, path))
		native._confirm_current()
		assert.equals("before\n", table.concat(vim.fn.readfile(target, "b"), "\n"))
		assert.equals("link", vim.uv.fs_lstat(path).type)
		assert.is_true(vim.bo[buf].modified)
		assert.equals("pending", edits.get_edit("r").files[1].status)
	end)
	it("does not confirm a modified buffer when a write handler saves nothing", function()
		open()
		local buf = vim.fn.bufnr(path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "manual" })
		vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = function() end })
		native._confirm_current()
		assert.equals("before\n", read())
		assert.is_true(vim.bo[buf].modified)
		assert.equals("pending", edits.get_edit("r").files[1].status)
	end)
	it("saves a manual buffer and classifies the saved proposal", function()
		open()
		local buf = vim.fn.bufnr(path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "after" })
		native._confirm_current()
		assert.equals("after\n", read())
		assert.is_false(vim.bo[buf].modified)
		assert.equals("accepted", edits.get_edit("r").files[1].status)
	end)
	it("reject does not replace divergent disk bytes or unsaved manual buffer", function()
		open()
		local buf = vim.fn.bufnr(path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved manual" })
		native._reject_current()
		assert.equals("before\n", read()); assert.is_true(vim.bo[buf].modified)
		assert.equals("pending", edits.get_edit("r").files[1].status)
		vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
		native._reject_all()
		assert.equals("unsaved manual\n", read())
		assert.equals("rejected", edits.get_edit("r").files[1].status)
	end)
	for _, reset in ipairs({ "switch", "epoch" }) do
		it("does not apply a stale deletion confirmation after " .. reset, function()
			local choose
			menu.open = function(opts) choose = opts.on_select end
			open("delete")
			if reset == "epoch" then require("opencode.session.pending").clear_session("s")
			else
				edits.add_edit("other", "s", { { fileID = "f", filePath = path, before = "before\n", after = "after\n", type = "update" } },
					{ transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
				native.show({ { filePath = path, before = "before\n", after = "after\n", type = "update", edit_file_index = 1 } }, { edit_id = "other" })
			end
			choose("Yes, delete")
			assert.equals("before\n", read())
			assert.equals("pending", edits.get_edit(reset == "switch" and "other" or "r").files[1].status)
		end)
	end

	for _, multiple in ipairs({ false, true }) do
		it("does not run an old " .. (multiple and "next-file" or "finish") .. " callback on a new diff", function()
			local queued, schedule = {}, vim.schedule
			open()
			if multiple then
				local files = {
					{ fileID = "f", filePath = path, before = "before\n", after = "after\n", type = "update", edit_file_index = 1 },
					{ fileID = "second", filePath = path .. ".target", before = "", after = "second\n", type = "add", edit_file_index = 2 },
				}
				edits.add_edit("r", "s", files, { transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
				native.show(files, { edit_id = "r" })
			end
			vim.schedule = function(callback) queued[#queued + 1] = callback end
			local ok, err = pcall(function()
				native._confirm_current()
				edits.add_edit("other", "s", { { fileID = "f", filePath = path, before = "before\n", after = "after\n", type = "update" } },
					{ transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
				native.show({ { filePath = path, before = "before\n", after = "after\n", type = "update" } }, { edit_id = "other" })
				local tab = vim.api.nvim_get_current_tabpage()
				local count = #vim.api.nvim_list_tabpages()
				for _, callback in ipairs(queued) do callback() end
				assert.is_true(native.is_active())
				assert.equals(tab, vim.api.nvim_get_current_tabpage())
				assert.equals(count, #vim.api.nvim_list_tabpages())
				assert.equals("pending", edits.get_edit("other").files[1].status)
			end)
			vim.schedule = schedule
			assert.is_true(ok, err)
		end)
	end

	it("applies the current deletion confirmation", function()
		local choose
		menu.open = function(opts) choose = opts.on_select end
		open("delete")
		choose("Yes, delete")
		assert.is_nil(vim.uv.fs_stat(path))
		assert.equals("accepted", edits.get_edit("r").files[1].status)
	end)

	it("late delete confirmation cannot write after review cancellation", function()
		local choose
		menu.open = function(opts) choose = opts.on_select end
		open("delete")
		edits.set_review_record({ reviewID = "r", sessionID = "s", revision = 1, status = "cancelled" })
		choose("Yes, delete")
		assert.equals("before\n", read())
	end)
end)

describe("codediff review backend", function()
	local path, notify, chat_edits, calls
	local function open(kind, before)
		edits.add_edit("r", "s", { { fileID = "f", filePath = path, before = before or "before\n", after = "after\n", type = kind or "update" } },
			{ transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
		native.show({ { filePath = path, before = before or "before\n", after = "after\n", type = kind or "update", edit_file_index = 1 } }, { edit_id = "r" })
	end
	local function mapping(buf, key)
		return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(key, "n", false, true) end)
	end
	local function stub_codediff()
		-- Mirrors `:CodeDiff file a b`: a new tab with a LEFT and b RIGHT, and
		-- pane mappings installed from a scheduled render.
		vim.api.nvim_create_user_command("CodeDiff", function(cmd)
			local a, b = cmd.fargs[2], cmd.fargs[3]
			calls[#calls + 1] = { a = a, b = b, after = table.concat(vim.fn.readfile(a, "b"), "\n") }
			vim.cmd("tabnew " .. vim.fn.fnameescape(a))
			vim.cmd("rightbelow vsplit " .. vim.fn.fnameescape(b))
			local bufs = { vim.fn.bufnr(a), vim.fn.bufnr(b) }
			vim.schedule(function()
				for _, buf in ipairs(bufs) do vim.keymap.set("n", "q", "<Cmd>tabclose<CR>", { buffer = buf }) end
			end)
		end, { nargs = "*" })
	end
	local function flush() vim.wait(20, function() return false end) end
	before_each(function()
		path, calls, notify = vim.fn.tempname(), {}, vim.notify
		vim.fn.writefile({ "before" }, path)
		vim.notify = function() end
		chat_edits = package.loaded["opencode.ui.chat.edits"]
		package.loaded["opencode.ui.chat.edits"] = { refresh_edit = function() end }
		state.set_config({ server = { shared_filesystem = true }, diff = { provider = "codediff" } })
		state.set_connection("connected")
	end)
	after_each(function()
		local buf = vim.fn.bufnr(path)
		if buf >= 0 then vim.bo[buf].modified = false end
		native.close(); edits.clear_all(); require("opencode.artifact.changes").clear()
		buf = vim.fn.bufnr(path)
		if buf >= 0 and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
		pcall(vim.api.nvim_del_user_command, "CodeDiff")
		vim.fn.delete(path); vim.notify = notify
		package.loaded["opencode.ui.chat.edits"] = chat_edits; state.set_connection("idle")
	end)

	it("opens the proposed content against the actual file through CodeDiff", function()
		stub_codediff()
		open()
		assert.equals(1, #calls)
		assert.equals(path, calls[1].b)
		assert.equals("after\n", calls[1].after)
		local proposed = vim.fn.bufnr(calls[1].a)
		assert.is_false(vim.bo[proposed].modifiable)
		assert.is_false(vim.wo[vim.fn.bufwinid(path)].diff)
		flush()
		local actual = vim.fn.bufnr(path)
		assert.is_function(mapping(actual, "q").callback)
		mapping(actual, "<C-y>").callback()
		assert.same({ "after" }, vim.api.nvim_buf_get_lines(actual, 0, -1, false))
		vim.bo[actual].modified = false
		mapping(actual, "q").callback()
		assert.is_false(native.is_active())
		assert.equals(0, vim.fn.filereadable(calls[1].a))
		assert.is_false(vim.api.nvim_buf_is_valid(proposed))
	end)

	it("cleans up the temp file when the codediff tab is closed directly", function()
		stub_codediff()
		open()
		vim.cmd("tabclose")
		assert.is_false(native.is_active())
		assert.equals(0, vim.fn.filereadable(calls[1].a))
	end)

	it("falls back to the native diff when codediff is not installed", function()
		open()
		assert.is_true(native.is_active())
		assert.is_true(vim.wo[vim.fn.bufwinid(path)].diff)
	end)

	it("reviews a new file with the native diff", function()
		stub_codediff()
		vim.fn.delete(path)
		open("add", "")
		assert.equals(0, #calls)
		assert.is_true(vim.wo[vim.fn.bufwinid(path)].diff)
	end)
end)
