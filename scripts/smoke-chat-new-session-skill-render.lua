-- Real OpenCode server smoke test for the chat render regression after
-- starting a new session and loading a skill.
--
-- Run with:
--   ./scripts/test-headless.sh scripts/smoke-chat-new-session-skill-render.lua

local function fail(message)
	error(message, 0)
end

local function assert_true(value, message)
	if not value then
		fail(message)
	end
end

local function wait_for(timeout, predicate, message)
	assert_true(vim.wait(timeout, predicate, 50), message)
end

local function executable(path)
	return type(path) == "string" and path ~= "" and vim.fn.executable(path) == 1
end

local function resolve_opencode_command()
	local path_cmd = vim.fn.exepath("opencode")
	if executable(path_cmd) then
		return path_cmd
	end

	local home_cmd = vim.fn.expand("~/.opencode/bin/opencode")
	if executable(home_cmd) then
		return home_cmd
	end

	fail("opencode executable not found")
end

local function buffer_text(chat)
	local bufnr = chat.get_bufnr()
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function wait_for_buffer_contains(chat, needle, message)
	wait_for(120000, function()
		return buffer_text(chat):find(needle, 1, true) ~= nil
	end, message)
end

local function press_chat_new_session(chat)
	chat.focus()
	local mapping = vim.fn.maparg("N", "n", false, true)
	if type(mapping) == "table" and type(mapping.callback) == "function" then
		mapping.callback()
		return
	end

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("N", true, false, true), "m", false)
end

vim.o.columns = 120
vim.o.lines = 36
vim.opt.runtimepath:append(vim.fn.getcwd())

local opencode_command = resolve_opencode_command()

local opencode = require("opencode")
local lifecycle = require("opencode.lifecycle")
local app_state = require("opencode.state")
local chat = require("opencode.ui.chat")
local slash = require("opencode.slash")

local function cleanup()
	pcall(function()
		chat.close()
	end)
end

local function main()
	opencode.setup({
		server = {
			command = opencode_command,
			auto_start = true,
			lazy = true,
			reuse_running = false,
			startup_timeout = 30000,
			health_check_interval = 250,
			shutdown_on_exit = true,
			use_shell_env = true,
		},
		session = {
			parallel = {
				enabled = true,
				use_prompt_async = true,
			},
		},
		chat = {
			layout = "vertical",
			position = "right",
			width = 80,
			close_on_focus_lost = false,
			session_tabs = {
				enabled = true,
				max_tabs = 4,
			},
		},
		lualine = {
			enabled = false,
		},
		danger_mode = true,
	})

	local connected = false
	lifecycle.ensure_connected(function()
		connected = true
	end)
	wait_for(45000, function()
		return connected and app_state.get_connection() == "connected"
	end, "real OpenCode server did not connect")

	chat.open()
	local previous_session_id = app_state.get_session().id
	press_chat_new_session(chat)
	wait_for(30000, function()
		local current = app_state.get_session()
		return current.id and current.id ~= previous_session_id
	end, "pressing chat N did not activate a real new session")
	local new_session_id = app_state.get_session().id

	local parsed = slash.parse("/skill caveman")
	assert_true(parsed ~= nil and slash.execute(parsed) == true, "/skill caveman was not handled")

	wait_for_buffer_contains(chat, 'Skill "caveman"', "real caveman skill tool did not render after N-created session")
	opencode.send("Print exactly this token and nothing else: SMOKE_CAVEMAN_RENDER_DONE")
	wait_for_buffer_contains(chat, "SMOKE_CAVEMAN_RENDER_DONE", "real assistant follow-up did not render after skill load")
	assert_true(app_state.get_session().id == new_session_id, "skill load changed away from the N-created session")
end

local ok, err = xpcall(main, debug.traceback)
cleanup()

if not ok then
	fail(err)
end

print("Real OpenCode new-session skill render smoke passed")
