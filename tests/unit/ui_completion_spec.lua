local completion = require("opencode.ui.completion")
local actions = require("opencode.actions")
local spinner = require("opencode.ui.spinner")
local namespace = vim.api.nvim_get_namespaces().OpenCodeCompletion

describe("editor ghost completion UI", function()
	local previous_buffer, bufnr, old_complete, old_prompt, old_accept, old_dismiss
	local options = { enabled = true, keymaps = { trigger = "<C-l>", accept = "<Tab>" } }

	local function snapshot(line, col)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line, "next line" })
		return {
			id = 1,
			bufnr = bufnr,
			winid = vim.api.nvim_get_current_win(),
			row = 0,
			col = col or #line,
			changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
		}
	end

	local function marks()
		return vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
	end

	local function mapping(key, mode)
		return vim.fn.maparg(key, mode or "i", false, true)
	end

	local function selection_snapshot()
		local request = snapshot("local value = 1", 0)
		request.selection = { mode = "V", start_line = 1, end_line = 2,
			lines = { "local value = 1", "next line" }, text = "local value = 1\nnext line",
			source_lines = { "local value = 1", "next line" }, prefix = "", suffix = "" }
		return request
	end

	local function input(keys)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
	end

	before_each(function()
		completion.teardown()
		previous_buffer = vim.api.nvim_get_current_buf()
		bufnr = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(bufnr)
		old_complete, old_prompt, old_accept = actions.complete, actions.complete_with_prompt, actions.accept_completion
		old_dismiss = actions.dismiss_completion
		actions.complete = function() return true end
		actions.complete_with_prompt = function() return true end
		actions.accept_completion = function() completion.clear(); return true end
		actions.dismiss_completion = function() completion.clear(); return true end
		completion.setup(options)
	end)

	after_each(function()
		completion.teardown()
		actions.complete, actions.complete_with_prompt, actions.accept_completion = old_complete, old_prompt, old_accept
		actions.dismiss_completion = old_dismiss
		if vim.api.nvim_buf_is_valid(previous_buffer) then vim.api.nvim_set_current_buf(previous_buffer) end
		if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
	end)

	it("renders a Unicode insertion before a suffix without changing source text", function()
		local request = snapshot("local café = ()", #"local café = (")
		vim.bo[bufnr].modified = false
		assert.is_true(completion.show(request, "résultat"))
		local mark = marks()[1]
		assert.equals(request.col, mark[3])
		assert.same({ { "résultat", "OpenCodeCompletion" } }, mark[4].virt_text)
		assert.equals("inline", mark[4].virt_text_pos)
		assert.same({ "local café = ()", "next line" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		assert.is_false(vim.bo[bufnr].modified)
		assert.equals(request.changedtick, vim.api.nvim_buf_get_changedtick(bufnr))
	end)

	it("renders a short multiline block at EOL, preserving indentation and blank lines", function()
		assert.is_true(completion.show(snapshot("class Example"), ":\n\tdef run(self):\n\n\t\treturn 1"))
		local mark = marks()[1][4]
		assert.same({ { ":", "OpenCodeCompletion" } }, mark.virt_text)
		assert.same({
			{ { "\tdef run(self):", "OpenCodeCompletion" } },
			{ { "", "OpenCodeCompletion" } },
			{ { "\t\treturn 1", "OpenCodeCompletion" } },
		}, mark.virt_lines)
		assert.same({ "class Example", "next line" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end)

	it("rejects multiline previews before existing suffix text", function()
		assert.is_false(completion.show(snapshot("call()", 5), "first\nsecond"))
		assert.same({}, marks())
		assert.is_false(completion.show(snapshot("call()"), ""))
	end)

	it("shows a selection diff below the source without modifying it", function()
		local request = selection_snapshot()
		vim.bo[bufnr].modified = false
		assert.is_true(completion.pending(request))
		local mark_id = marks()[1][1]
		assert.is_true(completion.show(request, "local value = 2\nnext line\n"))
		local mark = marks()[1]
		assert.equals(mark_id, mark[1])
		assert.equals(1, mark[2])
		assert.is_nil(mark[4].virt_text)
		assert.same({
			{ { "@@ -1,2 +1,2 @@", "OpenCodeCompletionDiffChange" } },
			{ { "-local value = 1", "OpenCodeCompletionDiffDelete" } },
			{ { "+local value = 2", "OpenCodeCompletionDiffAdd" } },
			{ { " next line", "OpenCodeCompletion" } },
			{ { "OpenCode edit  <Tab> accept  <Esc> / <C-c> cancel", "OpenCodeCompletionSpinner" } },
		}, mark[4].virt_lines)
		assert.same(request.selection.lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		assert.is_false(vim.bo[bufnr].modified)
		assert.equals(request.changedtick, vim.api.nvim_buf_get_changedtick(bufnr))
	end)

	it("previews the physical line replacement around a character selection", function()
		local request = snapshot("call(old_value)", #"call(")
		request.selection = { mode = "v", start_line = 1, end_line = 1,
			lines = { "old_value" }, text = "old_value", source_lines = { "call(old_value)" }, prefix = "call(", suffix = ")" }
		assert.is_true(completion.show(request, "new_value"))
		assert.same({
			{ { "@@ -1 +1 @@", "OpenCodeCompletionDiffChange" } },
			{ { "-call(old_value)", "OpenCodeCompletionDiffDelete" } },
			{ { "+call(new_value)", "OpenCodeCompletionDiffAdd" } },
			{ { "OpenCode edit  <Tab> accept  <Esc> / <C-c> cancel", "OpenCodeCompletionSpinner" } },
		}, marks()[1][4].virt_lines)
		assert.same({ "call(old_value)", "next line" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end)

	it("previews deleting the entire selection", function()
		local request = selection_snapshot()
		assert.is_true(completion.show(request, ""))
		assert.same({
			{ { "@@ -1,2 +0,0 @@", "OpenCodeCompletionDiffChange" } },
			{ { "-local value = 1", "OpenCodeCompletionDiffDelete" } },
			{ { "-next line", "OpenCodeCompletionDiffDelete" } },
			{ { "OpenCode edit  <Tab> accept  <Esc> / <C-c> cancel", "OpenCodeCompletionSpinner" } },
		}, marks()[1][4].virt_lines)
		assert.same(request.selection.lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end)

	it("uses and restores Normal accept and cancel keys without replacing Insert mappings", function()
		local originals, inserted = {}, function() return "inserted" end
		vim.keymap.set("i", "<Tab>", inserted, { buffer = bufnr, expr = true })
		for _, key in ipairs({ "<Tab>", "<Esc>", "<C-c>" }) do
			vim.keymap.set("n", key, function() end, { buffer = bufnr })
			originals[key] = mapping(key, "n")
		end
		local request = selection_snapshot()
		assert.is_true(completion.pending(request))
		assert.equals(inserted, mapping("<Tab>").callback)
		for _, key in ipairs({ "<Tab>", "<Esc>", "<C-c>" }) do
			assert.is_not.equals(originals[key].callback, mapping(key, "n").callback)
		end
		local accepted, dismissed = 0, 0
		actions.accept_completion = function() accepted = accepted + 1; completion.clear(request); return true end
		actions.dismiss_completion = function() dismissed = dismissed + 1; completion.clear(request); return true end
		input("<Tab>")
		assert.equals(1, accepted)
		for key, original in pairs(originals) do assert.same(original, mapping(key, "n")) end
		for _, key in ipairs({ "<Esc>", "<C-c>" }) do
			assert.is_true(completion.show(request, "new code"))
			input(key)
			for lhs, original in pairs(originals) do assert.same(original, mapping(lhs, "n")) end
		end
		assert.equals(2, dismissed)
		assert.equals(inserted, mapping("<Tab>").callback)
		assert.same({}, marks())
	end)

	it("keeps other previews and new Normal mapping owners when a selection is cleared", function()
		local request = selection_snapshot()
		local ghost = { bufnr = bufnr, row = 1, col = #"next line" }
		local original_tab = mapping("<Tab>")
		completion.pending(ghost)
		local accept = mapping("<Tab>").callback
		completion.show(request, "new code")
		local replacement = function() end
		vim.keymap.set("n", "<Tab>", replacement, { buffer = bufnr })
		completion.clear(request)
		assert.equals(replacement, mapping("<Tab>", "n").callback)
		assert.equals(accept, mapping("<Tab>").callback)
		assert.equals(1, #marks())
		completion.show(request, "other code")
		local normal_accept = mapping("<Tab>", "n").callback
		completion.clear(ghost)
		assert.same(original_tab, mapping("<Tab>"))
		assert.equals(normal_accept, mapping("<Tab>", "n").callback)
		assert.equals(1, #marks())
		completion.clear(request)
		assert.equals(replacement, mapping("<Tab>", "n").callback)
	end)

	it("replays a custom Normal accept key through its original mapping after a stale edit", function()
		completion.setup({ enabled = true, keymaps = { accept = "<F8>" } })
		local calls = 0
		vim.keymap.set("n", "<F8>", function() calls = calls + 1 end, { buffer = bufnr })
		local original = mapping("<F8>", "n")
		actions.accept_completion = function() return false end
		completion.show(selection_snapshot(), "new code")
		local lines = marks()[1][4].virt_lines
		assert.equals("OpenCode edit  <F8> accept  <Esc> / <C-c> cancel", lines[#lines][1][1])
		input("<F8>")
		assert.equals(1, calls)
		assert.same(original, mapping("<F8>", "n"))
		assert.same({}, marks())
	end)

	it("keeps a custom accept key when it overlaps cancellation and shows the remaining cancel key", function()
		completion.setup({ enabled = true, keymaps = { accept = "<Esc>" } })
		local accepted, dismissed = 0, 0
		actions.accept_completion = function() accepted = accepted + 1; completion.clear(); return true end
		actions.dismiss_completion = function() dismissed = dismissed + 1; completion.clear(); return true end
		local original = mapping("<Esc>", "n")
		local request = selection_snapshot()
		completion.show(request, "new code")
		local lines = marks()[1][4].virt_lines
		assert.equals("OpenCode edit  <Esc> accept  <C-c> cancel", lines[#lines][1][1])
		input("<Esc>")
		assert.equals(1, accepted)
		assert.equals(0, dismissed)
		assert.same(original, mapping("<Esc>", "n"))
		completion.show(request, "other code")
		input("<C-c>")
		assert.equals(1, dismissed)
	end)

	it("keeps the spinner and accept mapping while acceptance is queued, and restores Tab on clear", function()
		local original_frame, calls = spinner.get_frame, 0
		local fallback = function() return "fallback" end
		vim.keymap.set("i", "<Tab>", fallback, { buffer = bufnr, expr = true })
		local accepted = 0
		actions.accept_completion = function() accepted = accepted + 1; return true end
		spinner.get_frame = function() calls = calls + 1; return "|" end
		local ok, err = pcall(function()
			local request = snapshot("local value = ")
			assert.is_true(completion.pending(request))
			local accept = mapping("<Tab>").callback
			assert.is_not.equals(fallback, accept)
			accept(); accept()
			assert.equals(2, accepted)
			assert.equals(accept, mapping("<Tab>").callback)
			assert.equals("OpenCodeCompletionSpinner", marks()[1][4].virt_text[1][2])
			assert.equals("|", marks()[1][4].virt_text[1][1])
			assert.is_true(vim.wait(500, function() return calls >= 2 end, 10))
			assert.equals("|", marks()[1][4].virt_text[1][1])
			assert.same({ "local value = ", "next line" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
			assert.equals(request.changedtick, vim.api.nvim_buf_get_changedtick(bufnr))
			completion.clear()
			assert.equals(fallback, mapping("<Tab>").callback)
			local stopped_calls = calls
			vim.wait(spinner.get_interval_ms() * 2, function() return false end, 10)
			assert.equals(stopped_calls, calls)
			assert.same({}, marks())
		end)
		spinner.get_frame = original_frame
		if not ok then error(err) end
	end)

	it("replaces the spinner with growing text and restores the original mapping after streaming", function()
		local fallback = function() return "fallback" end
		vim.keymap.set("i", "<Tab>", fallback, { buffer = bufnr, expr = true })
		local request = snapshot("    ")
		vim.bo[bufnr].modified = false
		assert.is_true(completion.pending(request))
		assert.is_true(completion.show(request, "if ready:"))
		local mark, accept = marks()[1][1], mapping("<Tab>").callback
		assert.is_true(completion.show(request, "if ready:\n\tpass"))
		assert.equals(mark, marks()[1][1])
		assert.equals(accept, mapping("<Tab>").callback)
		assert.same({ { { "\tpass", "OpenCodeCompletion" } } }, marks()[1][4].virt_lines)
		vim.wait(spinner.get_interval_ms() * 2, function() return false end, 10)
		assert.equals("if ready:", marks()[1][4].virt_text[1][1])
		assert.is_true(completion.show(request, "return value"))
		assert.is_nil(marks()[1][4].virt_lines)
		assert.same({ "    ", "next line" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		assert.equals(request.changedtick, vim.api.nvim_buf_get_changedtick(bufnr))
		assert.is_false(vim.bo[bufnr].modified)
		completion.clear()
		assert.equals(fallback, mapping("<Tab>").callback)
	end)

	it("keeps concurrent spinners, streaming text, and mapping ownership independent", function()
		local fallback = function() return "fallback" end
		vim.keymap.set("i", "<Tab>", fallback, { buffer = bufnr, expr = true })
		local first = snapshot("value")
		local second = vim.tbl_extend("force", first, { row = 1, col = #"next line" })
		local original_frame, calls = spinner.get_frame, 0
		spinner.get_frame = function() calls = calls + 1; return "|" end
		local ok, err = pcall(function()
			completion.pending(first)
			local accept = mapping("<Tab>").callback
			completion.pending(second)
			assert.equals(2, #marks())
			assert.equals(accept, mapping("<Tab>").callback)
			completion.show(first, "_done")
			local before = calls
			assert.is_true(vim.wait(500, function() return calls > before end, 10))
			assert.equals("_done", marks()[1][4].virt_text[1][1])
			assert.equals("OpenCodeCompletionSpinner", marks()[2][4].virt_text[1][2])
			-- Equal request IDs do not alias distinct snapshot tables.
			completion.clear(first)
			assert.equals(1, #marks())
			assert.equals(1, marks()[1][2])
			assert.equals(accept, mapping("<Tab>").callback)
			completion.clear(second)
			assert.equals(fallback, mapping("<Tab>").callback)
			local stopped = calls
			vim.wait(spinner.get_interval_ms() * 2, function() return false end, 10)
			assert.equals(stopped, calls)
		end)
		spinner.get_frame = original_frame
		if not ok then error(err) end
	end)

	it("updates or rejects only the matching preview, including snapshots without IDs", function()
		local first = snapshot("value")
		first.id = nil
		local second = { bufnr = bufnr, row = 1, col = #"next line" }
		completion.show(first, "_first")
		completion.show(second, "_second")
		local second_mark = marks()[2][1]
		completion.show(first, "_updated")
		assert.equals("_updated", marks()[1][4].virt_text[1][1])
		assert.equals(second_mark, marks()[2][1])
		completion.clear(vim.deepcopy(first))
		assert.equals(2, #marks())
		assert.is_false(completion.show(first, ""))
		assert.equals(1, #marks())
		assert.equals("_second", marks()[1][4].virt_text[1][1])
		completion.clear()
		assert.same({}, marks())
	end)

	it("replays unrelated Tab and resumes acceptance for both targets in the same input batch", function()
		local fallbacks, accepted = 0, 0
		local fallback = function() fallbacks = fallbacks + 1; return "fallback" end
		vim.keymap.set("i", "<Tab>", fallback, { buffer = bufnr, expr = true })
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "first", "second", "" })
		local targets = {
			{ bufnr = bufnr, row = 0, col = #"first" },
			{ bufnr = bufnr, row = 1, col = #"second" },
		}
		for _, target in ipairs(targets) do completion.pending(target) end
		actions.accept_completion = function()
			local cursor = vim.api.nvim_win_get_cursor(0)
			for _, target in ipairs(targets) do
				if cursor[1] == target.row + 1 and cursor[2] == target.col then
					assert.equals(2 - accepted, #marks())
					accepted = accepted + 1
					completion.clear(target)
					return true
				end
			end
			return false
		end
		input("2ji<Tab><Esc>kkA<Tab><Esc>jA<Tab><Esc>")
		assert.equals(1, fallbacks)
		assert.equals(2, accepted)
		assert.same({ "first", "second", "fallback" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		assert.same({}, marks())
		assert.equals(fallback, mapping("<Tab>").callback)
	end)

	it("keeps decorations and mappings in other buffers when one buffer is cleared", function()
		local first = snapshot("first")
		local original = mapping("<Tab>")
		completion.pending(first)
		local other = vim.api.nvim_create_buf(true, false)
		local ok, err = pcall(function()
			vim.api.nvim_set_current_buf(other)
			local second = { bufnr = other, row = 0, col = 0 }
			completion.pending(second)
			local accept = mapping("<Tab>").callback
			vim.api.nvim_set_current_buf(bufnr)
			vim.bo[bufnr].filetype = "opencode_chat"
			assert.same({}, marks())
			assert.same(original, mapping("<Tab>"))
			vim.api.nvim_set_current_buf(other)
			assert.equals(1, #vim.api.nvim_buf_get_extmarks(other, namespace, 0, -1, {}))
			assert.equals(accept, mapping("<Tab>").callback)
			completion.clear()
			assert.same({}, vim.api.nvim_buf_get_extmarks(other, namespace, 0, -1, {}))
		end)
		vim.api.nvim_set_current_buf(bufnr)
		vim.api.nvim_buf_delete(other, { force = true })
		if not ok then error(err) end
	end)

	it("restores a local expression callback after accepting", function()
		local fallback = function() return "fallback" end
		vim.keymap.set("i", "<Tab>", fallback, { buffer = bufnr, expr = true, replace_keycodes = false })
		local original = mapping("<Tab>")
		local accepted = 0
		actions.accept_completion = function() accepted = accepted + 1; completion.clear(); return true end
		assert.is_true(completion.show(snapshot("value"), "_complete"))
		input("i<Tab><Esc>")
		assert.equals(1, accepted)
		assert.same(original, mapping("<Tab>"))
		assert.same({}, marks())
	end)

	it("replays stale Tab once through the original expression mapping", function()
		local fallbacks = 0
		vim.keymap.set("i", "<Tab>", function()
			fallbacks = fallbacks + 1
			return "fallback"
		end, { buffer = bufnr, expr = true })
		actions.accept_completion = function() return false end
		completion.show(snapshot(""), "ignored")
		input("i<Tab><Esc>")
		assert.equals(1, fallbacks)
		assert.equals("fallback", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
		assert.same({}, marks())
	end)

	it("exposes a global mapping again when no previous local Tab existed", function()
		local original = mapping("<Tab>")
		local global = function() return "global" end
		vim.keymap.set("i", "<Tab>", global, { expr = true })
		local ok, err = pcall(function()
			completion.show(snapshot("value"), "_complete")
			assert.equals(1, mapping("<Tab>").buffer)
			completion.clear()
			assert.equals(0, mapping("<Tab>").buffer)
			assert.equals(global, mapping("<Tab>").callback)
		end)
		vim.keymap.del("i", "<Tab>")
		if next(original) then vim.fn.mapset("i", false, original) end
		if not ok then error(err) end
	end)

	it("does not overwrite an accept mapping installed by another owner", function()
		completion.show(snapshot("value"), "_complete")
		local replacement = function() return "replacement" end
		vim.keymap.set("i", "<Tab>", replacement, { buffer = bufnr, expr = true })
		completion.clear()
		assert.equals(replacement, mapping("<Tab>").callback)
	end)

	it("preserves another accept key's new owner across fallback and resumed acceptance", function()
		completion.setup({ enabled = true, keymaps = { trigger = false, accept = { "<Tab>", "<F6>" } } })
		local fallbacks = 0
		vim.keymap.set("i", "<Tab>", "<F6>", { buffer = bufnr, remap = true })
		local request = snapshot("value")
		completion.pending(request)
		local replacement = function() fallbacks = fallbacks + 1; return "fallback" end
		vim.keymap.set("i", "<F6>", replacement, { buffer = bufnr, expr = true })
		local original = mapping("<F6>")
		actions.accept_completion = function() return false end
		input("ji<Tab><Esc>")
		assert.equals(1, fallbacks)
		assert.equals(1, #marks())
		assert.same(original, mapping("<F6>"))
		actions.accept_completion = function() completion.clear(request); return true end
		input("kA<Tab><Esc>")
		assert.same({}, marks())
		assert.same(original, mapping("<F6>"))
	end)

	it("does not reclaim an accept key changed by the fallback callback", function()
		local replacement = function() return "replacement" end
		vim.keymap.set("i", "<Tab>", function()
			vim.keymap.set("i", "<Tab>", replacement, { buffer = bufnr, expr = true })
			return "fallback"
		end, { buffer = bufnr, expr = true })
		completion.pending(snapshot("value"))
		actions.accept_completion = function() return false end
		input("ji<Tab><Esc>")
		assert.equals(1, #marks())
		assert.equals(replacement, mapping("<Tab>").callback)
		completion.clear()
		assert.equals(replacement, mapping("<Tab>").callback)
	end)

	it("installs completion triggers only in ordinary editable buffers", function()
		local calls, prompts = 0, 0
		actions.complete = function() calls = calls + 1 end
		actions.complete_with_prompt = function() prompts = prompts + 1 end
		input("i<C-l><C-S-l><Esc>")
		assert.equals(1, calls)
		assert.equals(1, prompts)
		input("v<C-S-l><Esc>")
		assert.equals(2, prompts)
		for _, options_to_set in ipairs({
			{ buftype = "nofile" },
			{ filetype = "opencode_input" },
			{ modifiable = false },
			{ readonly = true },
		}) do
			local special = vim.api.nvim_create_buf(true, false)
			for key, value in pairs(options_to_set) do vim.bo[special][key] = value end
			vim.api.nvim_set_current_buf(special)
			assert.is_nil(mapping("<C-l>").callback)
			assert.is_nil(mapping("<C-S-l>").callback)
			assert.is_nil(mapping("<C-S-l>", "x").callback)
			vim.api.nvim_set_current_buf(bufnr)
			vim.api.nvim_buf_delete(special, { force = true })
		end
	end)

	it("restores the Visual prompt mapping and preserves later owners", function()
		completion.teardown()
		local fallback = function() end
		vim.keymap.set("x", "<C-S-l>", fallback, { buffer = bufnr })
		local original = mapping("<C-S-l>", "x")
		completion.setup(options)
		local mode
		actions.complete_with_prompt = function() mode = vim.api.nvim_get_mode().mode end
		input("v<C-S-l><Esc>")
		assert.equals("v", mode)
		completion.teardown()
		assert.same(original, mapping("<C-S-l>", "x"))
		completion.setup(options)
		local replacement = function() end
		vim.keymap.set("x", "<C-S-l>", replacement, { buffer = bufnr })
		completion.teardown()
		assert.equals(replacement, mapping("<C-S-l>", "x").callback)
	end)

	it("restores original trigger mappings on teardown and keeps newer mappings", function()
		completion.teardown()
		local originals = {}
		for _, key in ipairs({ "<C-l>", "<C-S-l>" }) do
			vim.keymap.set("i", key, "original", { buffer = bufnr })
			originals[key] = mapping(key)
		end
		completion.setup(options)
		completion.teardown()
		for key, original in pairs(originals) do assert.same(original, mapping(key)) end
		completion.setup(options)
		for key in pairs(originals) do vim.keymap.set("i", key, "replacement", { buffer = bufnr }) end
		completion.teardown()
		for key in pairs(originals) do assert.equals("replacement", mapping(key).rhs) end
	end)

	it("removes decorations and editor mappings when a buffer becomes an OpenCode view", function()
		local previous_tab = mapping("<Tab>")
		completion.show(snapshot("value"), "_complete")
		vim.bo[bufnr].filetype = "opencode_chat"
		assert.same({}, marks())
		assert.same(previous_tab, mapping("<Tab>"))
		assert.is_nil(mapping("<C-l>").callback)
		assert.is_nil(mapping("<C-S-l>").callback)
		assert.is_nil(mapping("<C-S-l>", "x").callback)
	end)

	it("supports disabling completion mappings and clears previews on teardown", function()
		completion.setup({ enabled = true, keymaps = { trigger = false, prompt = false, accept = false } })
		assert.is_nil(mapping("<C-l>").callback)
		assert.is_nil(mapping("<C-S-l>").callback)
		assert.is_nil(mapping("<C-S-l>", "x").callback)
		local previous_tab = mapping("<Tab>")
		completion.show(snapshot("value"), "_complete")
		assert.same(previous_tab, mapping("<Tab>"))
		completion.teardown()
		assert.same({}, marks())
	end)

	it("supports multiple trigger, prompt, and accept keys and restores every previous mapping", function()
		completion.teardown()
		local keys = { "<C-l>", "<M-l>", "<F6>", "<F7>", "<Tab>", "<M-a>" }
		local originals = {}
		for _, key in ipairs(keys) do
			vim.keymap.set("i", key, "original", { buffer = bufnr })
			originals[key] = mapping(key)
		end
		completion.setup({ enabled = true, keymaps = {
			trigger = { "<C-l>", "<M-l>" }, prompt = { "<F6>", "<F7>" }, accept = { "<Tab>", "<M-a>" },
		} })
		assert.is_nil(mapping("<C-S-l>").callback)
		local requested, prompted, accepted = 0, 0, 0
		actions.complete = function() requested = requested + 1 end
		actions.complete_with_prompt = function() prompted = prompted + 1 end
		actions.accept_completion = function() accepted = accepted + 1; completion.clear(); return true end
		mapping("<C-l>").callback()
		mapping("<M-l>").callback()
		assert.equals(2, requested)
		mapping("<F6>").callback()
		mapping("<F7>").callback()
		assert.equals(2, prompted)
		completion.show(snapshot("value"), "_complete")
		assert.is_function(mapping("<Tab>").callback)
		mapping("<M-a>").callback()
		assert.equals(1, accepted)
		assert.same(originals["<Tab>"], mapping("<Tab>"))
		assert.same(originals["<M-a>"], mapping("<M-a>"))
		completion.teardown()
		for _, key in ipairs(keys) do assert.same(originals[key], mapping(key)) end
	end)

	it("deduplicates equivalent accept aliases before restoring the original mapping", function()
		local fallback = function() return "original" end
		vim.keymap.set("i", "<Tab>", fallback, { buffer = bufnr, expr = true })
		local original = mapping("<Tab>")
		completion.setup({ enabled = true, keymaps = { trigger = false, accept = { "<Tab>", "<C-i>" } } })
		completion.show(snapshot("value"), "_complete")
		mapping("<Tab>").callback()
		assert.same(original, mapping("<Tab>"))
	end)
end)
