-- Real integration palette/forms against the public-sentinel fixture plugin.
local app, client = require("opencode"), require("opencode.client")
local state, chat = require("opencode.state"), require("opencode.ui.chat")
local lifecycle, palette = require("opencode.lifecycle"), require("opencode.ui.palette")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local function wait(predicate, why) assert(vim.wait(15000, predicate, 20), why) end
local function await(register)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return value
end
local function key(name)
	local map = vim.fn.maparg(name, "n", false, true)
	assert(type(map.callback) == "function", "Missing mapping " .. name); map.callback()
end
local function current_text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end
local function screen_text()
	local lines = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		vim.list_extend(lines, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
	end
	return table.concat(lines, "\n")
end
local function shot(name)
	if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw!"); vim.rpcnotify(1, "opencode_screenshot", name) end
end
local function search(value)
	wait(function() return vim.bo.filetype == "opencode_float" end, "No menu")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { value })
	vim.api.nvim_exec_autocmds("TextChangedI", { buffer = vim.api.nvim_get_current_buf() })
	vim.cmd("stopinsert"); key("<CR>")
end
local function integration()
	return await(function(cb) client.integration("get", "groq", nil, { directory = directory }, cb) end)
end
local function credential_count()
	local total = 0
	for _, connection in ipairs(integration().connections) do if connection.type == "credential" then total = total + 1 end end
	return total
end
local notifications = {}
local old_notify = vim.notify
vim.notify = function(message, level, opts) notifications[#notifications + 1] = tostring(message); old_notify(message, level, opts) end
local function notified(pattern, since)
	for i = since or 1, #notifications do if notifications[i]:find(pattern, 1, true) then return true end end
	return false
end
local function secret(value, trigger)
	-- Inputsecret is exercised directly. This fixture never sees a personal key.
	vim.defer_fn(function() vim.api.nvim_input(value .. "\r") end, 100)
	trigger()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			assert(not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find(value, 1, true), "Secret echoed into a buffer")
		end
	end
end
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } }, lualine = { enabled = false } })
lifecycle.ensure_connected(function() end); wait(state.is_connected, "No connection")
chat.open(); chat.focus()
local function connect(method)
	chat.focus(); palette.trigger("provider.connect")
	search("Neovim disposable auth fixture")
	search(method)
end

connect("Test key")
wait(function() return current_text():find("Region", 1, true) end, "Integration setup form missing")
shot("auth-key-setup"); key("1")
secret("public-key-ui-sentinel", function() key("<C-g>") end)
wait(function() return notified("Connected to Neovim disposable auth fixture") end, "Key connection not confirmed")
assert(credential_count() == 1, "Key did not create one account")

connect("Test code")
wait(function() return current_text():find("awaiting_user", 1, true) end, "No OAuth code screen")
shot("auth-code-pending")
local opened, old_open = nil, vim.ui.open
vim.ui.open = function(url) opened = url end
key("o"); vim.ui.open = old_open
assert(opened == "https://example.invalid/authorize", "Wrong authorization URL")
local count_before = #notifications
secret("public-test-code", function() key("c") end)
wait(function() return notified("Connected to Neovim disposable auth fixture", count_before + 1) end, "OAuth code not completed")
assert(credential_count() == 2)

connect("Test cancel")
wait(function() return current_text():find("polling", 1, true) end, "No cancellable authorization")
shot("auth-cancel-pending"); key("<Esc>")
wait(function() return vim.api.nvim_get_current_win() == chat.get_winid() end, "Auth cancel did not return focus")
assert(credential_count() == 2, "Cancelled auth changed accounts")

connect("Test expired")
wait(function() return current_text():find("expired", 1, true) end, "Expired auth not shown")
shot("auth-expired"); key("<Esc>")

-- Account management traverses the actual searchable menus and confirmation UI.
chat.focus(); palette.trigger("provider.disconnect")
wait(function() return screen_text():find("public", 1, true) == nil and vim.bo.filetype == "opencode_float" end, "Connections unavailable")
shot("auth-connections")
local before = integration()
local target
for _, connection in ipairs(before.connections) do if connection.type == "credential" then target = connection; break end end
assert(target)
search(target.label)
search("Activate")
wait(function() return notified("Account updated") end, "Account activation not confirmed")
palette.trigger("provider.disconnect"); search(target.label)
vim.defer_fn(function() vim.api.nvim_input("1\r") end, 100)
search("Disconnect")
-- vim.ui.select uses Neovim's native numbered confirmation prompt in this profile.
-- The selection is injected through its normal input API, not by calling an action.
wait(function() return notified("Account disconnected") end, "Account removal not confirmed")
local after = integration()
assert(credential_count() == 1, "Wrong account count after removal")
local env_preserved = false
for _, connection in ipairs(after.connections) do
	assert(connection.id ~= target.id, "Removed account survived")
	if connection.type == "env" then env_preserved = true end
end
assert(env_preserved, "Environment connection was removed")
chat.focus(); palette.trigger("provider.disconnect")
wait(function() return vim.bo.filetype == "opencode_float" end, "Final connections menu missing")
shot("auth-remaining-account"); vim.cmd("stopinsert"); key("<Esc>")
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", key_ui = true, oauth_code_ui = true,
	authorization_url_dispatch = true, personal_browser_opened = false, expired_ui = true,
	accounts_before_delete = before, accounts_after_delete = after, activation_ui = true, deletion_ui = true,
	secret_not_in_buffers = true, notifications = notifications }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Native auth UI passed")
