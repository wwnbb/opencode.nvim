local cs = require("opencode.ui.chat.state")
local app, sync = require("opencode.state"), require("opencode.sync")
local actions = require("opencode.actions")
local locks = require("opencode.session.lock")

describe("tab child model metadata fallbacks", function()
	local view, saved
	local model = { providerID = "provider", modelID = "model" }
	before_each(function()
		app.reset(); sync.clear_all(); locks.clear_all()
		require("opencode.session.pending").clear_all()
		app.set_session("model-parent", "Parent")
		view = cs.new()
		view.session_id = "model-parent"
		saved = { get = actions.get_session, load = actions.load_session_messages, bind = actions.set_view_session,
			render = require("opencode.ui.chat.render_coordinator").request }
		actions.get_session = function(_, callback) callback(nil, { id = "model-child", parentID = "model-parent" }) end
		actions.load_session_messages = function(_, _, callback) callback(nil, {}) end
		actions.set_view_session = function(owner, id) owner.session_id = id; return true end
		require("opencode.ui.chat.render_coordinator").request = function() end
	end)
	after_each(function()
		vim.wait(10, function() return false end, 1)
		actions.get_session, actions.load_session_messages, actions.set_view_session = saved.get, saved.load, saved.bind
		require("opencode.ui.chat.render_coordinator").request = saved.render
		cs.remove(view)
		app.reset(); sync.clear_all(); locks.clear_all()
		require("opencode.session.pending").clear_all()
	end)

	for _, source in ipairs({ "metadata.model", "state metadata", "flat metadata", "input.model" }) do
		it("uses " .. source .. " with no earlier model or child history", function()
			local part = { id = "model-task", type = "tool", tool = "task", sessionID = "model-parent",
				state = { metadata = { sessionID = "model-child" }, input = { subagent_type = "explore", variant = "fast" } } }
			if source == "metadata.model" then part.metadata = { model = model }
			elseif source == "state metadata" then part.state.metadata = vim.tbl_extend("force", part.state.metadata, model)
			elseif source == "flat metadata" then part.metadata = model
			else part.state.input.model = model end
			view.tasks.task = { tool_part = part }
			cs.module(view, require("opencode.ui.chat.nav")).enter_child_session("task")
			local lock = locks.get("model-child")
			assert.is_not_nil(lock)
			assert.same(model, lock.model)
			assert.is_not.equals(true, lock.pending, "resolved metadata must not block child sends")
			assert.equals("fast", lock.variant)
			assert.equals("explore", lock.agent)
			assert.equals("model-child", cs.session(view).id)
		end)
	end

	for _, source in ipairs({ "assistant history", "user history", "child.model", "flat child" }) do
		it("uses " .. source .. " when task metadata has no model", function()
			local child = { id = "model-child", parentID = "model-parent", agent = "explore", variant = "fallback" }
			local messages = {}
			if source == "child.model" then child.model = model
			elseif source == "flat child" then child = vim.tbl_extend("force", child, model)
			else messages = { { info = { role = source == "assistant history" and "assistant" or "user", model = model } } } end
			actions.get_session = function(_, callback) callback(nil, child) end
			actions.load_session_messages = function(_, _, callback) callback(nil, messages) end
			view.tasks.task = { tool_part = { id = "model-task", type = "tool", tool = "task", sessionID = "model-parent",
				state = { metadata = { sessionID = "model-child" }, input = {} } } }
			cs.module(view, require("opencode.ui.chat.nav")).enter_child_session("task")
			local lock = locks.get("model-child")
			assert.is_not_nil(lock)
			assert.same(model, lock.model)
			assert.is_not.equals(true, lock.pending)
			if source == "child.model" then assert.is_nil(lock.variant) else assert.equals("fallback", lock.variant) end
			assert.equals("model-child", cs.session(view).id)
		end)
	end

	it("preserves nested metadata precedence and its explicit variant", function()
		local preferred = vim.tbl_extend("force", model, { variant = "preferred" })
		view.tasks.task = { tool_part = { id = "model-task", type = "tool", tool = "task", sessionID = "model-parent",
			metadata = { model = { providerID = "other", modelID = "other" }, variant = "fallback" },
			state = { metadata = { sessionID = "model-child", model = preferred }, input = { subagent_type = "explore" } } } }
		cs.module(view, require("opencode.ui.chat.nav")).enter_child_session("task")
		assert.same(model, locks.get("model-child").model)
		assert.equals("preferred", locks.get("model-child").variant)
	end)
end)
