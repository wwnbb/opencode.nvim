describe("session close interaction routing", function()
	it("keeps native permissions and reviews pending when closing and reopening a tab", function()
		local state = require("opencode.state")
		local sync = require("opencode.sync")
		local session = require("opencode.session")
		local permissions = require("opencode.permission.state")
		local edits = require("opencode.edit.state")
		local client = require("opencode.client")
		local respond, rpc, get_messages = client.respond_permission, client.review_rpc, client.get_messages
		local permission_calls, review_calls = {}, {}
		state.reset(); sync.clear_all(); permissions.clear_all(); edits.clear_all()
		state.set_config({ server = { shared_filesystem = false } })
		state.set_connection("connected")
		state.upsert_session({ id = "close-session", directory = "/tmp/close-session" }, { touch = false })
		session.set_active("close-session", "Review", { preserve_cache = true })
		permissions.add_permission("permission-close", "close-session", "shell", {})
		edits.add_edit("review-close", "close-session", {
			{ fileID = "file-close", filePath = "/tmp/close-session/file.txt", before = "before", after = "after", type = "update" },
		}, {
			transport = "review_rpc", review_id = "review-close", revision = 1,
			location = { directory = "/tmp/close-session" }, native_review = { status = "pending" },
		})
		client.respond_permission = function(id, decision, opts)
			permission_calls[#permission_calls + 1] = { id = id, decision = decision, opts = opts }
		end
		client.review_rpc = function(method, payload, directory)
			review_calls[#review_calls + 1] = { method = method, payload = payload, directory = directory }
		end
		local ok, err = pcall(session.close, "close-session", { silent = true })
		assert.is_true(ok, err)
		assert.is_true(err)
		assert.equals(0, #permission_calls)
		assert.equals(0, #review_calls)
		assert.equals("pending", permissions.get_permission("permission-close").status)
		assert.is_not_nil(edits.get_edit("review-close"))
		assert.is_false(state.is_runtime_session("close-session"))

		-- A closed tab may be opened again while these requests still wait on the server.
		client.get_messages = function() end
		session.switch_to({ id = "close-session", title = "Review", directory = "/tmp/close-session" })
		assert.is_true(state.is_runtime_session("close-session"))
		assert.equals("pending", permissions.get_permission("permission-close").status)
		assert.is_not_nil(edits.get_edit("review-close"))
		assert.equals(0, #permission_calls)
		assert.equals(0, #review_calls)
		client.respond_permission, client.review_rpc, client.get_messages = respond, rpc, get_messages
		state.reset(); sync.clear_all(); permissions.clear_all(); edits.clear_all()
	end)
end)
