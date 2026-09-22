describe("v2 persistent todo revisions", function()
	local sync = require("opencode.sync")
	after_each(function() sync.clear_all() end)
	it("keeps the newest list across delayed snapshots, duplicates and wrong locations", function()
		local function record(revision, content)
			return { protocolVersion = 1, sessionID = "session", location = { directory = "/project" }, revision = revision,
				todos = { { id = "one", content = content, status = "pending" } } }
		end
		assert.is_true(sync.handle_todo_record(record(3, "new"), "/project"))
		local revision = sync.get_todo_revision("session")
		assert.is_false(sync.handle_todo_record(record(2, "old"), "/project"))
		assert.is_false(sync.handle_todo_record(record(3, "duplicate"), "/project"))
		assert.is_false(sync.handle_todo_record(record(4, "foreign"), "/other"))
		assert.equals(revision, sync.get_todo_revision("session"))
		assert.equals("new", sync.get_todos("session")[1].content)
		local empty = record(4, "unused"); empty.todos = {}
		assert.is_true(sync.handle_todo_record(empty, "/project"))
		assert.same({}, sync.get_todos("session"))
		sync.clear_session("session")
		assert.is_true(sync.handle_todo_record(record(4, "restored"), "/project"))
	end)
end)
