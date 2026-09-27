local chat_state = require("opencode.ui.chat.state").state
local render_state = require("opencode.ui.chat.render_state")
local bus = require("opencode.events.bus")
local function wait_until(predicate, message) assert.is_true(vim.wait(500, predicate, 10), message) end

describe("chat render coordination contracts", function()
	before_each(function()
		bus.clear(); bus.clear_history()
		render_state.reset_chat_surface({ reset_expansions = true })
	end)
	after_each(function()
		bus.clear(); bus.clear_history()
		render_state.reset_chat_surface({ reset_expansions = true })
	end)

	it("clears highlights from the start of a containing widget", function()
		chat_state.permissions = {}
		chat_state.edits = {}
		chat_state.tasks = {}
		chat_state.tools = {
			widget_highlight_range = {
				start_line = 10,
				end_line = 20,
				highlights = {
					{ line = 1, col_start = 0, col_end = 10, hl_group = "PanelHeaderTest" },
				},
			},
		}

		assert(
			render_state.highlight_clear_start(15, {}) == 10,
			"highlight clear should expand from inside a widget to the widget start"
		)
		assert(
			render_state.highlight_clear_start(21, {}) == 21,
			"highlight clear should not expand outside the widget range"
		)
	end)

	it("routes snapshots and deltas separately and rebinds after clearing listeners", function()
		local render_coordinator = require("opencode.ui.chat.render_coordinator")
		bus.clear()
		bus.clear_history()
		render_coordinator.setup(bus)

		local full_render_count = 0
		local stream_render_count = 0
		bus.on("chat_render", function()
			full_render_count = full_render_count + 1
		end)
		bus.on("chat_stream_part_updated", function()
			stream_render_count = stream_render_count + 1
		end)

		bus.emit("sync_changed", {
			kind = "part",
			action = "updated",
			session_id = "stream_route_session",
			message_id = "stream_route_message",
			part_id = "stream_route_part",
		})
		wait_until(function()
			return full_render_count == 1
		end, "part.updated snapshots should request a full chat render")
		assert(stream_render_count == 0, "part.updated snapshots should not use stream-only rendering")

		bus.emit("sync_changed", {
			kind = "part",
			action = "updated",
			session_id = "stream_route_session",
			message_id = "stream_route_message",
			part_id = "stream_route_part",
			field = "text",
			delta = "chunk",
		})
		wait_until(function()
			return stream_render_count == 1
		end, "part deltas should use stream-only rendering")
		assert(full_render_count == 1, "part deltas should not force a full render")

		bus.clear()
		render_coordinator.setup(bus)
		full_render_count = 0
		stream_render_count = 0
		bus.on("chat_render", function()
			full_render_count = full_render_count + 1
		end)
		bus.on("chat_stream_part_updated", function()
			stream_render_count = stream_render_count + 1
		end)
		bus.emit("sync_changed", {
			kind = "session",
			action = "updated",
			session_id = "rebound_session",
		})
		wait_until(function()
			return full_render_count == 1
		end, "render coordinator should rebind after bus.clear")
		assert(stream_render_count == 0, "rebound snapshot should remain a full render")

		bus.clear()
		bus.clear_history()
	end)

end)
