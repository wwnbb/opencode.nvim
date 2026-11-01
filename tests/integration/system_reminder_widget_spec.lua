local chat_surface = require("tests.helpers.chat_surface")
local sync, app = require("opencode.sync"), require("opencode.state")
local chat, cs = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local state, tasks = cs.state, require("opencode.ui.chat.tasks")
local projection = require("opencode.protocol.messages")

local reminder = "<system-reminder>\nYou are in Plan mode. Discuss the plan with the user directly in the conversation."
	.. "\n\nDo not modify any other files.\n</system-reminder>"

local function text() return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n") end
local function key(value) vim.fn.maparg(value, "n", false, true).callback() end
local function seed(body, extra)
	sync.clear_session_messages("reminder")
	sync.handle_session_messages("reminder", projection.page("reminder", {
		{ id = "user", type = "user", text = "Plan it", time = { created = 1 } },
		vim.tbl_extend("force", { id = "notice", type = "synthetic", text = body, time = { created = 2 } }, extra or {}),
		{ id = "answer", type = "assistant", time = { created = 3 }, content = { { type = "text", text = "Following answer" } } },
	}))
	chat.do_render()
end

describe("system reminder widget", function()
	local surface
	before_each(function()
		surface = chat_surface.setup()
		state.auto_scroll = surface.saved_view.auto_scroll
		app.set_session("reminder", "Reminder")
		chat.setup({ session_tabs = { enabled = true } })
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr, {})
	end)
	after_each(function() chat_surface.restore(surface) end)

	it("folds to one row and shows the literal reminder when expanded", function()
		seed(reminder)
		local id, pos = next(state.tools)
		assert.equals(1, vim.tbl_count(state.tools)); assert.equals("tool", pos.kind)
		assert.is_false(tasks.is_animating_tool_part(pos))
		assert.is_truthy(text():find("▸ System reminder · You are in Plan mode.", 1, true))
		assert.is_nil(text():find("<system-reminder>", 1, true))
		assert.is_nil(text():find("Do not modify", 1, true))
		vim.api.nvim_win_set_cursor(state.winid, { pos.start_line + 1, 0 }); key("O")
		assert.is_true(state.expanded_tools[id])
		assert.is_truthy(text():find("▾ System reminder", 1, true))
		assert.is_truthy(text():find("Do not modify any other files.", 1, true))
		assert.is_nil(text():find("system-reminder>", 1, true))
		key("O"); assert.is_nil(state.expanded_tools[id])
		assert.is_nil(text():find("Do not modify", 1, true))
		assert.is_truthy(text():find("Following answer", 1, true))
	end)

	it("folds plain synthetic text as a notice", function()
		seed("User requested that active blocking work be moved to the background.\n\nBackgrounded work:\n- shell: sleep")
		local id, pos = next(state.tools)
		assert.equals(1, vim.tbl_count(state.tools))
		assert.is_truthy(text():find("▸ Notice · User requested that active blocking work", 1, true))
		assert.is_nil(text():find("Backgrounded work", 1, true))
		vim.api.nvim_win_set_cursor(state.winid, { pos.start_line + 1, 0 }); key("O")
		assert.is_true(state.expanded_tools[id])
		assert.is_truthy(text():find("- shell: sleep", 1, true))
	end)

	it("shows a described notice by its description", function()
		seed("Model-facing body", { description = "Context refreshed" })
		assert.equals(0, vim.tbl_count(state.tools))
		assert.is_truthy(text():find(" ◈ Context refreshed", 1, true))
		assert.is_nil(text():find("Model-facing body", 1, true))
	end)

	it("summarizes consecutive instruction loads as one row", function()
		local function load(id, created, paths, description)
			return { id = id, type = "synthetic", time = { created = created }, description = description,
				metadata = { instruction = { paths = paths } },
				text = "Instructions from: " .. paths[1] .. "\nSECRET INSTRUCTION BODY" }
		end
		sync.clear_session_messages("reminder")
		sync.handle_session_messages("reminder", projection.page("reminder", {
			{ id = "user", type = "user", text = "Read files", time = { created = 1 } },
			load("load-a", 2, { "/repo/src/AGENTS.md" }, "Loaded src/AGENTS.md"),
			{ id = "switch", type = "agent-switched", agent = "build", time = { created = 3 } },
			load("load-b", 4, { "/repo/lib/AGENTS.md", "/repo/src/AGENTS.md" }),
			{ id = "answer", type = "assistant", time = { created = 5 }, content = { { type = "text", text = "Following answer" } } },
			load("load-c", 6, { "/repo/test/AGENTS.md" }, "Loaded test/AGENTS.md"),
		}))
		chat.do_render()
		assert.equals(2, vim.tbl_count(state.tools))
		local _, count = text():gsub("Instructions · ", "")
		assert.equals(2, count)
		assert.is_truthy(text():find("▸ Instructions · 2 files", 1, true))
		assert.is_truthy(text():find("▸ Instructions · 1 file%s*\n") or text():find("▸ Instructions · 1 file%s*$"))
		assert.is_nil(text():find("SECRET", 1, true))
		local first = state.tools["instructions:" .. projection.part_id("reminder", "load-a", "text", 0)]
		assert.is_not_nil(first)
		vim.api.nvim_win_set_cursor(state.winid, { first.start_line + 1, 0 }); key("O")
		assert.is_truthy(text():find("     Loaded src/AGENTS.md", 1, true))
		assert.is_truthy(text():find("     Loaded /repo/lib/AGENTS.md, /repo/src/AGENTS.md", 1, true))
		assert.is_nil(text():find("Loaded test/AGENTS.md", 1, true))
		assert.is_nil(text():find("SECRET", 1, true))
	end)
end)
