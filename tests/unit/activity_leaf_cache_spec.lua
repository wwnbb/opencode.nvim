local group = require("opencode.ui.chat.tool_group")
local exploration = require("opencode.ui.chat.exploration_tool")
local execute = require("opencode.ui.chat.execute")
local render = require("opencode.ui.chat.render")
local syntax = require("opencode.ui.syntax")
local sync = require("opencode.sync")
local app = require("opencode.state")
local cs = require("opencode.ui.chat.state").state
local surface_helper = require("tests.helpers.chat_surface")

describe("completed activity leaf cache", function()
	local surface, saved, calls, config, width, cwd
	local sid, mid = "leaf-cache-session", "leaf-cache-message"
	local code = "local example_value = 1\nreturn example_value"

	local function put(id, output, tool)
		local part = { id = id, messageID = mid, sessionID = sid, type = "tool", tool = tool or "read",
			state = { status = "completed", input = { filePath = cwd .. "/" .. id .. ".lua" },
				output = output or code, time = { start = 1, ["end"] = 2 } } }
		if tool == "execute" then
			part.state.input = { code = "return await tools.read()" }
			part.state.metadata = { toolCalls = { { tool = "read", status = "completed" } } }
		end
		sync.handle_part_updated(part)
		return part
	end

	local function change(id, callback)
		local part = vim.deepcopy(sync.get_part(mid, id))
		callback(part)
		sync.handle_part_updated(part)
		return part
	end

	local function draw(ids, expanded, expansions, kind)
		local refs = {}
		for _, id in ipairs(ids) do
			refs[#refs + 1] = { message = sync.get_message(sid, mid), part = sync.get_part(mid, id) }
		end
		return group.render(kind or "explore", refs, expanded ~= false, expansions or {})
	end

	local function cold_equal(ids, expanded, expansions, kind)
		local warm = draw(ids, expanded, expansions, kind)
		group.clear_leaf_cache()
		assert.same(warm, draw(ids, expanded, expansions, kind))
		return warm
	end

	before_each(function()
		surface = surface_helper.setup()
		config = vim.deepcopy(require("opencode.config").defaults)
		width, cwd, calls = 100, "/tmp/opencode-leaf-cache", {}
		saved = { exploration = exploration.render, execute = execute.render, width = render.get_chat_text_width,
			cwd = vim.fn.getcwd, config = app.get_config, parser = vim.treesitter.get_string_parser,
			ambiwidth = vim.o.ambiwidth }
		app.get_config = function() return config end
		render.get_chat_text_width = function() return width end
		vim.fn.getcwd = function() return cwd end
		for name, widget in pairs({ exploration = exploration, execute = execute }) do
			widget.render = function(part, ...)
				calls[part.id] = (calls[part.id] or 0) + 1
				return saved[name](part, ...)
			end
		end
		sync.handle_message_updated({ id = mid, sessionID = sid, role = "assistant", time = { created = 1 } })
		group.clear_leaf_cache()
	end)

	after_each(function()
		exploration.render, execute.render = saved.exploration, saved.execute
		render.get_chat_text_width, vim.fn.getcwd, app.get_config = saved.width, saved.cwd, saved.config
		vim.treesitter.get_string_parser = saved.parser
		vim.o.ambiwidth = saved.ambiwidth
		group.clear_leaf_cache()
		surface_helper.restore(surface)
		if saved.editor and vim.api.nvim_buf_is_valid(saved.editor) then
			vim.api.nvim_buf_delete(saved.editor, { force = true })
		end
	end)

	it("reuses completed bodies and rebuilds only the changed or expanded sibling", function()
		put("first"); put("second")
		local expanded = { first = true, second = true }
		local first = draw({ "first", "second" }, true, expanded)
		assert.same(first, draw({ "first", "second" }, true, expanded))
		assert.same({ first = 1, second = 1 }, calls)
		change("second", function(part) part.state.output = code .. "\nreturn 2" end)
		draw({ "first", "second" }, true, expanded)
		assert.same({ first = 1, second = 2 }, calls)
		expanded.second = false
		draw({ "first", "second" }, true, expanded)
		assert.same({ first = 1, second = 3 }, calls)
		cold_equal({ "first", "second" }, true, expanded)
	end)

	it("rebinds equal replacements and never exposes cached nested widget tables", function()
		local original = put("execute", nil, "execute")
		local expanded = { execute = true }
		local first = draw({ "execute" }, true, expanded, "execute")
		local nested_id = execute.section_id("execute", "calls")
		assert.equals(original, first.children.execute.children[nested_id].tool_part)
		local revision = sync.get_part_revision(mid, "execute")
		local replacement = change("execute", function() end)
		assert.equals(revision, sync.get_part_revision(mid, "execute"))
		local second = draw({ "execute" }, true, expanded, "execute")
		assert.equals(1, calls.execute)
		assert.equals(replacement, second.children.execute.tool_part)
		assert.equals(replacement, second.children.execute.children[nested_id].tool_part)
		assert.is_not.equals(first.children.execute.children, second.children.execute.children)
		second.children.execute.children[nested_id].start_line = 999
		second.lines[2] = "mutated caller output"
		local leaf_highlight = second.highlights[#second.highlights].hl_group
		second.highlights[#second.highlights].hl_group = "ErrorMsg"
		local third = draw({ "execute" }, true, expanded, "execute")
		assert.is_not.equals(999, third.children.execute.children[nested_id].start_line)
		assert.is_not.equals("mutated caller output", third.lines[2])
		assert.equals(leaf_highlight, third.highlights[#third.highlights].hl_group)
		assert.equals(1, calls.execute)
		cold_equal({ "execute" }, true, expanded, "execute")
	end)

	it("keeps a large completed group warm within the shared budget", function()
		local ids, expanded = {}, {}
		for index = 1, 30 do
			local id = "large-" .. index
			put(id, ("local foo = math.max(1, 2)\n"):rep(100))
			ids[index], expanded[id] = id, true
		end
		local first = draw(ids, true, expanded)
		assert.same(first, draw(ids, true, expanded))
		for _, id in ipairs(ids) do assert.equals(1, calls[id]) end
		local budget = require("opencode.util.memo").stats()
		assert.is_true(budget.bytes <= budget.max_bytes)
	end)

	it("separates grouped mode and rejects stale bodies after owner revision reuse", function()
		local part = put("owner", nil, "execute")
		group.render_leaf(part, true, { grouped = false })
		group.render_leaf(part, true, { grouped = false })
		assert.equals(1, calls.owner)
		group.render_leaf(part, true, { grouped = true })
		group.render_leaf(part, true, { grouped = true })
		assert.equals(2, calls.owner)
		local revision = sync.get_part_revision(mid, "owner")
		sync.clear_all()
		sync.handle_message_updated({ id = mid, sessionID = sid, role = "assistant", time = { created = 1 } })
		part = vim.deepcopy(part)
		part.state.metadata.toolCalls[1].tool = "replacement tool"
		sync.handle_part_updated(part)
		assert.equals(revision, sync.get_part_revision(mid, "owner"))
		local rendered = group.render_leaf(part, true, { grouped = true })
		assert.equals(3, calls.owner)
		assert.is_truthy(table.concat(rendered.lines, "\n"):find("replacement tool", 1, true))
		group.clear_leaf_cache()
		assert.same(rendered, group.render_leaf(part, true, { grouped = true }))
	end)

	it("keeps running bodies, spinner headers and folded error visibility live", function()
		put("done"); put("running")
		change("running", function(part) part.state.status = "running"; part.state.time["end"] = nil end)
		cs.task_anim_frame = 1
		local first = draw({ "done", "running" }, true, { done = true, running = true })
		cs.task_anim_frame = 2
		local second = draw({ "done", "running" }, true, { done = true, running = true })
		assert.same({ done = 1, running = 2 }, calls)
		assert.is_not.equals(first.lines[1], second.lines[1])
		change("running", function(part) part.state.status = "error"; part.state.error = "Failed now" end)
		local folded = draw({ "done", "running" }, false)
		assert.is_nil(folded.children.done.start_line)
		assert.is_number(folded.children.running.start_line)
		assert.is_truthy(table.concat(folded.lines, "\n"):find("Failed now", 1, true))
		assert.is_truthy(folded.lines[1]:find("1 failed", 1, true))
		cold_equal({ "done", "running" }, false)
	end)

	it("retries unavailable syntax and retains the recovered body on ordinary draws", function()
		put("retry")
		local available = false
		vim.treesitter.get_string_parser = function(text, lang, opts)
			if lang == "lua" and not available then error("temporarily unavailable") end
			return saved.parser(text, lang, opts)
		end
		draw({ "retry" }, true, { retry = true })
		draw({ "retry" }, true, { retry = true })
		assert.equals(2, calls.retry)
		available = true
		local recovered = draw({ "retry" }, true, { retry = true })
		assert.same(recovered, draw({ "retry" }, true, { retry = true }))
		assert.equals(3, calls.retry)
		assert.is_true(#recovered.highlights > 0)
		cold_equal({ "retry" }, true, { retry = true })
	end)

	it("invalidates width, cwd, config values, display options and theme dependencies", function()
		put("dependencies", "local value = \"" .. string.rep("x", 140) .. "\"\n\treturn value")
		local function get() return draw({ "dependencies" }, true, { dependencies = true }) end
		get(); get(); assert.equals(1, calls.dependencies)
		for index, update in ipairs({
			function() width = 70 end,
			function() cwd = cwd .. "/nested" end,
			function() config.syntax.tools = false end,
			function() config.syntax.tools = true end,
			function()
				vim.bo[surface.bufnr].tabstop = 3
				saved.editor = vim.api.nvim_create_buf(false, true)
				vim.bo[saved.editor].tabstop = 3
				vim.api.nvim_win_set_buf(surface.winid, saved.editor)
			end,
			function()
				vim.bo.tabstop = 5
				assert.equals(3, vim.bo[surface.bufnr].tabstop)
			end,
			function() vim.o.ambiwidth = saved.ambiwidth == "double" and "single" or "double" end,
			function() vim.api.nvim_exec_autocmds("ColorScheme", {}) end,
		}) do
			update(); get(); get()
			assert.equals(index + 1, calls.dependencies)
		end
		cold_equal({ "dependencies" }, true, { dependencies = true })
	end)

	it("uses exact detached snapshots instead of trusting reused IDs or mutable source tables", function()
		local part = { id = "detached", messageID = "detached-message", sessionID = sid,
			type = "tool", tool = "read", state = { status = "completed", input = { path = "example.lua" }, output = code } }
		local refs = { { part = part, message = { id = "detached-message", sessionID = sid } } }
		local function get() return group.render("explore", refs, true, { detached = true }) end
		local before = get(); assert.same(before, get()); assert.equals(1, calls.detached)
		part.state.output = code .. "\nreturn 33"
		local changed = get()
		assert.equals(2, calls.detached)
		assert.is_not.same(before.lines, changed.lines)
		group.clear_leaf_cache()
		assert.same(changed, get())
	end)

	it("matches cold lines, byte highlights and child ranges after each structural event", function()
		put("first", code .. "\n" .. code); put("second")
		local ids, expanded = { "first", "second" }, { first = true, second = true }
		cold_equal(ids, true, expanded)
		for _, update in ipairs({
			function() change("first", function(part) part.state.output = "return 1" end) end,
			function() change("second", function(part) part.state.output = "local value = \"猫🙂é\"\n\treturn value" end) end,
			function() expanded.first = false end,
			function() width = 34 end,
			function() ids = { "second", "first" } end,
			function() change("second", function(part) part.state.status = "error"; part.state.error = "line one\nline two" end) end,
			function() ids = { "second" }; sync.handle_part_removed(mid, "first") end,
			function() vim.api.nvim_exec_autocmds("ColorScheme", {}) end,
		}) do
			update()
			cold_equal(ids, true, expanded)
		end
	end)
end)
