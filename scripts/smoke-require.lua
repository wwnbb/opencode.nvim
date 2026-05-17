-- Headless module-load smoke test for opencode.nvim.
-- Run with: nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke-require.lua

local function stub_module(name, value)
	package.preload[name] = package.preload[name] or function()
		return value
	end
end

local noop = function() end
local popup = {}
popup.__index = popup
function popup:new(opts)
	return setmetatable({ opts = opts or {}, bufnr = 1, winid = 1 }, self)
end
function popup:mount() end
function popup:unmount() end
function popup:map() end
function popup:on() end

local line = {}
line.__index = line
function line:new()
	return setmetatable({ _content = "" }, self)
end
function line:append(text)
	self._content = self._content .. tostring(text or "")
end
function line:content()
	return self._content
end
function line:highlight() end
setmetatable(line, {
	__call = function(cls)
		return cls:new()
	end,
})

stub_module("nui.popup", popup)
stub_module("nui.input", popup)
stub_module("nui.split", popup)
stub_module("nui.layout", { new = function() return popup:new() end })
stub_module("nui.line", line)
stub_module("nui.text", function(text) return text end)
stub_module("nui.utils.autocmd", { event = setmetatable({}, { __index = function(_, key) return key end }) })
stub_module("plenary.job", {
	new = function(_, opts)
		return {
			pid = 0,
			start = noop,
			shutdown = noop,
			opts = opts or {},
		}
	end,
})

local function scandir(dir, out)
	out = out or {}
	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return out
	end
	while true do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		local path = dir .. "/" .. name
		if kind == "directory" then
			scandir(path, out)
		elseif kind == "file" and path:match("%.lua$") then
			table.insert(out, path)
		end
	end
	return out
end

local function module_name(path)
	local name = path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/", ".")
	return name:gsub("%.init$", "")
end

local failures = {}
local files = scandir("lua/opencode")
table.sort(files)
for _, path in ipairs(files) do
	local mod = module_name(path)
	local ok, err = pcall(require, mod)
	if not ok then
		table.insert(failures, string.format("%s: %s", mod, tostring(err)))
	end
end

if #failures > 0 then
	print("Smoke require failures:")
	for _, failure in ipairs(failures) do
		print("  " .. failure)
	end
	os.exit(1)
end

local setup_ok, setup_err = pcall(function()
	local opencode = require("opencode")
	opencode.setup({
		server = {
			auto_start = false,
		},
		lualine = {
			enabled = true,
		},
	})
	assert(type(opencode.open_input_at_end) == "function", "open_input_at_end is not exported")
	assert(type(opencode.add_current_line) == "function", "add_current_line is not exported")
	assert(type(opencode.add_current_line_and_open_input) == "function", "add_current_line_and_open_input is not exported")
	assert(type(opencode.add_visual_selection) == "function", "add_visual_selection is not exported")
	assert(
		type(opencode.add_visual_selection_and_open_input) == "function",
		"add_visual_selection_and_open_input is not exported"
	)
	assert(type(opencode.active_sessions) == "function", "active_sessions is not exported")
	assert(type(opencode.toggle_danger_mode) == "function", "toggle_danger_mode is not exported")
	assert(type(opencode.new_session) == "function", "new_session is not exported")
	assert(type(opencode.is_danger_mode_enabled) == "function", "is_danger_mode_enabled is not exported")
	opencode.enable_danger_mode({ silent = true })
	assert(opencode.is_danger_mode_enabled() == true, "danger mode did not enable")
	opencode.disable_danger_mode({ silent = true })
	assert(opencode.is_danger_mode_enabled() == false, "danger mode did not disable")
	local component = opencode.lualine_component()
	assert(type(component) == "string", "lualine component did not return a string")

	local slash = require("opencode.slash")
	local slash_commands = {}
	for _, command in ipairs(slash.get_commands()) do
		slash_commands[command.name] = command
	end
	assert(slash_commands.clear ~= nil, "/clear is not registered")
	assert(slash_commands.new ~= nil, "/new is not registered")
	for _, alias in ipairs(slash_commands.new.aliases or {}) do
		assert(alias ~= "clear", "/clear must not be an alias for /new")
	end

	local app_state = require("opencode.state")
	app_state.set_session("runtime-session", "Runtime Session")
	app_state.set_recent_sessions({
		{ id = "historical-session", title = "Historical Session", messageCount = 5 },
	}, 30)
	assert(
		app_state.get_session_record("historical-session").message_count == 5,
		"backend messageCount did not update session record"
	)
	app_state.upsert_session({ id = "remembered-session", title = "Remembered Session" }, { touch = false })
	local active_by_id = {}
	for _, session in ipairs(app_state.get_active_sessions()) do
		active_by_id[session.id] = true
	end
	assert(active_by_id["runtime-session"] == true, "runtime session is missing from active sessions")
	assert(active_by_id["historical-session"] ~= true, "historical session leaked into active sessions")
	assert(active_by_id["remembered-session"] ~= true, "untouched remembered session leaked into active sessions")
	vim.cmd("new")
	local winid = vim.api.nvim_get_current_win()
	require("opencode.ui.chat.state").state.winid = winid
	require("opencode.ui.chat").update_winbar()
	assert(vim.wo[winid].winbar:match("Runtime Session"), "chat winbar did not render runtime session tab")
	vim.cmd("bwipeout!")
	app_state.set_session("child-session", "Child Session", { runtime = false })
	active_by_id = {}
	for _, session in ipairs(app_state.get_active_sessions()) do
		active_by_id[session.id] = true
	end
	assert(active_by_id["runtime-session"] == true, "runtime root disappeared while viewing child session")
	assert(active_by_id["child-session"] ~= true, "child session leaked into active sessions")
	local sync = require("opencode.sync")
	sync.handle_message_updated({
		id = "task-message",
		sessionID = "runtime-session",
		role = "assistant",
		time = { created = 1 },
	})
	sync.handle_part_updated({
		id = "task-part",
		messageID = "task-message",
		sessionID = "runtime-session",
		type = "tool",
		tool = "task",
		metadata = { sessionId = "child-session" },
	})
	local widget_support = require("opencode.ui.chat.widget_support")
	assert(
		widget_support.should_render("child-session", "pending", "runtime-session", false) == true,
		"runtime root should render pending widgets from its task child"
	)
	assert(
		widget_support.should_render("historical-session", "pending", "runtime-session", false) == false,
		"unrelated root session widget leaked into selected chat"
	)
	app_state.remove_session("runtime-session")
	active_by_id = {}
	for _, session in ipairs(app_state.get_active_sessions()) do
		active_by_id[session.id] = true
	end
	assert(active_by_id["runtime-session"] ~= true, "removed session leaked into active sessions")
	app_state.set_message_count(7)
	app_state.set_session(nil, nil)
	assert(app_state.get_message_count() == 0, "clearing active session should reset message count")
end)

if not setup_ok then
	print("Smoke setup failure:")
	print("  " .. tostring(setup_err))
	os.exit(1)
end

print("Smoke require/setup passed")
