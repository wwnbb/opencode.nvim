-- Runs only inside capture_v2.py's disposable server/profile.
local client = require("opencode.client")
local sync = require("opencode.sync")
local state = require("opencode.state")
local session = require("opencode.session")
local events = require("opencode.events.bus")
local url = assert(vim.env.OPENCODE_V2_SERVER_URL)
local host, port = url:match("^http://([^:]+):(%d+)$")
assert(host and port, "Expected a loopback HTTP URL")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
vim.cmd.cd(vim.fn.fnameescape(directory))

local function await(register)
	local done, result, failure = false
	register(function(err, data) failure, result, done = err, data, true end)
	assert(vim.wait(15000, function() return done end, 10), "HTTP timeout")
	assert(not failure, vim.inspect(failure))
	return result
end

client.setup({ host = host, port = tonumber(port), auth = { username = "opencode", password = "opencode-nvim-test-only" } })
assert(await(client.health).version == "2.0.11")
local providers = await(function(cb) client.get_config_providers(cb, { directory = directory }) end)
local agents = await(function(cb) client.list_agents(cb, { directory = directory }) end)
sync.select_catalog_location(directory)
sync.handle_location_catalog(directory, "providers", providers)
sync.handle_location_catalog(directory, "agents", agents)
state.set_config({ session = { default_agent = "build", default_model = { providerID = provider, modelID = model } } })
require("opencode.events.sse_bridge").setup(events)
require("opencode.events.handlers.v2").setup(events)
-- The send flow uses the facade; keep it on the same bus without initializing
-- unrelated UI/interaction modules before their own migration checks.
package.loaded["opencode.events"] = events
assert(client.connect_events())
assert(vim.wait(5000, client.sse.is_connected, 10), "SSE connection timeout")

local created = await(function(cb)
	client.create_session({ location = { directory = directory }, agent = "build", model = { providerID = provider, id = model } }, cb)
end)
session.remember(created)
session.set_active(created.id, "V2 smoke", { preserve_cache = true })
assert(require("opencode.send").send("Reply with exactly: Neovim v2 works.", { agent = "build", model = { providerID = provider, id = model } }))
assert(vim.wait(90000, function()
	for _, message in ipairs(sync.get_messages(created.id)) do
		if message.type == "idle" and message.outcome == "succeeded" then return true end
	end
	return false
end, 20), "Generation did not complete: " .. vim.inspect(sync.get_messages(created.id)))

local snapshot = await(function(cb) client.get_messages(created.id, {}, cb) end)
local live = {}
local users = 0
for _, message in ipairs(sync.get_messages(created.id)) do
	live[message.id] = vim.deepcopy(sync.get_parts(message.id))
	if message.role == "user" then users = users + 1 end
end
assert(users == 1, "Duplicate user message")
for _, message in ipairs(snapshot) do
	assert(vim.deep_equal(live[message.info.id], message.parts), "Live/history mismatch: " .. message.info.id)
end
local text = ""
for _, message in ipairs(snapshot) do
	if message.info.role == "assistant" then text = text .. sync.get_message_render_parts(message.info.id).content end
end
assert(text:find("Neovim v2 works.", 1, true), text)
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", model = provider .. "/" .. model, user_count = users,
	text = text, live_matches_history = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
await(function(cb) client.delete_session(created.id, cb) end)
client.disconnect_events()
require("opencode.events.handlers.v2").clear()
print("Neovim v2 frontend smoke passed")
