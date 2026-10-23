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

	it("asks on a visible bash row's panel while the request is pending", function()
		local lines, _, meta = widget.render(shell(), row())
		local rows = vim.split(text(lines), "\n")
		assert.same({ "▏  △ Allow this command?", "▏  ❯ 1. Allow once" }, { rows[1], rows[2] })
		assert.equals("▏", rows[#rows])
		local rendered = text(lines)
		assert.is_nil(rendered:find("mkdir -p", 1, true))
		assert.is_nil(rendered:find("Install Neovim", 1, true))
		assert.is_nil(rendered:find("# Permission", 1, true))
		assert.equals(3, meta.interactive_count)
		assert.is_true(meta.attached)
		rendered = text((widget.render(shell({ patterns = { COMMAND, "rm -rf /" } }), row())))
		assert.is_truthy(rendered:find("△ Allow this command?\n▏  Resource: rm -rf /\n▏  ❯ 1. Allow once", 1, true))
	end)

	it("indents wrapped command rows past the prompt", function()
		local long = 'ssh qant_test "docker exec -u root PythonTest3 tar -C /home/cs/logs -cf - out.log"'
		local rows = vim.split(text((widget.render(shell({ patterns = { long }, tool_input = { command = long } }),
			{ width = 40 }))), "\n")
		local first
		for index, line in ipairs(rows) do
			if line:find("▏  $ ssh", 1, true) == 1 then first = index end
		end
		assert.is_not_nil(first)
		assert.is_truthy(rows[first + 1]:find("^▏    %S"))
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
		assert.same({ "▏  ✓ External directory allowed once: /tmp/*", "▏" }, vim.split(other, "\n"))
	end)

	it("names the saved patterns once and lists requested resources they do not cover", function()
		local function directory(overrides)
			return vim.tbl_extend("force", {
				permission_id = "dir", permission_type = "external_directory", status = "approved", reply = "always",
				patterns = { "/srv/data/*" }, always = { "/srv/data/*" },
			}, overrides or {})
		end
		assert.same({ "▏  ✓ External directory always allowed: /srv/data/*", "▏" },
			vim.split(text((widget.render(directory(), row()))), "\n"))
		assert.same({ "▏  ✓ External directory always allowed: /srv/*", "▏  Resource: /srv/data/*", "▏" },
			vim.split(text((widget.render(directory({ always = { "/srv/*" } }), row()))), "\n"))
		assert.same({ "▏  ✓ External directory always allowed", "▏  Resource: /srv/data/*", "▏" },
			vim.split(text((widget.render(directory({ always = { "*" } }), row()))), "\n"))
	end)

	it("indents a decision under a compact list row without a panel", function()
		local compact = { width = 80, tool_row = { tool = "read", command = "", folded = false, compact = true, end_line = 0 } }
		local lines, highlights, meta = widget.render({
			permission_id = "dir", permission_type = "external_directory", status = "approved", reply = "always",
			patterns = { "/srv/data/*" }, always = { "/srv/data/*" }, message = "for the fixtures",
		}, compact)
		assert.same({ "     ✓ External directory always allowed: /srv/data/*", "     Message: for the fixtures" },
			vim.split(text(lines), "\n"))
		assert.is_true(meta.attached)
		for _, hl in ipairs(highlights) do
			assert.is_truthy(hl.hl_group:find("^OpenCodePermissionList"), hl.hl_group)
		end
		assert.same({ "     ✗ Rejected: lua/opencode/init.lua" }, vim.split(text((widget.render({
			permission_id = "read", permission_type = "read", status = "rejected",
			patterns = { vim.fn.getcwd() .. "/lua/opencode/init.lua" },
		}, compact))), "\n"))
	end)

	it("keeps the full panel for a decided request without a tool row", function()
		local lines, _, meta = widget.render(shell({ status = "approved", reply = "once" }), { width = 80 })
		local rendered = text(lines)
		assert.is_truthy(rendered:find("# Permission allowed for Bash (once)", 1, true))
		assert.equals(1, count(rendered, "mkdir -p"))
		assert.is_nil(meta.attached)
	end)
end)
