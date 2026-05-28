-- Dynamic state ownership checks.
-- Run with: nvim --headless --clean --cmd "set rtp+=." -l scripts/check-state-ownership.lua

local function stub_module(name, value)
	package.preload[name] = package.preload[name] or function()
		return value
	end
end

local popup = {}
popup.__index = popup
function popup:new(opts)
	return setmetatable({ opts = opts or {}, bufnr = 1, winid = 1 }, self)
end
function popup:mount() end
function popup:unmount() end
function popup:map() end
function popup:on() end
setmetatable(popup, {
	__call = function(_, opts)
		return popup:new(opts)
	end,
})

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
	__call = function()
		return line:new()
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
			start = function() end,
			shutdown = function() end,
			opts = opts or {},
		}
	end,
})

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_true(value, message)
	if not value then
		error(message)
	end
end

local function wait_for(predicate, message)
	local ok = vim.wait(200, predicate, 10)
	assert_true(ok, message)
end

local bus = require("opencode.events.bus")
bus.clear()
bus.clear_history()

package.loaded["opencode.events"] = nil
local permission_state = require("opencode.permission.state")
local question_state = require("opencode.question.state")
local edit_state = require("opencode.edit.state")
require("opencode.local")
assert_eq(package.loaded["opencode.events"], nil, "stores should not load event facade")

permission_state.add_permission("perm_store", "session_a", "bash", {})
permission_state.select_option("perm_store", 2)
question_state.add_question("question_store", "session_a", {
	{ prompt = "Pick", options = { { label = "A", value = "a" } } },
})
question_state.select_option("question_store", 1)
edit_state.add_edit("edit_store", "session_a", {
	{ filePath = "README.md", before = "a", after = "b" },
}, { review_mode = "readonly" })
assert_eq(package.loaded["opencode.events"], nil, "store mutations should not load event facade")
assert_eq(#bus.get_history(), 0, "store mutations should not emit events")

local state = require("opencode.state")
local sync = require("opencode.sync")
local local_state = require("opencode.local")
local selectors = require("opencode.selectors")

sync.clear_all()
sync.handle_providers({
	{ id = "p1", name = "Provider 1", models = { m1 = { name = "Model 1" } } },
	{ id = "p2", name = "Provider 2", models = { m2 = { name = "Model 2" } } },
})
sync.handle_agents({
	{ id = "code", name = "Code" },
	{ id = "plan", name = "Plan" },
})
state.set_config({
	session = {
		default_model = { providerID = "p1", modelID = "m1" },
		default_agent = "Code",
	},
})
local_state.agent.set("Plan")
local_state.model.set({ providerID = "p2", modelID = "m2" })

local selected = selectors.send_selection({
	model = { providerID = "p1", modelID = "m1" },
	agent = "Code",
	variant = "fast",
})
assert_eq(selected.model.providerID, "p1", "opts model provider should win")
assert_eq(selected.model.modelID, "m1", "opts model id should win")
assert_eq(selected.agent, "Code", "opts agent should win")
assert_eq(selected.variant, "fast", "opts variant should win")

local fallback = selectors.send_selection({
	model = { providerID = "missing", modelID = "nope" },
})
assert_eq(fallback.model.providerID, "p2", "invalid opts model should fall back to local provider")
assert_eq(fallback.model.modelID, "m2", "invalid opts model should fall back to local model")
assert_eq(fallback.agent, "Plan", "local agent should be selected")

local logger = require("opencode.logger")
sync.handle_provider_defaults({ p1 = "m1" })
local_state.agent.set("Code")
logger.clear()
local fallback_current = local_state.model.current()
assert_eq(fallback_current.providerID, "p1", "fallback provider default should be selected")
assert_eq(fallback_current.modelID, "m1", "fallback provider default model should be selected")
local first_log_count = logger.count()
local_state.model.current()
assert_eq(logger.count(), first_log_count, "unchanged model selection reads should not append logs")

bus.clear()
bus.clear_history()
state.reset()
local session_actions = require("opencode.session")
session_actions.set_active("session_status", "Status Session", { preserve_cache = true })
session_actions.set_status("idle", { reason = "test", session_id = "session_status" })
require("opencode.events.handlers.message").setup(bus)

bus.emit("message_updated", {
	info = {
		id = "msg_status",
		sessionID = "session_status",
		role = "assistant",
		time = { created = 1 },
	},
})
vim.wait(50)
assert_eq(state.get_status(), "idle", "message update alone should not change global status")

bus.emit("session_status", {
	sessionID = "session_status",
	status = { type = "busy" },
})
wait_for(function()
	return state.get_status() == "streaming"
end, "busy session.status should set streaming")

bus.emit("session_status", {
	sessionID = "session_status",
	status = { type = "idle" },
})
wait_for(function()
	return state.get_status() == "idle"
end, "idle session.status should set idle")

bus.clear()
bus.clear_history()
state.reset()
sync.clear_all()
permission_state.clear_all()
question_state.clear_all()
session_actions.set_active("visible_session", "Visible Session", { preserve_cache = true })
require("opencode.events.handlers.permission").setup(bus)
require("opencode.events.handlers.question").setup(bus)
local spinner = require("opencode.ui.spinner")

spinner.start()
bus.emit("permission", {
	id = "perm_other_session",
	permission = "bash",
	sessionID = "other_session",
	time = { created = 1 },
})
vim.wait(50)
assert_true(spinner.is_active(), "permission in another root session should not stop visible spinner")

bus.emit("permission", {
	id = "perm_visible_session",
	permission = "bash",
	sessionID = "visible_session",
	time = { created = 2 },
})
wait_for(function()
	return not spinner.is_active()
end, "permission in visible session should stop spinner")

spinner.start()
bus.emit("question_asked", {
	requestID = "question_other_session",
	sessionID = "other_session",
	questions = {
		{ prompt = "Pick", options = { { label = "A", value = "a" } } },
	},
	time = { created = 3 },
})
vim.wait(50)
assert_true(spinner.is_active(), "question in another root session should not stop visible spinner")

bus.emit("question_asked", {
	requestID = "question_visible_session",
	sessionID = "visible_session",
	questions = {
		{ prompt = "Pick", options = { { label = "A", value = "a" } } },
	},
	time = { created = 4 },
})
wait_for(function()
	return not spinner.is_active()
end, "question in visible session should stop spinner")

bus.clear()
bus.clear_history()
local render_coordinator = require("opencode.ui.chat.render_coordinator")
render_coordinator.setup(bus)
local render_count = 0
bus.on("chat_render", function()
	render_count = render_count + 1
end)
render_coordinator.request({ session_id = "session_status" })
render_coordinator.request({ reason = "second_request" })
wait_for(function()
	return render_count == 1
end, "render coordinator should coalesce same-tick requests")

bus.clear()
bus.clear_history()
state.reset()
session_actions.set_active("session_hidden", "Hidden Widget", { preserve_cache = true })
question_state.clear_all()
question_state.add_question("hidden_question", "session_hidden", {
	{ question = "Hidden?", options = { { label = "Yes", value = "yes" } } },
})
local chat = require("opencode.ui.chat")
chat.create()
local lines = chat.render()
local rendered = table.concat(lines, "\n")
assert_true(rendered:find("Hidden%?") ~= nil, "hidden question should render from question store")

permission_state.clear_all()
edit_state.clear_all()
permission_state.add_permission("preserve_perm", "session_hidden", "bash", {})
edit_state.add_edit("preserve_edit", "session_hidden", {
	{ filePath = "README.md", before = "a", after = "b" },
}, { review_mode = "readonly" })
require("opencode.events.handlers.permission").setup(bus)
require("opencode.events.handlers.question").setup(bus)
bus.emit("session_change", {
	id = "child",
	previous_id = "session_hidden",
	reason = "child_navigation",
	preserve_cache = true,
})
assert_true(permission_state.has_permission("preserve_perm"), "preserve_cache session_change should keep permissions")
assert_true(edit_state.get_edit("preserve_edit") ~= nil, "preserve_cache session_change should keep edits")
assert_true(question_state.has_question("hidden_question"), "preserve_cache session_change should keep questions")

bus.clear()
bus.clear_history()
permission_state.clear_all()
edit_state.clear_all()
state.set_danger_mode(true)
require("opencode.permission.danger").clear()

local client = require("opencode.client")
local original_respond_permission = client.respond_permission
local replies = {}
client.respond_permission = function(permission_id, reply, opts, callback)
	table.insert(replies, {
		permission_id = permission_id,
		reply = reply,
		opts = opts,
	})
	if callback then
		callback(nil, true)
	end
end

require("opencode.events.handlers.permission").setup(bus)
bus.emit("permission", {
	id = "danger_perm",
	permission = "bash",
	sessionID = "session_hidden",
})
wait_for(function()
	return #replies == 1
end, "danger mode should auto-reply to permission requests")
assert_eq(replies[1].permission_id, "danger_perm", "danger mode reply should target permission")
assert_eq(replies[1].reply, "once", "danger mode should use one-shot approval")
assert_true(not permission_state.has_permission("danger_perm"), "danger mode should skip pending permission widget")

client.respond_permission = original_respond_permission
state.set_danger_mode(false)
require("opencode.permission.danger").clear()

print("State ownership checks passed")
