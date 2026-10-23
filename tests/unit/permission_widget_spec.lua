local widget = require("opencode.ui.permission_widget")

local COMMAND = table.concat({
	"ssh qant_test 'set -e",
	'mkdir -p "$HOME/.local/bin"',
	'"$HOME/.local/bin/nvim" --version | head -1\'',
}, "\n")

local function shell(overrides)
	return vim.tbl_extend("force", {
		permission_id = "perm", permission_type = "shell", status = "pending", selected_option = 1,
		tool_name = "bash", patterns = { COMMAND }, always = { "ssh *" },
		tool_input = { command = COMMAND, description = "Install Neovim" },
	}, overrides or {})
end

local function text(lines)
	local trimmed = {}
	for _, line in ipairs(lines) do trimmed[#trimmed + 1] = (line:gsub("%s+$", "")) end
	return table.concat(trimmed, "\n")
end

local function count(haystack, needle)
	local found, init = 0, 1
	while true do
		local start = haystack:find(needle, init, true)
		if not start then return found end
		found, init = found + 1, start + #needle
	end
end

local function row(command, folded)
	return { width = 80, tool_row = { tool = "bash", command = command or COMMAND, folded = folded == true, end_line = 0 } }
end

describe("permission widget", function()
	it("shows a shell request's command once, as a bash command block", function()
		local rendered = text((widget.render(shell(), { width = 80 })))
		assert.equals(1, count(rendered, "mkdir -p"))
		assert.is_truthy(rendered:find("\n▏  shell\n▏\n▏  $ ssh qant_test 'set -e\n▏    mkdir -p", 1, true))
		assert.is_truthy(rendered:find("▏  Description: Install Neovim", 1, true))
		assert.is_nil(rendered:find("Path:", 1, true))
		assert.is_nil(rendered:find("Resource:", 1, true))
	end)

	it("aligns continuation lines of a detail under its value", function()
		local rendered = text((widget.render(shell({ message = "first\nsecond" }), { width = 80 })))
		assert.is_truthy(rendered:find("▏  Message: first\n▏           second", 1, true))
	end)

	it("keeps a requested resource the command does not show", function()
		local rendered = text((widget.render(shell({ patterns = { COMMAND, "rm -rf /" } }), { width = 80 })))
		assert.equals(1, count(rendered, "mkdir -p"))
		assert.is_truthy(rendered:find("Resource: rm -rf /", 1, true))
	end)

	it("folds a long command only when no requested resource is hidden", function()
		local lines = {}
		for i = 1, 20 do lines[i] = "echo line" .. i end
		local command = table.concat(lines, "\n")
		local folded = text((widget.render(shell({ patterns = { "echo line1" }, tool_input = { command = command } }), { width = 80 })))
		assert.is_truthy(folded:find("(8 command lines hidden)", 1, true))
		assert.is_nil(folded:find("echo line10", 1, true))
		local full = text((widget.render(shell({ patterns = { command }, tool_input = { command = command } }), { width = 80 })))
		assert.is_nil(full:find("command lines hidden", 1, true))
		assert.equals(1, count(full, "echo line10"))
		assert.is_nil(full:find("Resource:", 1, true))
	end)

	it("leaves the command to a visible bash row while the request is pending", function()
		local lines, _, meta = widget.render(shell(), row())
		local rendered = text(lines)
		assert.is_nil(rendered:find("mkdir -p", 1, true))
		assert.is_nil(rendered:find("Install Neovim", 1, true))
		assert.is_truthy(rendered:find("# Permission required for Bash", 1, true))
		assert.is_truthy(rendered:find("1. Allow once", 1, true))
		assert.equals(3, meta.interactive_count)
		assert.is_falsy(meta.attached)
		rendered = text((widget.render(shell({ patterns = { COMMAND, "rm -rf /" } }), row())))
		assert.is_truthy(rendered:find("Resource: rm -rf /", 1, true))
	end)

	it("shows the full request when the bash row folds the command", function()
		local rendered = text((widget.render(shell(), row(COMMAND, true))))
		assert.equals(1, count(rendered, "mkdir -p"))
	end)

	it("renders a decided request as one status line for the tool row", function()
		local lines, _, meta = widget.render(shell({ status = "approved", reply = "once" }), row())
		assert.same({ "▏  ✓ Allowed once", "▏" }, vim.split(text(lines), "\n"))
		assert.is_true(meta.attached)
		assert.equals(0, meta.interactive_count)
		assert.equals("▏  ✓ Always allowed: ssh *",
			text((widget.render(shell({ status = "approved", reply = "always" }), row()))):match("^[^\n]+"))
		assert.equals("▏  ✗ Rejected", text((widget.render(shell({ status = "rejected" }), row()))):match("^[^\n]+"))
		local other = text((widget.render(shell({
			permission_type = "external_directory", status = "approved", reply = "once", patterns = { "/tmp/*" },
		}), row())))
		assert.is_truthy(other:find("▏  ✓ External directory allowed once\n▏  Resource: /tmp/*", 1, true))
	end)

	it("keeps the full panel for a decided request without a tool row", function()
		local lines, _, meta = widget.render(shell({ status = "approved", reply = "once" }), { width = 80 })
		local rendered = text(lines)
		assert.is_truthy(rendered:find("# Permission allowed for Bash (once)", 1, true))
		assert.equals(1, count(rendered, "mkdir -p"))
		assert.is_nil(meta.attached)
	end)
end)
