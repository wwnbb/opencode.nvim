local chat_surface = require("tests.helpers.chat_surface")
local app = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local tasks = require("opencode.ui.chat.tasks")
local bash = require("opencode.ui.chat.bash")
local render = require("opencode.ui.chat.render")
local render_state = require("opencode.ui.chat.render_state")
local projection = require("opencode.protocol.messages")
local questions = require("opencode.question.state")
local edits = require("opencode.edit.state")
local tree = require("opencode.ui.chat.widget_tree")

local session = "bash-separators"

local function shell(id, output, status)
	return { type = "tool", id = id, name = "shell", state = {
		status = status or "completed", input = { command = "printf " .. id },
		content = output and { { type = "text", text = output } } or {},
	} }
end

local function message(id, content, created)
	return { id = id, type = "assistant", time = { created = created or 1, completed = (created or 1) + 1 }, content = content }
end

local function update(messages, session_id)
	session_id = session_id or session
	sync.handle_session_messages(session_id, projection.page(session_id, messages))
end

local function lines()
	return vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
end

local function draw()
	chat.do_render()
	return lines()
end

local function seed(content)
	update({ message("message", content) })
	draw()
	return sync.get_parts("message")
end

local function separator_rows(rendered)
	local rows = {}
	for row, line in ipairs(rendered or lines()) do
		if line:sub(1, #"▏  ─") == "▏  ─" then rows[#rows + 1] = row - 1 end
	end
	return rows
end

local function assert_separator(id)
	local pos = assert(tree.find(state.tools, id))
	local line = lines()[pos.start_line + 1]
	assert.is_true(pos.separator_before)
	local body_width = render.get_chat_text_width() - vim.fn.strdisplaywidth("▏  ")
	local cell_width = vim.fn.strdisplaywidth("─")
	assert.equals("▏  " .. string.rep("─", math.floor(body_width / cell_width))
		.. string.rep(" ", body_width % cell_width), line)
	local marks = vim.api.nvim_buf_get_extmarks(state.bufnr, cs.chat_hl_ns,
		{ pos.start_line, 0 }, { pos.start_line, -1 }, { details = true })
	assert.is_true(vim.iter(marks):any(function(mark)
		return mark[3] == 0 and mark[4].end_col == #line and mark[4].hl_group == "OpenCodeBashMuted"
	end))
end

describe("adjacent shell panel separators", function()
	local surface, columns, original_render, display
	before_each(function()
		surface = chat_surface.setup()
		columns, original_render = vim.o.columns, tasks.render_regular_tool
		display = { ambiwidth = vim.o.ambiwidth, cells = vim.fn.getcellwidths() }
		vim.o.ambiwidth = "single"
		vim.fn.setcellwidths({})
		local config = vim.deepcopy(app.get_config())
		config.syntax.tools = false
		app.set_config(config)
		app.set_session(session, "Shell separators")
		app.set_session_status(session, { type = "idle" })
		chat.setup({ session_tabs = { enabled = true }, auto_scroll = false })
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr, {})
	end)
	after_each(function()
		tasks.render_regular_tool = original_render
		questions.clear_all()
		edits.clear_all()
		vim.o.columns = columns
		vim.o.ambiwidth = display.ambiwidth
		vim.fn.setcellwidths(display.cells)
		chat_surface.restore(surface)
	end)

	it("draws exactly N-1 lines inside the following panels without changing height", function()
		for count = 1, 4 do
			local content = {}
			for i = 1, count do content[i] = shell("shell-" .. i, "output " .. i) end
			local parts = seed(content)
			local expected_rows, height = {}, 0
			for i, part in ipairs(parts) do
				local pos = state.tools[part.id]
				local plain = bash.render_tool(part, false)
				assert.equals(height, pos.start_line)
				assert.equals(height + #plain.lines - 1, pos.end_line)
				if i == 1 then
					assert.is_false(pos.separator_before)
					assert.equals("▏", vim.trim(lines()[1]))
				else
					expected_rows[#expected_rows + 1] = pos.start_line
					assert_separator(part.id)
				end
				height = height + #plain.lines
			end
			assert.equals(height, #lines())
			assert.equals("▏", vim.trim(lines()[height]))
			assert.same(expected_rows, separator_rows())
			local first = lines()
			assert.same(first, draw(), "warm rendering must keep the same separators")
		end
	end)

	for _, boundary in ipairs({
		{ type = "text", text = "Visible explanation" },
		{ type = "reasoning", text = "Visible thought" },
		{ type = "tool", id = "other", name = "custom", state = { status = "completed" } },
		{ type = "tool", id = "other", name = "read", state = { status = "completed", input = { path = "README.md" } } },
		{ type = "tool", id = "other", name = "skill", state = { status = "completed", input = { name = "example" } } },
		{ type = "tool", id = "other", name = "subagent", state = {
			status = "completed", input = { agent = "build", description = "Other task" },
		} },
	}) do
		it("restarts after visible " .. (boundary.name or boundary.type), function()
			local parts = seed({ shell("first"), boundary, shell("second"), shell("third") })
			assert.is_false(state.tools[parts[3].id].separator_before)
			assert_separator(parts[4].id)
			assert.same({ state.tools[parts[4].id].start_line }, separator_rows())
		end)
	end

	for _, kind in ipairs({ "question", "edit" }) do
		it("restarts after an interactive " .. kind .. " widget", function()
			update({ message("message", { shell("first"), shell("second"), shell("third") }) })
			if kind == "question" then
				questions.add_form({ id = "interaction", sessionID = session,
					fields = { { key = "choice", type = "select", title = "Pick one", options = { { label = "Yes", value = "yes" } } } },
					metadata = { tool = { messageID = "message", id = "first" } },
				})
			else
				edits.add_edit("interaction", session, { { filePath = "example.txt", before = "before", after = "after" } }, {
					message_id = "message", call_id = "first", review_mode = "readonly",
				})
			end
			draw()
			assert.is_not_nil(state[kind == "edit" and "edits" or kind .. "s"].interaction)
			local parts = sync.get_parts("message")
			assert.is_false(state.tools[parts[2].id].separator_before)
			assert_separator(parts[3].id)
			assert.same({ state.tools[parts[3].id].start_line }, separator_rows())
		end)
	end

	it("spans messages and ignores hidden messages, empty text and redacted or unsupported parts", function()
		update({
			message("first-message", { shell("first"), { type = "text", text = "" },
				{ type = "reasoning", text = "[REDACTED]" }, { type = "file", uri = "file:///hidden" } }),
			{ id = "idle", type = "idle", time = { created = 3 } },
			{ id = "switched", type = "agent-switched", agent = "hidden", time = { created = 4 } },
			message("empty", {}, 5),
			message("second-message", { shell("second") }, 6),
		})
		draw()
		local first, second = sync.get_parts("first-message")[1], sync.get_parts("second-message")[1]
		assert.equals(state.tools[first.id].end_line + 1, state.tools[second.id].start_line)
		assert_separator(second.id)
		assert.same({ state.tools[second.id].start_line }, separator_rows())
	end)

	it("does not cross a visible message footer", function()
		local first = message("first-message", { shell("first") })
		first.agent, first.model, first.finish = "build", { id = "test", providerID = "test" }, "stop"
		update({ first, message("second-message", { shell("second") }, 3) })
		draw()
		assert.is_truthy(table.concat(lines(), "\n"):find("test", 1, true))
		assert.same({}, separator_rows())
	end)

	it("ignores a tool renderer that produces no visible rows", function()
		tasks.render_regular_tool = function(part, ...)
			if part.tool == "hidden" then return { lines = {}, highlights = {} } end
			return original_render(part, ...)
		end
		local parts = seed({ shell("first"), { type = "tool", id = "hidden", name = "hidden", state = { status = "completed" } }, shell("second") })
		assert.equals(state.tools[parts[1].id].end_line + 1, state.tools[parts[3].id].start_line)
		assert_separator(parts[3].id)
	end)

	it("keys cached panels by adjacency without mutating results from an earlier context", function()
		local builds = 0
		tasks.render_regular_tool = function(...)
			builds = builds + 1
			return original_render(...)
		end
		update({ message("first-message", { shell("first") }), message("second-message", { shell("second") }, 3) })
		local warm = draw()
		assert.same(warm, draw())
		assert.equals(2, builds)
		local cached = render_state.ensure_render_cache()
		local snapshot = vim.deepcopy(cached)
		local first = vim.deepcopy(sync.get_parts("first-message")[1])
		local changed = vim.deepcopy(first)
		changed.type, changed.text, changed.tool, changed.state = "text", "Visible boundary", nil, nil
		sync.handle_part_updated(changed)
		draw()
		assert.same({}, separator_rows())
		assert.equals(3, builds, "the unchanged second message must rebuild when its neighbor changes")
		assert.same(snapshot, cached, "a previous cached result must remain untouched")
		sync.handle_part_updated(first)
		assert.same(warm, draw())
		render_state.clear_render_cache()
		assert.same(warm, draw(), "cold rendering must match the warm context")
	end)

	it("keeps separators, highlights and ranges when O toggles either adjacent panel", function()
		local output = table.concat(vim.fn.range(1, 16), "\n")
		local parts = seed({ shell("first", output), shell("second", output), { type = "text", text = "Following answer" } })
		local second_start = state.tools[parts[2].id].start_line
		for _, id in ipairs({ parts[1].id, parts[2].id, parts[1].id, parts[2].id }) do
			vim.api.nvim_win_set_cursor(state.winid, { state.tools[id].start_line + 2, 0 })
			assert.equals(id, tasks.get_tool_at_cursor())
			vim.fn.maparg("O", "n", false, true).callback()
			assert_separator(parts[2].id)
			assert.equals(state.tools[parts[1].id].end_line + 1, state.tools[parts[2].id].start_line)
			local pos = state.tools[id]
			assert.equals(#bash.render_tool(sync.get_part("message", id), state.expanded_tools[id] == true).lines,
				pos.end_line - pos.start_line + 1)
			local in_place = lines()
			assert.same(in_place, draw())
			assert.equals(id, tasks.get_tool_at_cursor())
		end
		assert.equals(second_start, state.tools[parts[2].id].start_line)
		vim.api.nvim_win_set_cursor(state.winid, { second_start + 1, 0 })
		assert.equals(parts[2].id, tasks.get_tool_at_cursor(), "the separator belongs to the second panel")
		assert.is_truthy(table.concat(lines(), "\n"):find("Following answer", 1, true))
	end)

	it("preserves the separator during both animation fallback update paths", function()
		local parts = seed({ shell("first"), shell("second", "live output", "running") })
		tasks.stop_task_animation_timer()
		state.task_anim_frame = 2
		assert.is_true(tasks.update_active_animations_in_place())
		assert_separator(parts[2].id)
		local part = vim.deepcopy(parts[2])
		part.state.output = "live output\nmore output"
		sync.handle_part_updated(part)
		assert.is_true(tasks.update_active_animations_in_place())
		assert_separator(part.id)
		local in_place = lines()
		assert.same(in_place, draw())
	end)

	it("recomputes the divider width on resize without adding wrapped screen rows", function()
		local parts = seed({ shell("first", "one"), shell("second", "two") })
		for _, width in ipairs({ 100, 24, 72 }) do
			vim.o.columns = width
			local resized = draw()
			assert_separator(parts[2].id)
			assert.same({ state.tools[parts[2].id].start_line }, separator_rows())
			assert.equals(#resized, vim.api.nvim_win_text_height(state.winid, {}).all)
			assert.same(resized, draw())
		end
	end)

	it("separates visible bash children in expanded Activity but not across other children or its header", function()
		local config = vim.deepcopy(app.get_config())
		config.session.verbosity = "low"
		app.set_config(config)
		local parts = seed({ shell("first"), shell("second"),
			{ type = "tool", id = "other", name = "custom", state = { status = "completed" } },
			shell("third"), shell("fourth"), { type = "reasoning", text = "Visible thought" },
			shell("fifth"), shell("sixth"),
		})
		local parent = next(state.tools)
		tasks.handle_tool_toggle(parent)
		assert.is_true(state.expanded_tools[parent])
		for _, index in ipairs({ 2, 5, 8 }) do assert_separator(parts[index].id) end
		assert.same({ tree.find(state.tools, parts[2].id).start_line, tree.find(state.tools, parts[5].id).start_line,
			tree.find(state.tools, parts[8].id).start_line }, separator_rows())
		assert.equals("▏", vim.trim(lines()[tree.find(state.tools, parts[1].id).start_line + 1]))
		for _, index in ipairs({ 1, 2 }) do
			tasks.handle_tool_toggle(parts[index].id)
			assert_separator(parts[2].id)
			local in_place = lines()
			assert.same(in_place, draw())
		end
	end)

	it("separates folded Activity errors across hidden children but not a visible non-bash error", function()
		local config = vim.deepcopy(app.get_config())
		config.session.verbosity = "low"
		app.set_config(config)
		local parts = seed({ shell("first", nil, "error"),
			{ type = "tool", id = "hidden-read", name = "read", state = { status = "completed", input = { path = "README.md" } } },
			{ type = "reasoning", text = "Hidden thought" }, shell("hidden-bash"), shell("second", nil, "error"),
			{ type = "tool", id = "visible-error", name = "custom", state = { status = "error", error = "Failed" } },
			shell("third", nil, "error"), shell("fourth", nil, "error"),
		})
		assert.is_nil(tree.find(state.tools, parts[2].id).start_line)
		assert.is_nil(tree.find(state.tools, parts[4].id).start_line)
		assert_separator(parts[5].id)
		assert_separator(parts[8].id)
		assert.same({ tree.find(state.tools, parts[5].id).start_line, tree.find(state.tools, parts[8].id).start_line }, separator_rows())
		tasks.handle_tool_toggle(parts[5].id)
		assert_separator(parts[5].id)
		local in_place = lines()
		assert.same(in_place, draw())
	end)

	it("keeps an Activity container between standalone shell sequences", function()
		local parts = seed({ shell("before"), shell("inner-first"), shell("inner-second"), shell("after"), shell("last") })
		local group = { id = "activity:inner", kind = "activity", completed = true, refs = {
			{ part = parts[2], message = sync.get_message(session, "message") },
			{ part = parts[3], message = sync.get_message(session, "message") },
		} }
		local ctx = require("opencode.ui.chat.render_context").new({ current_session = { id = session } })
		local renderer = require("opencode.ui.chat.tool_renderer")
		ctx:reset_tracking()
		renderer.render_tool_part(ctx, parts[1], 1, {})
		local result = require("opencode.ui.chat.activity").render(group, true)
		local base = ctx:add_render_result(result, "activity")
		renderer.render_tool_part(ctx, parts[4], 1, {})
		renderer.render_tool_part(ctx, parts[5], 1, {})
		assert.is_false(state.tools[parts[1].id].separator_before)
		assert.is_false(state.tools[parts[4].id].separator_before)
		assert.same({ base + result.children[parts[3].id].start_line, state.tools[parts[5].id].start_line }, separator_rows(ctx.raw_lines))
	end)

	for _, mode in ipairs({ "standalone", "expanded Activity", "folded Activity" }) do
		for _, change in ipairs({
			{ name = "ambiwidth", apply = function() vim.o.ambiwidth = "double" end },
			{ name = "stroke cell width", apply = function() vim.fn.setcellwidths({ { 0x2500, 0x2500, 2 } }) end },
			{ name = "prefix cell width", apply = function() vim.fn.setcellwidths({ { 0x258f, 0x258f, 2 } }) end },
		}) do
			it("refreshes " .. mode .. " separators after a warm " .. change.name .. " change", function()
				if mode ~= "standalone" then
					local config = vim.deepcopy(app.get_config())
					config.session.verbosity = "low"
					app.set_config(config)
				end
				local status = mode == "folded Activity" and "error" or "completed"
				local parts = seed({ shell("first", nil, status), shell("second", nil, status) })
				if mode == "expanded Activity" then tasks.handle_tool_toggle(next(state.tools)) end
				local warm = draw()
				assert.same(warm, draw())
				change.apply()
				local refreshed = draw()
				assert_separator(parts[2].id)
				assert.equals(#refreshed, vim.api.nvim_win_text_height(state.winid, {}).all)
				local pos = tree.find(state.tools, parts[2].id)
				local panel = vim.list_slice(refreshed, pos.start_line + 1, pos.end_line + 1)
				render_state.clear_render_cache()
				local cold = draw()
				pos = tree.find(state.tools, parts[2].id)
				assert.same(panel, vim.list_slice(cold, pos.start_line + 1, pos.end_line + 1))
			end)
		end
	end

	it("does not carry a previous session's last shell into the next render context", function()
		seed({ shell("first"), shell("second") })
		local baseline = lines()
		update({ message("other-message", { shell("only") }) }, "other-session")
		for _ = 1, 2 do
			app.set_session("other-session", "Other")
			draw()
			assert.same({}, separator_rows())
			assert.is_false(state.tools[sync.get_parts("other-message")[1].id].separator_before)
			app.set_session(session, "Shell separators")
			assert.same(baseline, draw())
		end
	end)
end)
