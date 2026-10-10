describe("child navigation freshness", function()
	local nav = require("opencode.ui.chat.nav")
	local actions = require("opencode.actions")
	local state = require("opencode.state")
	local view = require("opencode.ui.chat.state").state
	local pending = require("opencode.session.pending")
	local lock = require("opencode.session.lock")
	local saved, replies
	local function complete(index, child_id)
		replies[index](nil, { id = child_id or "child", title = "Child", agent = "explore", model = { providerID = "test", id = "model" } })
	end
	before_each(function()
		state.reset(); pending.clear_all(); lock.clear_all(); require("opencode.sync").clear_all()
		state.set_session("parent", "Parent")
		saved = { get = actions.get_session, load = actions.load_session_messages, tasks = view.tasks, stack = view.session_stack }
		replies = {}
		actions.get_session = function(_, callback) replies[#replies + 1] = callback end
		actions.load_session_messages = function(_, _, callback) callback(nil, {}) end
		view.tasks = { task = { tool_part = { id = "task", messageID = "m", sessionID = "parent", type = "tool", tool = "task",
			state = { input = {}, metadata = { sessionID = "child" } } } } }
		view.session_stack = {}
	end)
	after_each(function()
		actions.get_session, actions.load_session_messages = saved.get, saved.load
		view.tasks, view.session_stack = saved.tasks, saved.stack
		state.reset(); pending.clear_all(); lock.clear_all(); require("opencode.sync").clear_all()
	end)

	it("ignores a child load after switching to another tab", function()
		nav.enter_child_session("task")
		state.set_session("other", "Other")
		complete(1)
		assert.equals("other", state.get_session().id)
		assert.equals(0, #view.session_stack)
		assert.is_nil(lock.get("child"))
	end)

	it("ignores a child load from a previous connection", function()
		local history
		actions.load_session_messages = function(_, _, callback) history = callback end
		nav.enter_child_session("task")
		complete(1)
		pending.invalidate()
		history(nil, {})
		assert.equals("parent", state.get_session().id)
		assert.equals(0, #view.session_stack)
	end)

	it("ignores a child deleted while its metadata was loading", function()
		nav.enter_child_session("task")
		pending.clear_session("child")
		complete(1)
		assert.equals("parent", state.get_session().id)
		assert.is_nil(lock.get("child"))
	end)

	it("enters once when repeated requests finish out of order", function()
		nav.enter_child_session("task")
		nav.enter_child_session("task")
		complete(2)
		complete(1)
		assert.equals("child", state.get_session().id)
		assert.equals(1, #view.session_stack)
		assert.equals("parent", view.session_stack[1].id)
		nav.leave_child_session()
		assert.equals("parent", state.get_session().id)
	end)

	it("honors the latest selected child even when the first request finishes first", function()
		view.tasks.second = vim.deepcopy(view.tasks.task)
		view.tasks.second.tool_part.id = "second"
		view.tasks.second.tool_part.state.metadata.sessionID = "second-child"
		nav.enter_child_session("task")
		nav.enter_child_session("second")
		complete(1)
		assert.equals("parent", state.get_session().id)
		complete(2, "second-child")
		assert.equals("second-child", state.get_session().id)
		assert.equals(1, #view.session_stack)
	end)

	it("does not reopen a closed parent from a stale back stack", function()
		state.set_session("other", "Other")
		state.set_session("parent", "Parent")
		local sync = require("opencode.sync")
		sync.record_task_child_session("parent", "m", "task", "child")
		nav.enter_child_session("task")
		complete(1)
		assert.is_true(require("opencode.session").close("parent", { silent = true }))
		assert.equals("other", state.get_session().id)
		nav.leave_child_session()
		assert.equals("other", state.get_session().id)
		assert.is_false(state.is_runtime_session("parent"))
	end)

	it("skips a deleted intermediate parent when returning to the root", function()
		nav.enter_child_session("task")
		complete(1)
		view.session_stack[#view.session_stack + 1] = { id = "child", name = "Child", runtime = false }
		state.set_session("grandchild", "Grandchild", { runtime = false })
		state.remove_session("child")
		nav.leave_child_session()
		assert.equals("parent", state.get_session().id)
		assert.is_nil(state.get_session_record("child"))
		assert.equals(0, #view.session_stack)
	end)

	it("returns by native parentID from a child opened by ID without adding intermediate tabs", function()
		state.upsert_session({ id = "grandchild", parentID = "middle" }, { touch = false })
		state.set_session("grandchild", "Grandchild", { runtime = false })
		nav.leave_child_session()
		replies[1](nil, { id = "middle", parentID = "parent", title = "Middle", agent = "explore",
			model = { providerID = "test", id = "model" } })
		assert.equals("middle", state.get_session().id)
		assert.same({ "parent" }, state.get_runtime_session_order())
		assert.is_true(lock.is_locked("middle"))
		nav.leave_child_session()
		replies[2](nil, { id = "parent", title = "Parent", agent = "build", model = { providerID = "test", id = "model" } })
		assert.equals("parent", state.get_session().id)
		assert.same({ "parent" }, state.get_runtime_session_order())
		assert.is_false(lock.is_locked("parent"))
	end)

	it("ignores a native parent response after switching away from the child", function()
		state.upsert_session({ id = "child", parentID = "parent" }, { touch = false })
		state.set_session("child", "Child", { runtime = false })
		nav.leave_child_session()
		state.set_session("other", "Other")
		replies[1](nil, { id = "parent", title = "Parent", agent = "build", model = { providerID = "test", id = "model" } })
		assert.equals("other", state.get_session().id)
	end)

	it("leaves the child view intact when its native parent no longer exists", function()
		state.upsert_session({ id = "child", parentID = "missing" }, { touch = false })
		state.set_session("child", "Child", { runtime = false })
		nav.leave_child_session()
		replies[1]({ message = "Session not found" })
		assert.equals("child", state.get_session().id)
	end)
end)
