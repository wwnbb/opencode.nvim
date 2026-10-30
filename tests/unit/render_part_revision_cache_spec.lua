local app = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local render = require("opencode.ui.chat.render")
local render_context = require("opencode.ui.chat.render_context")
local render_state = require("opencode.ui.chat.render_state")
local tasks = require("opencode.ui.chat.tasks")
local surface_helper = require("tests.helpers.chat_surface")

describe("chat render cache part revisions", function()
	local surface, original_content, original_tool, calls, tool_calls
	local sid, mid = "part-cache-session", "part-cache-assistant"

	local function text_part(id, text)
		sync.handle_part_updated({ id = id, messageID = mid, sessionID = sid, type = "text", text = text })
	end

	local function tool_part(id, status, output)
		sync.handle_part_updated({ id = id, messageID = mid, sessionID = sid, type = "tool", tool = "mcp_custom",
			callID = "call-" .. id, state = { status = status, input = { query = id }, output = output,
				time = { start = 1, ["end"] = status == "completed" and 2 or nil } } })
	end

	local function frame()
		local raw = chat.render()
		return table.concat(raw, "\n")
	end

	-- A cold render refills the cache; its rebuilds are not counted.
	local function cold_frame()
		local saved_calls, saved_tools = vim.deepcopy(calls), vim.deepcopy(tool_calls)
		render_state.clear_render_cache()
		require("opencode.ui.chat.tool_group").clear_leaf_cache()
		local result = frame()
		calls, tool_calls = saved_calls, saved_tools
		return result
	end

	before_each(function()
		surface = surface_helper.setup()
		app.set_session(sid, "Part cache")
		app.set_session_status(sid, { type = "idle" })
		calls, tool_calls = {}, {}
		original_content, original_tool = render.render_content, tasks.render_regular_tool
		render.render_content = function(content, ...)
			calls[content] = (calls[content] or 0) + 1
			return original_content(content, ...)
		end
		tasks.render_regular_tool = function(part, ...)
			tool_calls[part.id] = (tool_calls[part.id] or 0) + 1
			return original_tool(part, ...)
		end
		sync.handle_message_updated({ id = "part-cache-user", sessionID = sid, role = "user", time = { created = 1 } })
		sync.handle_part_updated({ id = "user-text", messageID = "part-cache-user", sessionID = sid,
			type = "text", text = "Question" })
		sync.handle_message_updated({ id = mid, sessionID = sid, role = "assistant", parentID = "part-cache-user",
			time = { created = 2 } })
	end)

	after_each(function()
		render.render_content, tasks.render_regular_tool = original_content, original_tool
		surface_helper.restore(surface)
	end)

	it("re-renders only the changed part of an in-progress assistant message", function()
		text_part("a-text", "First **answer** paragraph")
		tool_part("b-tool", "completed", "done")
		tool_part("c-tool", "completed", "done")
		text_part("d-text", "Second paragraph")
		local first = frame()
		assert.equals(1, calls["First **answer** paragraph"])
		assert.equals(1, calls["Second paragraph"])
		assert.equals(1, tool_calls["b-tool"])

		tool_part("c-tool", "completed", "changed output")
		local second = frame()
		assert.equals(1, calls["First **answer** paragraph"])
		assert.equals(1, calls["Second paragraph"])
		assert.equals(1, tool_calls["b-tool"])
		assert.equals(2, tool_calls["c-tool"])
		assert.equals(second, cold_frame())

		text_part("d-text", "Second paragraph grows")
		local third = frame()
		assert.equals(1, calls["First **answer** paragraph"])
		assert.equals(1, calls["Second paragraph grows"])
		assert.equals(third, cold_frame())
		assert.are_not.equal(first, third)

		-- Completing the message changes no part, and no part output depends on it.
		calls, tool_calls = {}, {}
		sync.handle_message_updated({ id = mid, sessionID = sid, role = "assistant", parentID = "part-cache-user",
			time = { created = 2, completed = 3 } })
		local completed = frame()
		assert.is_nil(calls["First **answer** paragraph"])
		assert.is_nil(tool_calls["b-tool"])
		assert.equals(completed, cold_frame())
	end)

	it("builds the user-message highlight signature identically to chained cache keys", function()
		for index = 1, 30 do
			local id = string.format("sig-user-%02d", index)
			sync.handle_message_updated({ id = id, sessionID = sid, role = "user", agent = index % 2 == 0 and "plan" or nil,
				time = { created = 10 + index } })
			sync.handle_part_updated({ id = id .. "-text", messageID = id, sessionID = sid, type = "text", text = "u" .. index })
		end
		local ctx = render_context.new({ current_session = app.get_session() })
		local expected = ctx.content_highlights._opencode_signature
		ctx:reset_tracking()
		require("opencode.ui.chat.message_renderer").render(ctx,
			require("opencode.ui.chat.widget_index").new({ current_session = ctx.current_session }))
		for _, message in ipairs(sync.get_messages(sid)) do
			if message.role == "user" then
				local agent = message.agent or require("opencode.local").message_agent.get(sid, message.id)
					or ctx.history_metadata.agent(message.id) or "unknown"
				expected = render_state.render_cache_key(expected, message.id, agent)
			end
		end
		assert.equals(expected, ctx.content_highlights._opencode_signature)
	end)
end)
