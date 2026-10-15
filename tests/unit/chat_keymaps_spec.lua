local keymaps = require("opencode.util.keymap")
local chat = require("opencode.ui.chat.state").state
local app = require("opencode.state")
local bindings = require("opencode.ui.chat.keymaps")

describe("configurable chat controls", function()
	local bufnr, saved_config, saved_chat, replacements
	local function replace(module, field, value)
		replacements[#replacements + 1] = { module, field, module[field] }
		module[field] = value
	end
	local function mapping(key)
		for _, item in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
			if keymaps.matches(item.lhs, key) then return item end
		end
	end
	local function setup(values, opts)
		chat.config = { keymaps = values }
		bindings.setup_buffer(bufnr, opts)
	end
	local function text(lines) return table.concat(lines, "\n"):gsub("▏", ""):gsub("%s+", " ") end
	before_each(function()
		saved_config, saved_chat = app.get_config(), chat.config
		app.set_config({})
		bufnr = vim.api.nvim_create_buf(false, true)
		replacements = {}
	end)
	after_each(function()
		for _, item in ipairs(replacements) do item[1][item[2]] = item[3] end
		if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		chat.config = saved_chat
		app.set_config(saved_config)
	end)

	it("disables every chat action without installing buffer mappings", function()
		local disabled = {}
		for action in pairs(keymaps.get("chat")) do disabled[action] = false end
		setup(disabled)
		assert.same({}, vim.api.nvim_buf_get_keymap(bufnr, "n"))
	end)

	it("prioritizes a configured close key over the default new-session key", function()
		local closed = 0
		setup({ close = "N" }, { close = function() closed = closed + 1 end })
		assert.is_nil(mapping("q"))
		mapping("N").callback()
		assert.equals(1, closed)
		assert.equals("N", keymaps.label("chat", "close", chat.config.keymaps))
		assert.equals("(disabled)", keymaps.label("chat", "new_session", chat.config.keymaps))
	end)

	it("supports aliases and passes the pressed key to widget dispatch", function()
		local tasks = require("opencode.ui.chat.tasks")
		replace(tasks, "get_tool_at_cursor", function() end)
		replace(tasks, "handle_tool_confirm", function() return false end)
		local received = {}
		replace(require("opencode.ui.chat.interactions"), "handle_question_confirm", function(key)
			received[#received + 1] = key
		end)
		setup({ confirm = { "<F3>", "<F4>" }, resolve_edit = false })
		assert.is_nil(mapping("<CR>"))
		mapping("<F3>").callback()
		mapping("<F4>").callback()
		assert.same({ "<F3>", "<F4>" }, received)
	end)

	it("shares default Enter between edit resolution and other widget confirmation", function()
		local tasks = require("opencode.ui.chat.tasks")
		replace(tasks, "get_tool_at_cursor", function() end)
		replace(tasks, "handle_tool_confirm", function() return false end)
		local edit, confirmed, resolved = nil, 0, 0
		local edits = require("opencode.ui.chat.edits")
		replace(edits, "get_edit_at_cursor", function() return edit end)
		replace(edits, "handle_edit_resolve_file", function() resolved = resolved + 1 end)
		replace(require("opencode.ui.chat.interactions"), "handle_question_confirm", function() confirmed = confirmed + 1 end)
		setup({})
		assert.equals("<CR>", keymaps.label("chat", "confirm", chat.config.keymaps))
		mapping("<CR>").callback()
		assert.equals(1, confirmed)
		edit = "edit"
		mapping("<CR>").callback()
		assert.equals(1, resolved)
		assert.equals(1, confirmed)
	end)

	it("separates Enter and manual edit resolution after remapping", function()
		local tasks = require("opencode.ui.chat.tasks")
		replace(tasks, "get_tool_at_cursor", function() end)
		replace(tasks, "handle_tool_confirm", function() return false end)
		local confirmed, resolved = 0, 0
		local edits = require("opencode.ui.chat.edits")
		replace(edits, "get_edit_at_cursor", function() return "edit" end)
		replace(edits, "handle_edit_resolve_file", function() resolved = resolved + 1 end)
		replace(require("opencode.ui.chat.interactions"), "handle_question_confirm", function() confirmed = confirmed + 1 end)
		setup({ resolve_edit = "<F7>" })
		mapping("<CR>").callback()
		mapping("<F7>").callback()
		assert.equals(1, confirmed)
		assert.equals(1, resolved)
	end)

	it("keeps counted session navigation when digit actions are remapped", function()
		local selected
		replace(require("opencode.ui.chat.interactions"), "handle_question_number_select", function() return false end)
		replace(require("opencode.ui.chat.session_tabs"), "go_to_session_tab", function(index) selected = index end)
		setup({ select_3 = "<F3>", next_session = "<F8>" })
		assert.is_nil(mapping("3"))
		mapping("<F3>").callback()
		mapping("<F8>").callback()
		assert.equals(3, selected)
	end)

	it("renders aliases and disabled actions in question and permission hints", function()
		chat.config = { keymaps = { confirm = { "<F3>", "<F4>" }, back = "<F5>",
			custom_input = false, widget_message = "<F6>", select_1 = "<F1>" } }
		local question = require("opencode.ui.question_widget").get_lines_for_question("q", {
			questions = { { question = "Choose", custom = true, options = { { label = "One" } } } },
		}, { current_tab = 1, selections = {} }, "pending")
		local rendered = text(question)
		assert.is_truthy(rendered:find("<F3> / <F4> continue", 1, true))
		assert.is_truthy(rendered:find("(disabled) custom", 1, true))
		assert.is_truthy(rendered:find("<F1> select", 1, true))
		local permission = require("opencode.ui.permission_widget").get_lines_for_permission("p", {
			permission_type = "bash", status = "pending", selected_option = 1,
		})
		rendered = text(permission)
		assert.is_truthy(rendered:find("<F3> / <F4> confirm", 1, true))
		assert.is_truthy(rendered:find("<F5> reject", 1, true))
		assert.is_truthy(rendered:find("<F6> message", 1, true))
	end)

	it("configures help controls and displays actual input history keys", function()
		app.set_config({ input = { keymaps = { history_prev = "<F9>", history_next = "<F10>" } },
			help = { keymaps = { close = "<F12>", down = false } } })
		local popup = require("opencode.ui.chat.help").show({ keymaps = { new_session = "<F5>" } })
		local ok, err = xpcall(function()
			local mappings = {}
			for _, item in ipairs(vim.api.nvim_buf_get_keymap(popup.bufnr, "n")) do mappings[item.lhs] = item end
			assert.is_nil(mappings.q)
			assert.is_nil(mappings.j)
			assert.is_truthy(mappings["<F12>"])
			local rendered = table.concat(vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false), "\n")
			assert.is_truthy(rendered:find("<F9> / <F10>", 1, true))
			assert.is_truthy(rendered:find("<F5>", 1, true))
		end, debug.traceback)
		popup:close()
		assert.is_true(ok, err)
	end)

	it("uses standalone form shortcuts in external-step hints and notices", function()
		app.set_config({ form = { keymaps = { confirm = "<F7>", custom = "<F8>" } } })
		chat.config = { keymaps = { confirm = "<F3>", custom_input = "<F4>" } }
		local url = "https://example.test/authorize"
		local lines = require("opencode.ui.question_widget").get_lines_for_question("f", {
			questions = { { field_type = "external", question = "Authorize", url = url } },
		}, { keymap_scope = "form", current_tab = 1, selections = {} }, "pending")
		local rendered = text(lines)
		assert.is_truthy(rendered:find("<F7>: open link", 1, true))
		assert.is_truthy(rendered:find("<F8>: copy link", 1, true))
		assert.is_nil(rendered:find("<F3>", 1, true))
		local notices = {}
		replace(vim, "notify", function(message) notices[#notices + 1] = message end)
		replace(vim.ui, "open", function() return nil, "unavailable" end)
		replace(vim.fn, "setreg", function() end)
		replace(vim.fn, "getreg", function() return url end)
		local external = require("opencode.ui.form_external")
		assert.is_false(external.open(url, "form"))
		assert.is_true(external.copy(url, "form"))
		assert.is_truthy(notices[1]:find("<F8>", 1, true))
		assert.is_truthy(notices[2]:find("<F7>", 1, true))
	end)

	it("configures execute view aliases and disables inherited close keys", function()
		app.set_config({ execute_details = { keymaps = { raw = { "<F2>", "<F3>" }, close = false,
			back = false, next_view = false } } })
		local details = require("opencode.ui.chat.execute_details")
		local popup = details.open({ state = { status = "completed", output = "output" } })
		local ok, err = xpcall(function()
			local mappings = {}
			for _, item in ipairs(vim.api.nvim_buf_get_keymap(popup.bufnr, "n")) do mappings[item.lhs] = item end
			assert.is_nil(mappings.q)
			assert.is_nil(mappings["<Esc>"])
			assert.is_nil(mappings["<Tab>"])
			assert.is_nil(mappings["2"])
			mappings["<F2>"].callback()
			assert.equals("raw", popup.view)
			popup.set_view("code")
			mappings["<F3>"].callback()
			assert.equals("raw", popup.view)
		end, debug.traceback)
		details.close()
		assert.is_true(ok, err)
	end)

	it("restores editor mappings when a configured inline diff is closed", function()
		local path = vim.fn.tempname()
		vim.fn.writefile({ "before" }, path)
		local previous_tab, visible = vim.api.nvim_get_current_tabpage(), chat.visible
		local edits, reviews = require("opencode.ui.chat.edits"), require("opencode.edit.state")
		local tab, actual
		chat.visible = false
		app.set_config({ server = { shared_filesystem = true }, inline_diff = {
			keymaps = { close = "<F9>", confirm = false, reject = false, apply_all = false, help = false },
		} })
		local ok, err = xpcall(function()
			vim.cmd("tabnew " .. vim.fn.fnameescape(path))
			tab, actual = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_buf()
			local original = function() end
			vim.keymap.set("n", "<F9>", original, { buffer = actual })
			local review = reviews.add_edit("keymap-review", "s", {
				{ fileID = "f", filePath = path, before = "before\n", after = "after\n", type = "update" },
			}, { transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
			edits.open_inline_diff_split(review.files[1], { edit_id = "keymap-review", file_index = 1 })
			local installed
			for _, item in ipairs(vim.api.nvim_buf_get_keymap(actual, "n")) do
				if item.lhs == "<F9>" then installed = item.callback end
				assert.is_false(keymaps.matches(item.lhs, "<C-a>"))
			end
			assert.is_truthy(installed)
			assert.is_false(installed == original)
			installed()
			local restored
			for _, item in ipairs(vim.api.nvim_buf_get_keymap(actual, "n")) do
				if item.lhs == "<F9>" then restored = item.callback end
			end
			assert.equals(original, restored)
		end, debug.traceback)
		edits.close_inline_diff_split({ silent = true })
		reviews.clear_all()
		if tab and vim.api.nvim_tabpage_is_valid(tab) then
			vim.api.nvim_set_current_tabpage(tab)
			vim.cmd("tabclose!")
		end
		vim.api.nvim_set_current_tabpage(previous_tab)
		if actual and vim.api.nvim_buf_is_valid(actual) then vim.api.nvim_buf_delete(actual, { force = true }) end
		chat.visible = visible
		vim.fn.delete(path)
		assert.is_true(ok, err)
	end)
end)
