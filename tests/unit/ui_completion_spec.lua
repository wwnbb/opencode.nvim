local completion = require("opencode.ui.completion")
local actions = require("opencode.actions")
local spinner = require("opencode.ui.spinner")
local namespace = vim.api.nvim_get_namespaces().OpenCodeCompletion

describe("editor ghost completion UI", function()
	local previous_buffer, bufnr, old_complete, old_accept
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

	local function mapping(key)
		return vim.fn.maparg(key, "i", false, true)
	end

	local function input(keys)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
	end

	before_each(function()
		completion.teardown()
		previous_buffer = vim.api.nvim_get_current_buf()
		bufnr = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(bufnr)
		old_complete, old_accept = actions.complete, actions.accept_completion
		actions.complete = function() return true end
		actions.accept_completion = function() return true end
		completion.setup(options)
	end)

	after_each(function()
		completion.teardown()
		actions.complete, actions.accept_completion = old_complete, old_accept
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

	it("stops spinner updates after clear and does not take Tab while pending", function()
		local original_frame, calls = spinner.get_frame, 0
		local fallback = function() return "fallback" end
		vim.keymap.set("i", "<Tab>", fallback, { buffer = bufnr, expr = true })
		spinner.get_frame = function() calls = calls + 1; return "|" end
		local ok, err = pcall(function()
			assert.is_true(completion.pending(snapshot("local value = ")))
			assert.equals(fallback, mapping("<Tab>").callback)
			assert.equals("OpenCodeCompletionSpinner", marks()[1][4].virt_text[1][2])
			assert.is_true(vim.wait(500, function() return calls >= 2 end, 10))
			completion.clear()
			local stopped_calls = calls
			vim.wait(spinner.get_interval_ms() * 2, function() return false end, 10)
			assert.equals(stopped_calls, calls)
			assert.same({}, marks())
		end)
		spinner.get_frame = original_frame
		if not ok then error(err) end
	end)

	it("restores a local expression callback after accepting", function()
		local fallback = function() return "fallback" end
		vim.keymap.set("i", "<Tab>", fallback, { buffer = bufnr, expr = true, replace_keycodes = false })
		local original = mapping("<Tab>")
		local accepted = 0
		actions.accept_completion = function() accepted = accepted + 1; return true end
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

	it("installs the trigger only in ordinary editable buffers", function()
		local calls = 0
		actions.complete = function() calls = calls + 1 end
		input("i<C-l><Esc>")
		assert.equals(1, calls)
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
			vim.api.nvim_set_current_buf(bufnr)
			vim.api.nvim_buf_delete(special, { force = true })
		end
	end)

	it("restores original trigger mappings on teardown and keeps newer mappings", function()
		completion.teardown()
		vim.keymap.set("i", "<C-l>", "original", { buffer = bufnr })
		local original = mapping("<C-l>")
		completion.setup(options)
		completion.teardown()
		assert.same(original, mapping("<C-l>"))
		completion.setup(options)
		vim.keymap.set("i", "<C-l>", "replacement", { buffer = bufnr })
		completion.teardown()
		assert.equals("replacement", mapping("<C-l>").rhs)
	end)

	it("removes decorations and editor mappings when a buffer becomes an OpenCode view", function()
		local previous_tab = mapping("<Tab>")
		completion.show(snapshot("value"), "_complete")
		vim.bo[bufnr].filetype = "opencode_chat"
		assert.same({}, marks())
		assert.same(previous_tab, mapping("<Tab>"))
		assert.is_nil(mapping("<C-l>").callback)
	end)

	it("supports disabling either mapping and clears previews on teardown", function()
		completion.setup({ enabled = true, keymaps = { trigger = false, accept = false } })
		assert.is_nil(mapping("<C-l>").callback)
		local previous_tab = mapping("<Tab>")
		completion.show(snapshot("value"), "_complete")
		assert.same(previous_tab, mapping("<Tab>"))
		completion.teardown()
		assert.same({}, marks())
	end)
end)
