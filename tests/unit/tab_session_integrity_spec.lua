local state, sync = require("opencode.state"), require("opencode.sync")
local sessions, util = require("opencode.session"), require("opencode.events.util")
local bus = require("opencode.events.bus")
local client, pending = require("opencode.client"), require("opencode.session.pending")
local permissions, forms = require("opencode.permission.state"), require("opencode.question.state")
local edits = require("opencode.edit.state")

describe("tab session integrity", function()
	local saved, notices
	local function seed(id, parent, runtime)
		state.upsert_session({ id = id, title = id, parentID = parent, directory = "/project" }, { touch = runtime ~= false })
	end
	local function form(id, sid)
		return { id = id, sessionID = sid, title = "Continue?", fields = { { key = "ok", type = "boolean", required = true } } }
	end
	before_each(function()
		bus.clear(); pending.clear_all(); state.reset(); sync.clear_all()
		permissions.clear_all(); forms.clear_all(); edits.clear_all()
		saved, notices = { notify = vim.notify, client = {} }, {}
		for _, name in ipairs({ "list_permissions", "list_questions", "review_rpc", "get_session_statuses" }) do saved.client[name] = client[name] end
		vim.notify = function(message, level) notices[#notices + 1] = { message = message, level = level } end
		state.set_config({ session = { parallel = { recent_limit = 2 } } })
	end)
	after_each(function()
		bus.clear(); pending.clear_all()
		permissions.clear_all(); forms.clear_all(); edits.clear_all(); state.reset(); sync.clear_all()
		for name, method in pairs(saved.client) do client[name] = method end
		vim.notify = saved.notify
	end)

	it("finds the nearest native runtime ancestor without widening direct-child rendering", function()
		seed("root"); seed("child", "root", false); seed("grandchild", "child", false)
		assert.equals("root", util.runtime_root_for_session("grandchild"))
		assert.equals("root", util.render_target_session_id("root", "child"))
		assert.is_nil(util.render_target_session_id("root", "grandchild"))
		assert.is_false(util.permission_session_is_relevant("root", "grandchild"))
		seed("child", "root")
		assert.equals("child", util.runtime_root_for_session("grandchild"))
		state.close_runtime_session("child")
		assert.equals("root", util.runtime_root_for_session("grandchild"))
		state.close_runtime_session("root")
		assert.is_nil(util.runtime_root_for_session("grandchild"))
	end)

	it("prefers task-parent links, handles mixed ancestry and terminates cycles", function()
		seed("root"); seed("other"); seed("child", "root", false); seed("grandchild", "other", false)
		sync.record_task_child_session("child", "child-message", "task", "grandchild")
		assert.equals("root", util.runtime_root_for_session("grandchild"))
		seed("cycle-a", "cycle-b", false); seed("cycle-b", "cycle-a", false)
		assert.is_nil(util.runtime_root_for_session("cycle-a"))
		sync.record_task_child_session("cycle-b", "cycle-message-b", "task-b", "cycle-a")
		sync.record_task_child_session("cycle-a", "cycle-message-a", "task-a", "cycle-b")
		assert.is_nil(util.runtime_root_for_session("cycle-a"))
	end)

	it("keeps the pre-index task metadata fallback", function()
		seed("root")
		sync.handle_part_updated({ id = "task", messageID = "message", type = "tool", tool = "task", metadata = { sessionId = "child" } })
		sync.handle_message_updated({ id = "message", sessionID = "root", role = "assistant" })
		assert.is_nil(sync.get_task_parent_session("child"))
		assert.equals("root", util.runtime_root_for_session("child"))
	end)

	it("recovers grandchild interactions and reviews, and rolls their pending counts up to the root", function()
		seed("root"); seed("child", nil, false); seed("grandchild", nil, false)
		seed("unrelated"); state.set_session("unrelated", "Unrelated")
		sync.record_task_child_session("root", "root-message", "root-task", "child")
		sync.record_task_child_session("child", "child-message", "child-task", "grandchild")
		local recovered = { permissions = {}, forms = {}, reviews = {} }
		client.list_permissions = function(opts, callback)
			recovered.permissions[opts.session_id] = true
			callback(nil, opts.session_id == "grandchild" and { { id = "permission", sessionID = "grandchild", action = "shell" } } or {})
		end
		client.list_questions = function(opts, callback)
			recovered.forms[opts.session_id] = true
			callback(nil, opts.session_id == "grandchild" and { form("form", "grandchild") } or {})
		end
		client.review_rpc = function(method, params, _, callback)
			if method == "capabilities" then callback(nil, { protocolVersion = 2, review = true })
			elseif method == "policyList" then callback(nil, {})
			elseif method == "reviewList" then
				recovered.reviews[params.sessionID] = true
				callback(nil, { reviews = params.sessionID == "grandchild" and { {
					protocolVersion = 2, reviewID = "review", revision = 1, sessionID = "grandchild", status = "pending", created = 1000,
					location = { directory = "/project" }, files = { { fileID = "file", filePath = "/project/file", before = "", after = "new" } },
				} } or {} })
			end
		end
		require("opencode.events.handlers.interactions").setup(bus)
		require("opencode.events.handlers.review").setup(bus)
		bus.emit("connected")
		assert.is_true(recovered.permissions.grandchild)
		assert.is_true(recovered.forms.grandchild)
		assert.is_true(recovered.reviews.grandchild)
		assert.is_not_nil(permissions.get_permission("permission"))
		assert.is_not_nil(forms.get_question("form"))
		assert.is_not_nil(edits.get_edit("review"))
		bus.emit("server_interaction", { type = "form.created", data = { form = form("live-form", "grandchild") } })
		sessions.recount_pending()
		assert.same({ permissions = 1, questions = 2, edits = 1 }, state.get_session_pending_counts("root"))
		assert.same({ permissions = 0, questions = 0, edits = 0 }, state.get_session_pending_counts("unrelated"))
		assert.same({}, notices)
	end)

	it("refreshes nested task status through the same runtime ancestor resolution", function()
		seed("root"); seed("child", nil, false); seed("grandchild", nil, false)
		sync.record_task_child_session("root", "root-message", "root-task", "child")
		sync.record_task_child_session("child", "child-message", "child-task", "grandchild")
		client.get_session_statuses = function(callback) callback(nil, { grandchild = { type = "busy" } }) end
		sessions.refresh_status()
		assert.equals("busy", state.get_session_status("grandchild").type)
	end)

	it("never uses recent history limits to evict live runtime membership", function()
		local expected = {}
		for index = 1, 35 do
			local id = "runtime-" .. index
			expected[#expected + 1] = id
			if index % 2 == 0 then state.set_session(id, id)
			else state.upsert_session({ id = id }, { limit = 1 }) end
		end
		state.set_session("runtime-1", "First")
		assert.same(expected, state.get_runtime_session_order())
		assert.equals(35, #state.get_active_sessions())
		for _, id in ipairs(expected) do assert.is_true(state.is_runtime_session(id)) end
		for _, id in ipairs(expected) do state.close_runtime_session(id) end
		assert.same({}, state.get_runtime_session_order())
		assert.equals(30, #state.get_closed_session_order())
		assert.equals(2, #state.get_full_state().sessions.recent_order)
	end)
end)
