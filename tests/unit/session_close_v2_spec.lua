describe("v2 session close interaction routing", function()
	it("rejects native permissions by owner and reviews through RPC", function()
		local state = require("opencode.state")
		local sync = require("opencode.sync")
		local session = require("opencode.session")
		local permissions = require("opencode.permission.state")
		local edits = require("opencode.edit.state")
		local client = require("opencode.client")
		local respond, rpc = client.respond_permission, client.review_rpc
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
		client.respond_permission, client.review_rpc = respond, rpc
		assert.is_true(ok, err)
		assert.is_true(err)
		assert.equals(1, #permission_calls)
		assert.equals("permission-v2", permission_calls[1].id)
		assert.equals("reject", permission_calls[1].decision)
		assert.equals("close-v2", permission_calls[1].opts.session_id)
		assert.equals(1, #review_calls)
		assert.equals("reviewReply", review_calls[1].method)
		assert.equals("/tmp/close-v2", review_calls[1].directory)
		assert.equals("review-v2", review_calls[1].payload.reviewID)
		assert.same({ { fileID = "file-v2", status = "rejected", apply = "server" } }, review_calls[1].payload.decisions)
		assert.is_nil(edits.get_edit("review-v2"))
		state.reset(); sync.clear_all(); permissions.clear_all(); edits.clear_all()
	end)
end)
