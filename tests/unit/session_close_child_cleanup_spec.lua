describe("opencode session close child cleanup", function()

	local function seed_task_child(sync, parent_session_id, child_session_id)
		local message_id = parent_session_id .. "-msg"
		sync.handle_message_updated({
			id = message_id,
			sessionID = parent_session_id,
			role = "assistant",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = parent_session_id .. "-task",
			messageID = message_id,
			sessionID = parent_session_id,
			type = "tool",
			tool = "task",
			state = {
				status = "completed",
				metadata = { sessionId = child_session_id },
			},
		})
		assert(
			sync.get_task_child_session(message_id, parent_session_id .. "-task") == child_session_id,
			"task child index should be recorded"
		)
	end

	local function seed_message(sync, session_id, message_suffix, created)
		sync.handle_message_updated({
			id = session_id .. "-" .. message_suffix,
			sessionID = session_id,
			role = "assistant",
			time = { created = created or 2 },
		})
	end

	it("collect_session_tree walks nested child sessions root-first", function()
		local sync = require("opencode.sync")
		sync.clear_all()

		seed_task_child(sync, "tree-root", "tree-child")
		seed_task_child(sync, "tree-child", "tree-grandchild")

		local ids = sync.collect_session_tree("tree-root")
		assert.equals(3, #ids, "session tree should include nested descendants")
		assert.equals("tree-root", ids[1], "root should come first")
		assert.equals("tree-child", ids[2], "direct child should follow the root")
		assert.equals("tree-grandchild", ids[3], "grandchild should follow its parent")

		assert.equals(1, #sync.collect_session_tree("tree-unknown"), "unknown ids should yield only themselves")
		assert.equals(0, #sync.collect_session_tree(nil), "nil ids should yield an empty tree")

		sync.clear_all()
	end)

	it("invalidates in-flight operations for the complete closed tree", function()
		local state, sync = require("opencode.state"), require("opencode.sync")
		local sessions, pending = require("opencode.session"), require("opencode.session.pending")
		local actions, client = require("opencode.actions"), require("opencode.client")
		local bus, handler = require("opencode.events.bus"), require("opencode.events.handlers.server")
		local lifecycle = require("opencode.lifecycle")
		local old_ensure, old_messages = lifecycle.ensure_connected, client.get_messages
		state.reset(); sync.clear_all(); pending.clear_all(); bus.clear(); handler.clear()
		local history, published = nil, 0
		lifecycle.ensure_connected = function(callback) callback() end
		client.get_messages = function(_, _, callback) history = callback end
		local ok, err = pcall(function()
			require("tests.helpers.schedule").with(function(flush)
				handler.setup(bus)
				sessions.set_active("close-tree", "Parent")
				sessions.set_active("keep-tree", "Neighbor")
				seed_task_child(sync, "close-tree", "close-tree-child")
				seed_task_child(sync, "close-tree-child", "close-tree-grandchild")
				seed_message(sync, "keep-tree", "seed", 3)
				local tokens = {}
				for _, id in ipairs({ "close-tree", "close-tree-child", "close-tree-grandchild", "keep-tree" }) do
					tokens[id] = pending.token(id)
					pending.begin({ session_id = id, message_id = "prompt-" .. id, status = "submitting" })
				end
				actions.load_session_messages("close-tree-grandchild", function() published = published + 1 end)
				assert.is_function(history)
				assert.is_true(sessions.close("close-tree", { silent = true }))
				history(nil, { { info = { id = "late-message", sessionID = "close-tree-grandchild", role = "user" }, parts = {} } })
				flush()
				assert.equals(0, published)
				assert.same({}, sync.get_messages("close-tree-grandchild"))
				assert.same({}, sync.get_messages("close-tree"))
				assert.same({}, sync.get_messages("close-tree-child"))
				assert.equals(1, #sync.get_messages("keep-tree"))
				assert.equals("keep-tree", state.get_session().id)
				assert.is_false(state.is_runtime_session("close-tree"))
				for _, id in ipairs({ "close-tree", "close-tree-child", "close-tree-grandchild" }) do
					assert.is_false(pending.is_current(tokens[id]))
					assert.same({}, pending.list(id))
				end
				assert.is_true(pending.is_current(tokens["keep-tree"]))
				assert.equals("submitting", pending.get("keep-tree", "prompt-keep-tree").status)
			end)
		end)
		lifecycle.ensure_connected, client.get_messages = old_ensure, old_messages
		bus.clear(); handler.clear(); state.reset(); sync.clear_all(); pending.clear_all()
		assert.is_true(ok, err)
	end)

	it("handle_deleted() clears child session data for a deleted tab", function()
		local state = require("opencode.state")
		local sync = require("opencode.sync")
		local session_actions = require("opencode.session")

		state.reset()
		sync.clear_all()

		session_actions.set_active("del-parent", "Parent", { reason = "test_setup" })
		session_actions.set_active("del-child-tab", "Child Tab", { reason = "test_setup" })
		seed_task_child(sync, "del-child-tab", "del-child-session")
		seed_message(sync, "del-child-session", "seed", 2)
		seed_message(sync, "del-parent", "seed", 3)
		local locks, pending = require("opencode.session.lock"), require("opencode.session.pending")
		local permissions, forms = require("opencode.permission.state"), require("opencode.question.state")
		locks.set("del-child-session", { agent = "explore" })
		locks.set("del-parent", { agent = "build" })
		permissions.add_permission("child-permission", "del-child-session", "read", {})
		forms.add_form({ id = "child-form", sessionID = "del-child-session", fields = { { key = "text", type = "string" } } })
		local child_token = pending.token("del-child-session")

		assert.equals(true, session_actions.handle_deleted("del-child-tab"), "deleting the tab should be handled")

		assert.equals(0, #sync.get_messages("del-child-tab"), "deleted tab data should be cleared")
		assert.equals(0, #sync.get_messages("del-child-session"), "deleted tab child data should be cleared")
		assert.equals(1, #sync.get_messages("del-parent"), "neighbor session data should survive")
		assert.is_false(locks.is_locked("del-child-session"))
		assert.is_true(locks.is_locked("del-parent"))
		assert.is_nil(permissions.get_permission("child-permission"))
		assert.is_nil(forms.get_question("child-form"))
		assert.is_false(pending.is_current(child_token))
		locks.clear_all()

		state.reset()
		sync.clear_all()
	end)

	it("clear_session_data clears the session tree from sync", function()
		local sync = require("opencode.sync")
		local actions = require("opencode.actions")

		sync.clear_all()

		seed_task_child(sync, "act-parent", "act-child")
		seed_message(sync, "act-parent", "seed", 1)
		seed_message(sync, "act-child", "seed", 2)

		actions.clear_session_data("act-parent")

		assert.equals(0, #sync.get_messages("act-parent"), "parent data should be cleared")
		assert.equals(0, #sync.get_messages("act-child"), "child data should be cleared")

		sync.clear_all()
	end)
end)
