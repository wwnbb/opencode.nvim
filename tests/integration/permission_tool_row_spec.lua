local chat_surface = require("tests.helpers.chat_surface")
local sync = require("opencode.sync")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local state = require("opencode.ui.chat.state").state
local projection = require("opencode.protocol.messages")
local permissions = require("opencode.permission.state")

local COMMAND = "ssh qant_test 'set -e\nmkdir -p \"$HOME/.local/bin\"\nnvim --version'"

local function seed(command)
	sync.handle_session_messages("permission-row", { projection.project("permission-row", {
		id = "message", type = "assistant", time = { created = 1 }, content = {
			{ type = "tool", id = "call", name = "bash", state = { status = "running", input = {
				command = command, description = "Install Neovim",
			} } },
		},
	}) })
end

local function ask(id, permission_type, opts)
	return permissions.add_permission(id, "permission-row", permission_type, vim.tbl_extend("force", {
		message_id = "message", call_id = "call", tool_name = "bash",
		patterns = { COMMAND }, always = { "ssh *" }, tool_input = { command = COMMAND },
	}, opts or {}))
end

local function lines()
	return vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
end

local function count(needle)
	local found = 0
	for _, line in ipairs(lines()) do
		if line:find(needle, 1, true) then found = found + 1 end
	end
	return found
end

local function tool_row()
	return state.tools[sync.get_parts("message")[1].id]
end

describe("permission widgets under their tool row", function()
	local surface
	before_each(function()
		surface = chat_surface.setup()
		permissions.clear_all()
		app.set_session("permission-row", "Permissions")
		chat.setup({ session_tabs = { enabled = false } })
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr, {})
	end)
	after_each(function()
		permissions.clear_all()
		chat_surface.restore(surface)
	end)

	it("asks below the bash row without repeating its command", function()
		seed(COMMAND)
		local pending = ask("perm", "shell")
		chat.do_render()
		assert.equals(1, count("mkdir -p"))
		assert.equals(1, count("# Permission required for Bash"))
		local reject_row
		for row, line in ipairs(lines()) do
			if line:find("3. Reject", 1, true) then reject_row = row end
		end
		assert.is_not_nil(reject_row)
		vim.api.nvim_win_set_cursor(state.winid, { reject_row, 0 })
		require("opencode.ui.chat.interactions").sync_widget_selection_from_cursor()
		assert.equals(3, pending.selected_option)
	end)

	it("shows the decision as a status line on the bash panel", function()
		seed(COMMAND)
		ask("perm", "shell")
		permissions.mark_approved("perm", "once")
		chat.do_render()
		local position = state.permissions.perm
		assert.equals(tool_row().end_line + 1, position.start_line)
		assert.equals("▏  ✓ Allowed once", vim.trim(lines()[position.start_line + 1]))
		assert.equals(1, count("mkdir -p"))
		assert.equals(0, count("Permission allowed"))
	end)

	it("chains every decided permission of the call on the bash panel", function()
		seed(COMMAND)
		ask("perm_dir", "external_directory", { timestamp = 1, patterns = { "/tmp/*" } })
		ask("perm_shell", "shell", { timestamp = 2 })
		permissions.mark_approved("perm_dir", "once")
		permissions.mark_rejected("perm_shell")
		chat.do_render()
		local first, second = state.permissions.perm_dir, state.permissions.perm_shell
		assert.equals(tool_row().end_line + 1, first.start_line)
		assert.equals(first.end_line + 1, second.start_line)
		assert.equals("▏  ✓ External directory allowed once", vim.trim(lines()[first.start_line + 1]))
		assert.equals("▏  ✗ Rejected", vim.trim(lines()[second.start_line + 1]))
	end)

	it("shows the full request when the bash row folds part of the command", function()
		local long = {}
		for i = 1, 20 do long[i] = "echo line" .. i end
		local command = table.concat(long, "\n")
		seed(command)
		ask("perm", "shell", { patterns = { command }, tool_input = { command = command } })
		chat.do_render()
		assert.equals(1, count("echo line15"))
		assert.equals(2, count("echo line1 "))
	end)
end)
