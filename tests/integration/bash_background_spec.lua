local chat_surface = require("tests.helpers.chat_surface")
local app = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local tasks = require("opencode.ui.chat.tasks")
local tree = require("opencode.ui.chat.widget_tree")
local projection = require("opencode.protocol.messages")

local session = "bash-background"
local SHELL_ID = "sh_background_0123456789"
local FILE = "/tmp/opencode-shell/" .. SHELL_ID .. ".out"
-- Native tool text: the first two lines describe the job, the rest instructs the model.
local MOVED = "Command moved to the background (shell ID: " .. SHELL_ID .. ").\nOutput is streaming to: " .. FILE
local MODEL_NOTE = "You will be notified automatically when the command finishes. DO NOT poll for completion."

local function shell_call()
	return { type = "tool", id = "call-background", name = "shell", state = {
		status = "completed",
		input = { command = "go test ./...", description = "Run tests" },
		content = { { type = "text", text = MOVED }, { type = "text", text = MODEL_NOTE } },
		metadata = { status = "running", shellID = SHELL_ID, truncated = false },
	} }
end

local function assistant()
	return { id = "assistant", type = "assistant", time = { created = 1, completed = 2 }, content = { shell_call() } }
end

local function notice(metadata)
	metadata = vim.tbl_extend("force", { source = "shell", state = "completed", exit = 0,
		shellID = SHELL_ID, jobID = SHELL_ID }, metadata or {})
	return {
		id = "shell-notice", type = "synthetic", time = { created = 3 },
		description = "go test ./...", metadata = metadata,
		text = '<shell id="' .. SHELL_ID .. '" state="' .. metadata.state .. '" command="go test ./...">\nok\n</shell>',
	}
end

local function update(messages)
	sync.clear_session_messages(session)
	sync.handle_session_messages(session, projection.page(session, messages))
	chat.do_render()
	return sync.get_parts("assistant")[1]
end

local function block(part)
	local pos = assert(tree.find(state.tools, part.id))
	return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, pos.start_line, pos.end_line + 1, false), "\n")
end

local function contains(text, value)
	assert.is_truthy(text:find(value, 1, true), "missing literal text: " .. value .. "\n" .. text)
end

local function absent(text, value)
	assert.is_nil(text:find(value, 1, true), "unexpected text: " .. value .. "\n" .. text)
end

describe("bash commands moved to the background", function()
	local surface
	before_each(function()
		surface = chat_surface.setup()
		state.config = vim.deepcopy(app.get_config().chat)
		state.config.session_tabs.enabled = false
		app.set_session(session, "Background shell")
		app.set_session_status(session, { type = "idle" })
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr)
	end)

	after_each(function()
		tasks.stop_task_animation_timer()
		chat_surface.restore(surface)
	end)

	it("shows a running background command without the model-facing instructions", function()
		local part = update({ assistant() })
		local text = block(part)
		contains(text, "# Run tests · running in background")
		contains(text, "$ go test ./...")
		contains(text, "Output: " .. FILE)
		absent(text, "Command moved to the background")
		absent(text, "You will be notified")
		absent(text, SHELL_ID .. ")")
		assert.is_true(tasks.is_animating_tool_part(part))

		tasks.handle_tool_toggle(part.id)
		contains(block(part), "Shell ID: " .. SHELL_ID)
	end)

	it("takes the outcome from the matching shell completion notice", function()
		for _, case in ipairs({
			{ metadata = {}, label = "· finished in background" },
			{ metadata = { exit = 2 }, label = "· failed in background · exit 2" },
			{ metadata = { state = "cancelled", exit = vim.NIL }, label = "· cancelled in background" },
		}) do
			update({ assistant() })
			local part = update({ assistant(), notice(case.metadata) })
			local text = block(part)
			contains(text, "# Run tests " .. case.label)
			absent(text, "running in background")
			assert.is_false(tasks.is_animating_tool_part(part))
		end
	end)

	it("ignores notices for other shells", function()
		local part = update({ assistant(), notice({ shellID = "sh_other", jobID = "sh_other" }) })
		contains(block(part), "· running in background")
	end)

	it("leaves foreground results unchanged", function()
		local call = shell_call()
		call.state.metadata, call.state.content = { exit = 0 }, { { type = "text", text = "ok" } }
		local part = update({ { id = "assistant", type = "assistant", time = { created = 1, completed = 2 }, content = { call } } })
		local text = block(part)
		contains(text, "# Run tests")
		absent(text, "background")
		contains(text, "ok")
	end)
end)
