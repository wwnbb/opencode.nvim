describe("opening tab input from an editor reference", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.request("nvim_ui_attach", { 140, 45, { rgb = true, ext_linegrid = true, ext_messages = true } })
		editor.lua([[
			_G.api, _G.chat = require("opencode"), require("opencode.ui.chat")
			_G.views, _G.workspace = require("opencode.ui.chat.state"), require("opencode.ui.chat.workspace")
			_G.input, _G.sessions = require("opencode.ui.input"), require("opencode.session")
			vim.notify = function() end
			api.setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab", session_tabs = { persist = false } } })
			require("opencode.lifecycle").ensure_connected = function(callback) callback() end
			require("opencode.client").get_messages = function(_, _, callback) callback(nil, {}) end
			_G.source, _G.source_window = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
			vim.api.nvim_buf_set_name(source, vim.fn.tempname() .. ".rs")
			vim.bo[source].filetype = "rust"
			vim.api.nvim_buf_set_lines(source, 0, -1, false, { "fn main() {", "    work();", "}" })
			_G.editor_tabs = vim.api.nvim_list_tabpages()
			_G.editor_tabline, _G.editor_showtabline = "%#TabLineSel#Editor tabs", 1
			vim.o.tabline, vim.o.showtabline = editor_tabline, editor_showtabline
			vim.g.mapleader = " "
			vim.keymap.set("x", "<leader>oe", api.add_visual_selection_and_open_input)
			vim.keymap.set("n", "<leader>oe", api.add_current_line_and_open_input)
			_G.seed = function(id)
				local session = { id = id, title = id, directory = vim.fn.getcwd() }
				sessions.remember(session)
				return session
			end
		]])
	end)
	after_each(function() if editor then editor.close() end end)

	for _, selection in ipairs({ true, false }) do
		for _, parked in ipairs({ false, true }) do
			it("registers and restores the workspace (selection=" .. tostring(selection) .. ", parked=" .. tostring(parked) .. ")", function()
				if parked then
					editor.lua([[
						seed("reference-a"); sessions.set_active("reference-a", "reference-a")
						chat.open()
						_G.first = chat.get_view()
						_G.second = chat.create_split(first, seed("reference-b"), "vertical")
						chat.create_layout(seed("reference-c"))
						chat.focus_view(second)
						_G.layout_id = workspace.current().id
						input.set_pending_text("Existing draft")
						chat.toggle()
						assert(workspace.is_parked())
					]])
				end
				editor.feed(selection and "ggVj<Space>oe" or "gg<Space>oe")
				assert.is_true(vim.wait(3000, function()
					return editor.lua("return input.is_visible() and vim.bo.filetype == 'opencode_input'")
				end, 10), "reference did not focus the composer")
				editor.lua([[
					local selection, parked = ...
					assert(workspace.current(), "input opened a native tab without a workspace")
					assert(not workspace.is_parked())
					assert(vim.o.tabline:find("__opencode_workspace_tab_click", 1, true), "native editor tabs leaked into OpenCode")
					assert(#vim.api.nvim_list_tabpages() == #editor_tabs + 1)
					local owner = input.owner_view()
					assert(owner.session_bound and owner.workspace_id == workspace.current().id)
					local text = input.get_pending_text()
					local reference = "@" .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source), ":~:.")
						.. (selection and "#1-2\n```rust\nfn main() {\n    work();\n```\n" or "#1\n```rust\nfn main() {\n```\n")
					assert(text == (parked and "Existing draft\n\n" or "") .. reference, text)
					if parked then
						assert(owner == second and workspace.current().id == layout_id and #workspace.list() == 2)
						assert(first.visible and second.visible and vim.api.nvim_win_is_valid(first.winid))
					else assert(#workspace.list() == 1) end
					vim.cmd("stopinsert")
					vim.api.nvim_set_current_win(source_window)
					assert(vim.wait(1000, workspace.is_parked, 5), "leaving input did not hide its native tab")
					assert(vim.deep_equal(editor_tabs, vim.api.nvim_list_tabpages()), "OpenCode tab leaked into the editor")
					assert(vim.o.tabline == editor_tabline and vim.o.showtabline == editor_showtabline)
					assert(require("opencode.ui.input.history").get_pending(views.session(owner).id) == text)
				]], { selection, parked })
			end)
		end
	end
end)
