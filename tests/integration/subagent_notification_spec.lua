local chat_surface = require("tests.helpers.chat_surface")
local app = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local state = require("opencode.ui.chat.state").state
local tasks = require("opencode.ui.chat.tasks")
local actions = require("opencode.actions")
local projection = require("opencode.protocol.messages")

describe("native subagent completion notifications", function()
	local surface, columns, serial, saved_actions, loads
	local session_id, child_id = "subagent-notifications", "ses_exact-notified-child"

	before_each(function()
		columns, serial, loads = vim.o.columns, 0, {}
		vim.o.columns = 160
		surface = chat_surface.setup()
		state.config = vim.deepcopy(app.get_config().chat)
		state.config.session_tabs.enabled = false
		app.set_session(session_id, "Subagent notifications")
		app.set_session_status(session_id, { type = "idle" })
		require("opencode.ui.chat.keymaps").setup_buffer(surface.bufnr)
		saved_actions = {}
		for _, name in ipairs({ "load_session_messages", "get_session", "set_view_session", "remember_session" }) do
			saved_actions[name] = actions[name]
		end
		actions.load_session_messages = function(id, _, callback)
			loads[#loads + 1] = id
			callback(nil, {})
		end
	end)

	after_each(function()
		for name, action in pairs(saved_actions) do actions[name] = action end
		require("opencode.session.lock").clear_all()
		chat_surface.restore(surface)
		vim.o.columns = columns
	end)

	local function notification(description, output, metadata)
		serial = serial + 1
		metadata = vim.tbl_extend("force", {
			source = "subagent", state = "completed", agent = "general", childID = child_id,
		}, metadata or {})
		return {
			id = "subagent-notice-" .. serial, type = "synthetic", time = { created = serial },
			description = description, metadata = metadata,
			text = '<subagent sessionID="' .. metadata.childID .. '" state="' .. metadata.state
				.. '" description="' .. description .. '">\n' .. output .. "\n</subagent>",
		}
	end

	local function show(native)
		local projected = projection.project(session_id, native)
		sync.clear_session_messages(session_id)
		sync.handle_session_messages(session_id, { projected })
		chat.do_render()
		return projected.parts[1].id, projected
	end

	local function block_text(id)
		local position = assert(state.tasks[id], "notification must be a navigable task")
		return table.concat(vim.api.nvim_buf_get_lines(surface.bufnr, position.start_line, position.end_line + 1, false), "\n")
	end

	local function contains(text, value)
		assert.is_truthy(text:find(value, 1, true), "missing literal text: " .. value)
	end

	local function absent(text, value)
		assert.is_nil(text:find(value, 1, true), "unexpected text: " .. value)
	end

	local function key(id, lhs)
		local position = assert(state.tasks[id])
		vim.api.nvim_set_current_win(surface.winid)
		vim.api.nvim_win_set_cursor(surface.winid, { position.start_line + 1, 0 })
		assert.equals(id, tasks.get_task_at_cursor())
		local mapping = vim.fn.maparg(lhs, "n", false, true)
		assert.equals(1, mapping.buffer)
		assert.is_function(mapping.callback)
		mapping.callback()
	end

	it("folds the report, expands with O and Enter, and preserves native data", function()
		local native = notification("Audit tab tests DRY KISS", "Audit report\nSecond result")
		local original = vim.deepcopy(native)
		local id, projected = show(native)
		contains(block_text(id), "General finished")
		contains(block_text(id), native.description)
		absent(block_text(id), "Audit report")
		absent(block_text(id), "<subagent")
		absent(block_text(id), child_id)
		assert.equals("text", projected.parts[1].type)
		assert.equals(native.text, projected.parts[1].text)
		assert.same(original, projected.info._native)
		assert.same(original, native)
		assert.is_not.equals(native.metadata, projected.parts[1].state.metadata)
		key(id, "O")
		assert.is_true(state.expanded_tasks[id])
		contains(block_text(id), "Audit report")
		contains(block_text(id), "Second result")
		absent(block_text(id), "<subagent")
		absent(block_text(id), "</subagent>")
		chat.do_render()
		contains(block_text(id), "Second result")
		key(id, "<CR>")
		assert.is_nil(state.expanded_tasks[id])
		absent(block_text(id), "Audit report")
		key(id, "<CR>")
		contains(block_text(id), "Audit report")
		assert.same({}, loads)
	end)

	it("keeps terminal outcomes static even when the child runs again", function()
		sync.handle_session_status(child_id, { type = "busy" })
		for _, case in ipairs({ { "completed", "finished" }, { "error", "failed" }, { "cancelled", "cancelled" } }) do
			local native = notification("Audit", "Outcome report", { state = case[1] })
			local id, projected = show(native)
			contains(block_text(id), "General " .. case[2])
			assert.is_false(tasks.is_animating_tool_part(projected.parts[1]))
		end
		local native = notification("Audit", "Outcome report")
		native.metadata.agent = nil
		local id = show(native)
		contains(block_text(id), "Subagent finished")
		assert.same({}, loads)
	end)

	it("opens exactly the notified child with gd", function()
		local id = show(notification("Audit", "Audit report"))
		local requested, opened
		actions.get_session = function(session, callback)
			requested = session
			callback(nil, { id = session, title = "Audit child", agent = "general", model = { providerID = "test", id = "model" } })
		end
		actions.remember_session = function() end
		actions.set_view_session = function(_, session) opened = session end
		key(id, "gd")
		assert.equals(child_id, requested)
		assert.equals(child_id, opened)
		assert.same({ child_id }, loads)
		assert.equals(session_id, state.session_stack[1].id)
	end)

	it("strips only the exact native wrapper while preserving quotes, newlines and nested tags", function()
		local description = 'Audit "quoted" tests\nSecond task line'
		local output = 'literal </subagent>\n<subagent sessionID="inner" state="error">\nInner result\n</subagent>\nFinal result'
		local native = notification(description, output)
		local id, projected = show(native)
		key(id, "O")
		local text = block_text(id)
		for _, line in ipairs(vim.split(output, "\n", { plain = true })) do contains(text, line) end
		absent(text, '<subagent sessionID="' .. child_id .. '"')
		assert.equals(native.text, projected.parts[1].text)
		local mismatch = notification("Audit", "Keep this result")
		mismatch.text = '<subagent sessionID="different-child" state="completed">\nKeep this result\n</subagent>'
		id = show(mismatch)
		key(id, "O")
		for _, line in ipairs(vim.split(mismatch.text, "\n", { plain = true })) do contains(block_text(id), line) end
	end)

	it("keeps user, assistant and invalid notification content as ordinary text", function()
		local native = notification("Audit", "Literal example")
		local cases = {
			{ id = "user", type = "user", text = native.text, metadata = native.metadata },
			{ id = "assistant", type = "assistant", content = { { type = "text", text = native.text,
				subagent_notification = true } }, metadata = native.metadata },
		}
		for _, metadata in ipairs({
			{}, { source = "subagent", state = "completed" },
			{ source = "subagent", state = "completed", childID = "" },
			{ source = "subagent", state = "completed", childID = 42 },
			{ source = "subagent", state = "running", childID = child_id },
			{ source = "other", state = "completed", childID = child_id },
		}) do
			cases[#cases + 1] = { id = "invalid-" .. #cases, type = "synthetic", text = native.text, metadata = metadata }
		end
		for _, value in ipairs(cases) do
			local id, projected = show(value)
			assert.is_nil(projected.parts[1].subagent_notification)
			assert.is_nil(state.tasks[id])
			assert.equals(native.text, projected.parts[1].text)
			local text = table.concat(vim.api.nvim_buf_get_lines(surface.bufnr, 0, -1, false), "\n")
			absent(text, "General finished")
			contains(text, "Literal example")
		end
	end)
end)
