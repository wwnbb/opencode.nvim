-- Full frontend setup and real Nui buffers, using only capture_v2.py's server.
local opencode = require("opencode")
local state = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local client = require("opencode.client")
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
vim.cmd.cd(vim.fn.fnameescape(directory))
vim.o.columns, vim.o.lines = 120, 36
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 15000, predicate, 20), why) end
local function text() return table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n") end
opencode.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	auth = { username = "opencode", password = "opencode-nvim-test-only" }, config_dir = vim.env.OPENCODE_CONFIG_DIR },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } },
	chat = { layout = "vertical", width = 80, close_on_focus_lost = false }, lualine = { enabled = false } })
require("opencode.lifecycle").ensure_connected(function() end)
wait(function() return state.is_connected() and #sync.get_agents() > 0 and sync.get_model(provider, model) ~= nil end, "Frontend catalogs did not load")
require("opencode.actions").select_model({ providerID = provider, modelID = model })
chat.open(); chat.focus()
local map = vim.fn.maparg("N", "n", false, true)
assert(type(map.callback) == "function", "Chat N keymap unavailable")
local previous = state.get_session().id
map.callback()
wait(function() return state.get_session().id and state.get_session().id ~= previous end, "N did not create a new session")
local sid = state.get_session().id
wait(function() return sync.get_catalog_location() == directory and #sync.get_skills() > 0 end, "Native skill catalog did not load")
local slash = require("opencode.slash")
assert(slash.execute(slash.parse("/skill smoke-native")), "Slash skill not handled")
wait(function()
	for _, message in ipairs(sync.get_messages(sid)) do
		if message.type == "idle" and message.outcome == "succeeded" then return true end
	end
	return false
end, "Skill request did not finish", 100000)
wait(function() return text():find("SKILL_V2_READY", 1, true) and text():find("skill smoke-native", 1, true) end, "Skill attachment/response missing from buffer")
local first_text = text()
if vim.env.OPENCODE_V2_ATTACHED_UI then
	vim.cmd("redraw")
	vim.rpcnotify(1, "opencode_screenshot", "skill-chat")
end
local done, failure
client.get_all_messages(sid, function(err, messages)
	failure = err
	if not err then
		local attached = false
		for _, message in ipairs(messages) do
			for _, part in ipairs(message.parts) do if part.type == "skill" and part.name == "smoke-native" then attached = true end end
		end
		assert(attached, "Native skill attachment missing from HTTP history")
	end
	done = true
end)
wait(function() return done end, "History did not load"); assert(not failure, vim.inspect(failure))
assert(state.get_session().id == sid, "Skill selection changed session")
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", model = provider .. "/" .. model, sessionID = sid,
	new_session_keymap = true, native_skill_attachment = true, rendered = first_text }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); require("opencode.lifecycle").disconnect()
print("Neovim new-session/skill UI smoke passed")
