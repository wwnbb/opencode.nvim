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

bus.clear()
bus.clear_history()
require("opencode.events.state_bridge").setup(bus)
local changes_sync_count = 0
bus.on("sync_changed", function(data)
	if type(data) == "table" and data.kind == "changes" and data.action == "updated" then
		changes_sync_count = changes_sync_count + 1
	end
end)
state.add_pending_change("bridge_state_change.lua", {
	original = "",
	modified = "changed",
	additions = 1,
	deletions = 0,
})
assert_eq(changes_sync_count, 1, "pending file changes should request sync_changed changes update")
state.clear_all_pending_changes()
bus.clear()
bus.clear_history()

local original_notify = vim.notify
local notifications = {}
vim.notify = function(message, level)
	table.insert(notifications, { message = tostring(message), level = level })
end

require("opencode.events.handlers.notifications").setup(bus)
bus.emit("error", { message = "sse boom" })
wait_for(function()
	for _, item in ipairs(notifications) do
		if item.message:find("OpenCode event stream error: sse boom", 1, true) then
			return true
		end
	end
	return false
end, "SSE errors should surface through vim.notify")
bus.clear()
bus.clear_history()

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
assert_eq(selectors.current_model().providerID, "p2", "selectors should expose local provider selection")
assert_eq(selectors.current_model().modelID, "m2", "selectors should expose local model selection")
assert_eq(selectors.current_agent().name, "Plan", "selectors should expose local agent selection")

bus.clear()
bus.clear_history()
local client = require("opencode.client")
local original_get_config_providers = client.get_config_providers
local original_list_agents = client.list_agents
local original_get_config = client.get_config
local original_list_skills = client.list_skills
local original_get_mcp_status = client.get_mcp_status

local function setup_initial_sync_capture()
	local loaded = {
		providers = 0,
		agents = 0,
		config = 0,
		skills = 0,
	}
	local sync_changed = {}
	require("opencode.events.handlers.sync_data").setup(bus)
	bus.on("providers_loaded", function()
		loaded.providers = loaded.providers + 1
	end)
	bus.on("agents_loaded", function()
		loaded.agents = loaded.agents + 1
	end)
	bus.on("config_loaded", function()
		loaded.config = loaded.config + 1
	end)
	bus.on("skills_loaded", function()
		loaded.skills = loaded.skills + 1
	end)
	bus.on("sync_changed", function(data)
		if type(data) == "table" and data.action == "loaded" then
			sync_changed[data.kind] = (sync_changed[data.kind] or 0) + 1
		end
	end)
	return loaded, sync_changed
end

sync.clear_all()
client.get_config_providers = function(callback)
	callback(nil, {
		providers = {
			{ id = "sync-provider", name = "Sync Provider", models = { ["sync-model"] = { name = "Sync Model" } } },
		},
		default = { ["sync-provider"] = "sync-model" },
	})
end
client.list_agents = function(callback)
	callback(nil, { { id = "sync-agent", name = "Sync Agent" } })
end
client.get_config = function(callback)
	callback(nil, {
		model = "sync-model",
		default_agent = "Sync Agent",
		command = { sync_command = { template = "echo sync" } },
	})
end
client.list_skills = function(callback)
	callback(nil, { { name = "sync-skill" } })
end
client.get_mcp_status = function(callback)
	callback(nil, { servers = { sync = { status = "connected" } } })
end
local loaded, sync_changed = setup_initial_sync_capture()
bus.emit("connected")
wait_for(function()
	return loaded.providers == 1
		and loaded.agents == 1
		and loaded.config == 1
		and loaded.skills == 1
		and sync_changed.providers == 1
		and sync_changed.agents == 1
		and sync_changed.config == 1
		and sync_changed.skills == 1
		and sync_changed.mcp == 1
end, "initial sync success should emit all loaded and sync_changed events")
assert_eq(sync.get_providers()[1].id, "sync-provider", "initial sync should store providers")
assert_eq(sync.get_provider_defaults()["sync-provider"], "sync-model", "initial sync should store provider defaults")
assert_eq(sync.get_agents()[1].name, "Sync Agent", "initial sync should store agents")
assert_eq(sync.get_config().model, "sync-model", "initial sync should store config")
assert_true(sync.get_commands().sync_command ~= nil, "initial sync should store commands")
assert_eq(sync.get_skills()[1].name, "sync-skill", "initial sync should store skills")
assert_eq(sync.get_mcp().servers.sync.status, "connected", "initial sync should store MCP status")

bus.clear()
bus.clear_history()
sync.clear_all()
local local_notices = {}
local notification_baseline = #notifications
client.get_config_providers = function(callback)
	callback({ message = "providers failed" })
end
client.list_agents = function(callback)
	callback(nil, { { id = "agent-after-failure", name = "Agent After Failure" } })
end
client.get_config = function(callback)
	callback(nil, { command = { failure_command = { template = "echo still runs" } } })
end
client.list_skills = function(callback)
	callback(nil, { { name = "skill-after-failure" } })
end
client.get_mcp_status = function(callback)
	callback({ message = "mcp failed quietly" })
end
loaded, sync_changed = setup_initial_sync_capture()
bus.on("local_notice", function(data)
	table.insert(local_notices, data)
end)
bus.emit("connected")
wait_for(function()
	return #local_notices > 0
		and #notifications == notification_baseline + 1
		and loaded.agents == 1
		and loaded.config == 1
		and loaded.skills == 1
		and sync_changed.agents == 1
		and sync_changed.config == 1
		and sync_changed.skills == 1
end, "one initial sync failure should not prevent other fetches")
assert_true(
	local_notices[1].content:find("Failed to fetch config providers: providers failed", 1, true) ~= nil,
	"initial sync local notice should include the failing fetch"
)
assert_eq(loaded.providers, 0, "failed providers fetch should not emit providers_loaded")
assert_eq(sync.get_agents()[1].name, "Agent After Failure", "agents should still load after provider failure")
assert_true(sync.get_commands().failure_command ~= nil, "config commands should still load after provider failure")
assert_eq(sync.get_skills()[1].name, "skill-after-failure", "skills should still load after provider failure")
for index = notification_baseline + 1, #notifications do
	assert_true(
		notifications[index].message:find("mcp failed quietly", 1, true) == nil,
		"MCP initial sync errors should remain quiet"
	)
end
client.get_config_providers = original_get_config_providers
client.list_agents = original_list_agents
client.get_config = original_get_config
client.list_skills = original_list_skills
client.get_mcp_status = original_get_mcp_status
vim.notify = original_notify
sync.handle_providers({
	{ id = "p1", name = "Provider 1", models = { m1 = { name = "Model 1" } } },
	{ id = "p2", name = "Provider 2", models = { m2 = { name = "Model 2" } } },
})
sync.handle_agents({
	{ id = "code", name = "Code" },
	{ id = "plan", name = "Plan" },
})

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

bus.emit("permission", {
	id = "perm_missing_session",
	permission = "bash",
	time = { created = 0 },
})
vim.wait(50)
assert_true(
	not permission_state.has_permission("perm_missing_session"),
	"permission without session or message identity should be dropped"
)

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
	id = "danger_missing_session",
	permission = "bash",
})
vim.wait(50)
assert_eq(#replies, 0, "danger mode should not auto-reply to permission without session identity")
assert_true(
	not permission_state.has_permission("danger_missing_session"),
	"danger mode should drop permission without session identity"
)

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

bus.clear()
bus.clear_history()
sync.clear_all()
state.reset()
permission_state.clear_all()
question_state.clear_all()
edit_state.clear_all()
local cleanup_chat = require("opencode.ui.chat")
local cleanup_chat_state = require("opencode.ui.chat.state").state
local danger = require("opencode.permission.danger")
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
sync.handle_message_updated({
	id = "cleanup_message",
	sessionID = "cleanup_session",
	role = "assistant",
	time = { created = 1 },
})
permission_state.add_permission("cleanup_perm", "cleanup_session", "bash", {})
question_state.add_question("cleanup_question", "cleanup_session", {
	{ prompt = "Cleanup?", options = { { label = "Yes", value = "yes" } } },
})
edit_state.add_edit("cleanup_edit", "cleanup_session", {
	{ filePath = "cleanup.lua", before = "a", after = "b" },
}, { review_mode = "readonly" })
cleanup_chat.add_message("system", "cleanup notice", { render = false })
local replies_before_cleanup = #replies
danger.approve("cleanup_danger")
assert_eq(#replies, replies_before_cleanup + 1, "danger approval should queue before cleanup")
require("opencode.cleanup").reset_all()
assert_eq(#sync.get_messages("cleanup_session"), 0, "cleanup should clear sync messages")
assert_true(not permission_state.has_permission("cleanup_perm"), "cleanup should clear permissions")
assert_true(not question_state.has_question("cleanup_question"), "cleanup should clear questions")
assert_eq(edit_state.get_edit("cleanup_edit"), nil, "cleanup should clear edits")
assert_eq(#cleanup_chat_state.local_notices, 0, "cleanup should clear chat local notices")
danger.approve("cleanup_danger")
assert_eq(#replies, replies_before_cleanup + 2, "cleanup should clear danger reply dedupe")
client.respond_permission = original_respond_permission

local file_edit_results = require("opencode.ui.chat.file_edit_results")
local long_title = "Patch applied " .. string.rep("with wrapped summary ", 8)
local rendered_file_result = file_edit_results.render_tool({
	tool = "apply_patch",
	state = {
		status = "completed",
		metadata = {
			title = long_title,
			files = {
				{
					filePath = "lua/opencode/some/really/long/path/for/render_check.lua",
					type = "update",
					status = "applied",
					additions = 3,
					deletions = 2,
				},
			},
		},
	},
}, false)
assert_true(rendered_file_result ~= nil, "file edit result should render")
assert_true(#rendered_file_result.lines > 1, "file edit result should wrap long panel text")
for _, line_text in ipairs(rendered_file_result.lines) do
	assert_eq(line_text:sub(1, #"▏  "), "▏  ", "file edit result lines should use panel prefix")
end
local has_diff_add = false
local has_diff_delete = false
for _, hl in ipairs(rendered_file_result.highlights) do
	has_diff_add = has_diff_add or hl.hl_group == "DiffAdd"
	has_diff_delete = has_diff_delete or hl.hl_group == "DiffDelete"
end
assert_true(has_diff_add, "file edit result should highlight additions")
assert_true(has_diff_delete, "file edit result should highlight deletions")

print("State ownership checks passed")
