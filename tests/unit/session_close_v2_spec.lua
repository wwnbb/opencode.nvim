describe("v2 session close interaction routing", function()
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
		state.upsert_session({ id = "close-v2", directory = "/tmp/close-v2" }, { touch = false })
		session.set_active("close-v2", "Review", { preserve_cache = true })
		permissions.add_permission("permission-v2", "close-v2", "shell", {})
		edits.add_edit("review-v2", "close-v2", {
			{ fileID = "file-v2", filePath = "/tmp/close-v2/file.txt", before = "before", after = "after", type = "update" },
		}, {
			transport = "review_rpc", review_id = "review-v2", revision = 1,
			location = { directory = "/tmp/close-v2" }, native_review = { status = "pending" },
		})
		client.respond_permission = function(id, decision, opts)
			permission_calls[#permission_calls + 1] = { id = id, decision = decision, opts = opts }
		end
		client.review_rpc = function(method, payload, directory)
			review_calls[#review_calls + 1] = { method = method, payload = payload, directory = directory }
		end
		local ok, err = pcall(session.close, "close-v2", { silent = true })
		assert.is_true(ok, err)
		assert.is_true(err)
		assert.equals(0, #permission_calls)
		assert.equals(0, #review_calls)
		assert.equals("pending", permissions.get_permission("permission-v2").status)
		assert.is_not_nil(edits.get_edit("review-v2"))
		assert.is_false(state.is_runtime_session("close-v2"))

		-- A closed tab may be opened again while these requests still wait on the server.
		client.get_messages = function() end
		session.switch_to({ id = "close-v2", title = "Review", directory = "/tmp/close-v2" })
		assert.is_true(state.is_runtime_session("close-v2"))
		assert.equals("pending", permissions.get_permission("permission-v2").status)
		assert.is_not_nil(edits.get_edit("review-v2"))
		assert.equals(0, #permission_calls)
		assert.equals(0, #review_calls)
		client.respond_permission, client.review_rpc, client.get_messages = respond, rpc, get_messages
		state.reset(); sync.clear_all(); permissions.clear_all(); edits.clear_all()
	end)
end)
