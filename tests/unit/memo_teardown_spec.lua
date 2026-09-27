local memo = require("opencode.util.memo")
local render_state = require("opencode.ui.chat.render_state")
local syntax = require("opencode.ui.syntax")
local cleanup = require("opencode.cleanup")

describe("memo owner teardown orchestration", function()
	local signature, highlight, chat
	before_each(function()
		memo.clear_all(); render_state.clear_render_cache(); render_state.clear_code_cache()
		signature, highlight, chat = syntax.cache_signature, syntax.highlight_text, package.loaded["opencode.ui.chat"]
		syntax.cache_signature = function() return "teardown-signature" end
		syntax.highlight_text = function() return {}, "ok" end
	end)
	after_each(function()
		syntax.cache_signature, syntax.highlight_text = signature, highlight
		package.loaded["opencode.ui.chat"] = chat
		memo.clear_all(); render_state.clear_render_cache(); render_state.clear_code_cache()
	end)
	local function populate(sid)
		local owner = render_state.render_cache_key("text", sid, "message", "part")
		render_state.render_cache_put("revision", { result = { lines = { sid } } }, owner)
		render_state.task_summary_cache_put(sid, 1, { text = sid }, "prompt")
		memo.new("activity_leaf"):put(sid .. "\0message\0part", 1, { text = sid })
		memo.new("history_metadata"):put(sid, 1, { text = sid })
		render_state.code_highlighter(sid .. "\0message\0part")("code", "lua", {}, { open_line = 0 })
		return owner
	end
	it("removes only the closing session's retained values", function()
		local gone, kept = populate("gone"), populate("kept")
		assert.equals(2, render_state.code_cache_stats().entries)
		cleanup.clear_session("gone")
		assert.is_nil(render_state.render_cache_get("revision", gone))
		assert.is_not_nil(render_state.render_cache_get("revision", kept))
		assert.is_false(select(3, render_state.task_summary_cache_get("gone", 1)))
		assert.is_true(select(3, render_state.task_summary_cache_get("kept", 1)))
		assert.is_nil(memo.new("activity_leaf"):get("gone\0message\0part", 1))
		assert.is_not_nil(memo.new("activity_leaf"):get("kept\0message\0part", 1))
		assert.is_nil(memo.new("history_metadata"):get("gone", 1))
		assert.is_not_nil(memo.new("history_metadata"):get("kept", 1))
		assert.equals(1, render_state.code_cache_stats().entries)
	end)
	it("releases memo and code values even when retaining the chat surface", function()
		populate("gone")
		local clears = 0
		package.loaded["opencode.ui.chat"] = { clear = function() clears = clears + 1 end }
		cleanup.clear_transient({ clear_chat = false })
		assert.equals(0, clears)
		assert.equals(0, memo.stats().entries)
		assert.equals(0, render_state.code_cache_stats().entries)
	end)
	it("closing an inactive tab releases its descendants' memos and preserves the active tab", function()
		local state, sync = require("opencode.state"), require("opencode.sync")
		local session, locks = require("opencode.session"), require("opencode.session.lock")
		state.reset(); sync.clear_all(); locks.clear_all()
		state.set_session("gone", "Closing tab")
		state.set_session("kept", "Active tab")
		for _, pair in ipairs({ { "gone", "child" }, { "child", "grandchild" } }) do
			local sid, child = pair[1], pair[2]
			sync.handle_message_updated({ id = sid .. "-message", sessionID = sid,
				role = "assistant", time = { created = 1 } })
			sync.handle_part_updated({ id = sid .. "-task", messageID = sid .. "-message",
				sessionID = sid, type = "tool", tool = "task",
				state = { status = "completed", metadata = { sessionId = child } } })
		end
		local owners = {}
		for _, sid in ipairs({ "gone", "child", "grandchild", "kept" }) do owners[sid] = populate(sid) end
		locks.set("gone", { agent = "build" })
		local view_clears = 0
		package.loaded["opencode.ui.chat"] = { clear_session_view = function() view_clears = view_clears + 1 end }

		assert.is_true(session.close("gone", { silent = true }))
		for _, sid in ipairs({ "gone", "child", "grandchild" }) do
			assert.is_nil(render_state.render_cache_get("revision", owners[sid]))
			assert.is_false(select(3, render_state.task_summary_cache_get(sid, 1)))
			assert.is_nil(memo.new("activity_leaf"):get(sid .. "\0message\0part", 1))
			assert.is_nil(memo.new("history_metadata"):get(sid, 1))
		end
		assert.is_not_nil(render_state.render_cache_get("revision", owners.kept))
		assert.is_true(select(3, render_state.task_summary_cache_get("kept", 1)))
		assert.is_not_nil(memo.new("activity_leaf"):get("kept\0message\0part", 1))
		assert.is_not_nil(memo.new("history_metadata"):get("kept", 1))
		assert.equals(1, render_state.code_cache_stats().entries)
		assert.equals("kept", state.get_session().id)
		assert.equals(0, view_clears)
		assert.is_false(state.is_runtime_session("gone"))
		assert.is_true(locks.is_locked("gone")) -- Closing a tab does not delete its local session state.
		state.reset(); sync.clear_all(); locks.clear_all()
	end)
end)
