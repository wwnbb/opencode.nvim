-- Keyboard selection, native variant updates without generating on other models.
local app, client = require("opencode"), require("opencode.client")
local state, sync, chat = require("opencode.state"), require("opencode.sync"), require("opencode.ui.chat")
local input, lc = require("opencode.ui.input"), require("opencode.local")
local lifecycle, session = require("opencode.lifecycle"), require("opencode.session")
local selection, pending = require("opencode.session.selection"), require("opencode.session.pending")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 15000, predicate, 20), why) end
local function await(register)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return value
end
local function key(name)
	local map = vim.fn.maparg(name, "n", false, true)
	assert(type(map.callback) == "function", "Missing mapping " .. name); map.callback()
end
local function shot(name)
	vim.wait(60, function() return false end, 10)
	if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw!"); vim.rpcnotify(1, "opencode_screenshot", name) end
end
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } }, lualine = { enabled = false } })
lifecycle.ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "No catalogs")
local info = await(function(cb) client.create_session({ location = { directory = directory }, agent = "build",
	model = { providerID = provider, id = model } }, cb) end)
session.remember(info); session.set_active(info.id, "Selection", { preserve_cache = true }); chat.open(); app.focus_input()
wait(input.is_visible, "No input"); vim.cmd("stopinsert")
local original_agent = lc.agent.current().id
key("<C-a>")
local other_agent = lc.agent.current().id
assert(other_agent ~= original_agent, "Agent cycling did not change selection")
local function send(marker)
	assert(lc.model.current().providerID == provider and lc.model.current().modelID == model, "Generation must only use authorized MiMo")
	vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { "Reply exactly " .. marker .. ". Do not call any tools." })
	key("<C-g>")
	wait(function()
		for _, message in ipairs(sync.get_messages(info.id)) do
			if message.role == "assistant" and message.time.completed then
				for _, part in ipairs(sync.get_parts(message.id)) do if part.type == "text" and part.text:find(marker, 1, true) then return true end end
			end
		end
	end, "No selection response " .. marker, 120000)
end
shot("agent-input"); send("SELECTED_AGENT_READY")
local initial_history = await(function(cb) client.get_all_messages(info.id, cb) end)
local first_assistant
for _, message in ipairs(initial_history) do
	if message.info.role == "assistant" then
		assert(message.info.agent == other_agent and message.info.modelID == model)
		first_assistant = vim.deepcopy(message)
	end
end
assert(first_assistant)
wait(function() return state.get_session_status(info.id).type == "idle" end, "Not idle")

local candidate
for _, p in ipairs(sync.get_providers()) do for _, m in pairs(p.models or {}) do
	if m.variant_order and #m.variant_order >= 2 then candidate = { providerID = p.id, modelID = m.id, name = m.name, variants = m.variant_order }; break end
end if candidate then break end end
assert(candidate, "Native catalog has no model with two variants")
local function pick_model(label, expected)
	chat.focus(); require("opencode.ui.palette").trigger("model.switch")
	wait(function() return vim.bo.filetype == "opencode_float" end, "Model menu did not open")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { label })
	vim.api.nvim_exec_autocmds("TextChangedI", { buffer = vim.api.nvim_get_current_buf() })
	shot("model-palette"); vim.cmd("stopinsert"); key("<CR>")
	wait(function() return lc.model.current().modelID == expected end, "Wrong model from palette")
end
pick_model(sync.get_model(provider, model).name, model) -- establish both input recents through the real palette
pick_model(candidate.name, candidate.modelID)
app.focus_input(); wait(input.is_visible, "No variant input"); vim.cmd("stopinsert")
local variants = {}
for i = 1, 2 do
	key("<C-t>"); local variant = lc.variant.current(); assert(variant, "Variant did not change")
	if i == 2 then assert(variant ~= variants[1].variant) end
	local desired = require("opencode.selectors").send_selection({ session_id = info.id })
	desired.model = assert(require("opencode.protocol.v2.requests").model(desired.model, desired.variant))
	-- Exercise the same selection preparation as send, but never POST a prompt
	-- for a model other than the user's explicitly authorized MiMo Free.
	await(function(cb) selection.prepare(info.id, desired, pending.token(info.id), cb) end)
	local native = await(function(cb) client.get_session(info.id, cb) end)
	assert(native.model.id == candidate.modelID and native.model.variant == variant, vim.inspect(native.model))
	variants[#variants + 1] = { variant = variant, native_model = native.model }
	shot("variant-input-" .. i)
end
assert(#await(function(cb) client.get_all_messages(info.id, cb) end) == #initial_history + 2,
	"Only native model switch service messages should be added")
-- Cycle via input recents back to MiMo, then cycle away/back before committing.
key("<C-t>") -- an unsent variant change must also be cleared on model switch
key("<C-e>"); assert(lc.model.current().modelID == model, "Model cycle did not return to MiMo")
assert(lc.variant.current() == nil, "Variant leaked from another model")
key("<C-e>"); assert(lc.model.current().modelID == candidate.modelID)
key("<C-e>"); assert(lc.model.current().modelID == model)
key("<C-t>"); assert(lc.variant.current() == nil, "MiMo has no catalog variants")
for _ = 1, 5 do if lc.agent.current().id == original_agent then break end key("<C-a>") end
assert(lc.agent.current().id == original_agent)
shot("mimo-input-restored"); send("ORIGINAL_AGENT_READY")
local history = await(function(cb) client.get_all_messages(info.id, cb) end)
local old_unchanged, last_agent = false, nil
for _, message in ipairs(history) do
	if message.info.id == first_assistant.info.id then old_unchanged = vim.deep_equal(message, first_assistant) end
	if message.info.role == "assistant" then
		assert(message.info.modelID == model and message.info.providerID == provider, "Unauthorized model generation")
		last_agent = message.info.agent
	end
end
assert(old_unchanged and last_agent == original_agent, "Historical/current selection mismatch")
chat.focus(); chat.do_render(); shot("selection-history")
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", original_agent = original_agent, other_agent = other_agent,
	variant_model = candidate, variants = variants, history = history, keyboard_cycles = true,
	variant_generation = false, historical_selection_preserved = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Agent/model/variant keyboard selection and native selection passed; generation only used MiMo Free")
