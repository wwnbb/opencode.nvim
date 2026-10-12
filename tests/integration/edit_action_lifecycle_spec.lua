local chat_edits = require("opencode.ui.chat.edits")
local chat_state = require("opencode.ui.chat.state").state
local edit_state = require("opencode.edit.state")
local changes = require("opencode.artifact.changes")
local native_diff = require("opencode.ui.native_diff")

describe("edit widget action lifecycle", function()
	local bufnr, winid, old_buffer, old_view, paths, calls, originals, captured_native_show
	local original_accept, original_reject
	local function reset_calls()
		calls = { finalize = 0, rerender = 0 }
	end
	before_each(function()
		paths = {}
		reset_calls()
		edit_state.clear_all(); changes.clear(); changes.setup({ auto_backup = false })
		old_buffer, winid = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
		old_view = vim.tbl_extend("force", {}, chat_state)
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(winid, bufnr)
		originals = { finalize = chat_edits.finalize_edit, rerender = chat_edits.rerender_edit,
			notify = vim.notify, show = native_diff.show, input_show = require("opencode.ui.input").show, focus = require("opencode.ui.chat").focus }
		original_accept, original_reject = changes.accept, changes.reject
		chat_edits.finalize_edit = function(id)
			calls.finalize, calls.last_finalized = calls.finalize + 1, id
		end
		chat_edits.rerender_edit = function(id)
			calls.rerender, calls.last_rerendered = calls.rerender + 1, id
		end
		require("opencode.ui.chat").focus = function() end
		captured_native_show = nil
		native_diff.show = function(files, opts) captured_native_show = { files = files, opts = opts } end
	end)
	after_each(function()
		chat_edits.finalize_edit, chat_edits.rerender_edit = originals.finalize, originals.rerender
		changes.accept, changes.reject = original_accept, original_reject
		vim.notify, native_diff.show = originals.notify, originals.show
		require("opencode.ui.input").show, require("opencode.ui.chat").focus = originals.input_show, originals.focus
		vim.api.nvim_win_set_buf(winid, old_buffer)
		if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		for key in pairs(chat_state) do chat_state[key] = nil end
		for key, value in pairs(old_view) do chat_state[key] = value end
		for _, path in ipairs(paths) do vim.fn.delete(path) end
		edit_state.clear_all(); changes.clear(); changes.setup()
	end)
	local function make_edit(edit_id, file_count, opts)
		edit_state.clear_all()
		opts = opts or {}
		changes.clear()
		local files = {}
		for index = 1, file_count do
			local path = vim.fn.tempname()
			local before = "before " .. tostring(index) .. "\n"
			local after = "after " .. tostring(index) .. "\n"
			-- writefile appends a newline per list item, so drop the trailing
			-- empty split element to keep disk bytes equal to the snapshot.
			local disk_lines = vim.split(opts.disk == "after" and after or before, "\n", { plain = true })
			if disk_lines[#disk_lines] == "" then
				table.remove(disk_lines)
			end
			vim.fn.writefile(disk_lines, path)
			table.insert(paths, path)
			table.insert(files, {
				filePath = path,
				before = before,
				after = after,
			})
		end
		edit_state.add_edit(edit_id, "session_edit_lifecycle", files, opts)
		local ranges = {}
		for index = 1, file_count do
			table.insert(ranges, {
				index = index,
				start_line = index - 1,
				end_line = index - 1,
			})
		end
		chat_state.winid = winid
		chat_state.bufnr = bufnr
		chat_state.edits = {
			[edit_id] = {
				start_line = 0,
				end_line = math.max(0, file_count - 1),
				status = "pending",
				meta = { file_ranges = ranges },
			},
		}
		local was_modifiable = vim.bo[bufnr].modifiable
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three", "four" })
		vim.bo[bufnr].modifiable = was_modifiable
		vim.api.nvim_win_set_cursor(winid, { 1, 0 })
	end

	local function select_file(edit_id, index)
		edit_state.move_selection_to(edit_id, index)
		vim.api.nvim_win_set_cursor(winid, { index, 0 })
	end

	it("keeps selection bounds and permits inspecting sent previews", function()
		local id = "edit_selection"
		make_edit(id, 2, { review_mode = "readonly" })
		assert.is_false(edit_state.move_selection_to(id, 0))
		assert.is_false(edit_state.move_selection_to(id, 3))
		assert.is_true(edit_state.move_selection_to(id, 2))
		assert.equals(2, edit_state.get_edit(id).selected_file)
		edit_state.mark_sent(id)
		assert.is_false(edit_state.move_selection_to(id, 1))
		assert.equals(2, edit_state.get_edit(id).selected_file)
		assert.is_true(edit_state.set_selection(id, 1))
		assert.equals(1, edit_state.get_edit(id).selected_file)
	end)

	for _, method in ipairs({ "on_send", "on_cancel" }) do
		for _, reset in ipairs({ "owner", "epoch" }) do
			it("ignores an old edit note " .. method .. " after its " .. reset .. " changes", function()
				make_edit("note-edit", 1)
				local shown
				require("opencode.ui.input").show = function(opts) shown = opts end
				chat_edits.handle_edit_message()
				assert.is_function(shown[method])
				if reset == "owner" then make_edit("note-edit", 1)
				else require("opencode.session.pending").clear_session("session_edit_lifecycle") end
				assert.is_true(edit_state.set_message("note-edit", "New note"))
				shown[method]("Old note")
				assert.equals("New note", edit_state.get_edit("note-edit").message)
				assert.equals(0, calls.rerender)
			end)
		end
	end

	it("saves a note from the current edit input", function()
		make_edit("note-edit", 1)
		local shown
		require("opencode.ui.input").show = function(opts) shown = opts end
		chat_edits.handle_edit_message()
		shown.on_send("Current note")
		assert.equals("Current note", edit_state.get_edit("note-edit").message)
		assert.equals(1, calls.rerender)
	end)

	for _, action in ipairs({ "accept", "reject", "resolve" }) do
		local opts = action == "reject" and { disk = "after" } or nil
		it(action .. " finalizes only when the last selected file is resolved", function()
			local id = "edit_single_" .. action
			make_edit(id, 2, opts)
			select_file(id, 1)
			chat_edits["handle_edit_" .. action .. "_file"]()
			assert.equals(1, calls.rerender)
			assert.equals(0, calls.finalize)
			reset_calls()
			select_file(id, 2)
			chat_edits["handle_edit_" .. action .. "_file"]()
			assert.equals(1, calls.finalize)
			assert.equals(id, calls.last_finalized)
			assert.equals(0, calls.rerender)
		end)
		it(action .. " all finalizes without an intermediate rerender", function()
			local id = "edit_all_" .. action
			make_edit(id, 2, opts)
			select_file(id, 1)
			chat_edits["handle_edit_" .. action .. "_all"]()
			assert.equals(1, calls.finalize)
			assert.equals(id, calls.last_finalized)
			assert.equals(0, calls.rerender)
		end)
	end

	for _, action in ipairs({ "accept", "reject" }) do
		it(action .. " finalizes a readonly review immediately", function()
			local id = "edit_readonly_" .. action
			make_edit(id, 2, { review_mode = "readonly" })
			select_file(id, 1)
			chat_edits["handle_edit_" .. action .. "_file"]()
			assert.equals(1, calls.finalize)
			assert.equals(0, calls.rerender)
		end)
	end

	it("does not count an empty review as pending", function()
		edit_state.clear_all()
		edit_state.add_edit("edit_empty", "session_empty", {}, {})
		assert(edit_state.has_pending_edits() == false, "empty edit should not count as pending")
		edit_state.add_edit("edit_file", "session_file", {
			{ filePath = "a.txt", before = "a", after = "b" },
		}, {})
		assert(edit_state.has_pending_edits() == true, "edit with pending file should count as pending")
		edit_state.clear_all()
	end)

	for _, case in ipairs({
		{ action = "accept", status = "accepted", title = "aggregates accept failures while applying the remaining files" },
		{ action = "reject", status = "rejected", disk = "after", title = "aggregates reject failures while continuing with the remaining files" },
	}) do
		it(case.title, function()
			local id, detail = "edit_" .. case.action .. "_partial_failure", case.action .. " write failed"
			make_edit(id, 3, { disk = case.disk })
			local edit = edit_state.get_edit(id)
			local original = changes[case.action]
			changes[case.action] = function(change_id, ...)
				if change_id == edit.files[2].change_id then return false, detail end
				return original(change_id, ...)
			end
			local ok, err, errors = edit_state[case.action .. "_all"](id)
			assert.is_false(ok, case.action .. "_all should fail when a file cannot be applied")
			assert.is_truthy(err:find(detail, 1, true), "aggregated error should include failed file detail")
			assert.equals(1, #errors)
			assert.equals(case.status, edit.files[1].status)
			assert.equals("pending", edit.files[2].status)
			assert.equals(case.status, edit.files[3].status, "batch should continue after a failed file")
			changes[case.action] = original
		end)
	end

	it("leaves a failed single-file rejection pending", function()
		make_edit("edit_reject_file_failure", 1, { disk = "after" })
		local reject_file_edit = edit_state.get_edit("edit_reject_file_failure")
		changes.reject = function()
			return false, "single reject failed"
		end
		local reject_file_ok = edit_state.reject_file("edit_reject_file_failure", 1)
		assert(not reject_file_ok, "reject_file should fail when the change cannot be reverted")
		assert(reject_file_edit.files[1].status == "pending", "reject_file should leave failed files pending")
		changes.reject = original_reject
	end)

	it("rerenders a failed chat batch without finalizing its pending file", function()
		vim.notify = function() end
		make_edit("edit_chat_batch_failure", 2)
		local chat_failure_edit = edit_state.get_edit("edit_chat_batch_failure")
		local chat_failed_change = chat_failure_edit.files[2].change_id
		changes.accept = function(change_id, opts)
			if change_id == chat_failed_change then
				return false, "chat batch failed"
			end
			return original_accept(change_id, opts)
		end
		reset_calls()
		select_file("edit_chat_batch_failure", 1)
		chat_edits.handle_edit_accept_all()
		assert(calls.finalize == 0, "failed chat batch action should not finalize")
		assert(calls.rerender == 1, "failed chat batch action should rerender")
		assert(chat_failure_edit.files[1].status == "accepted", "failed chat batch should keep successful statuses")
		assert(chat_failure_edit.files[2].status == "pending", "failed chat batch should leave failed file pending")
		changes.accept = original_accept
	end)

	it("reports and rerenders a failed manual batch without confirming the review", function()
		local notices = {}
		vim.notify = function(message) notices[#notices + 1] = message end
		make_edit("manual_failure", 1)
		local file = edit_state.get_edit("manual_failure").files[1]
		vim.fn.delete(file.filepath)
		vim.fn.mkdir(file.filepath, "p")
		select_file("manual_failure", 1)
		chat_edits.handle_edit_resolve_all()
		vim.fn.delete(file.filepath, "d")
		assert.equals(0, calls.finalize)
		assert.equals(1, calls.rerender)
		assert.equals("pending", file.status)
		assert.is_truthy(notices[1]:find("directory", 1, true))
	end)

	it("opens native diff at the selected file with original indices", function()
		make_edit("edit_native_multifile", 3)
		select_file("edit_native_multifile", 2)
		chat_edits.handle_edit_diff_tab()
		assert(captured_native_show, "native diff tab should open through native_diff.show")
		assert(#captured_native_show.files == 3, "native diff tab should include every pending edit file")
		assert(captured_native_show.opts.edit_id == "edit_native_multifile", "native diff should keep edit id")
		assert(captured_native_show.opts.file_index == 2, "native diff should keep selected edit file fallback")
		assert(captured_native_show.opts.start_index == 2, "native diff should start on selected file")
		assert(captured_native_show.files[2].edit_file_index == 2, "native diff files should keep original edit indices")
	end)

	it("maps selected file indices through the pending-only native diff list", function()
		make_edit("edit_native_pending_filter", 3)
		local native_pending_edit = edit_state.get_edit("edit_native_pending_filter")
		native_pending_edit.files[1].status = "accepted"
		select_file("edit_native_pending_filter", 2)
		chat_edits.handle_edit_diff_tab()
		assert(captured_native_show, "native diff tab should open when selected file is pending")
		assert(#captured_native_show.files == 2, "native diff tab should include only pending files")
		assert(captured_native_show.opts.start_index == 1, "native diff start index should be relative to pending files")
		assert(captured_native_show.files[1].edit_file_index == 2, "pending filtered native diff should keep original indices")
	end)

end)
