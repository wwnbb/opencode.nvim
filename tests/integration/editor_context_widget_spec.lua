local chat_surface = require("tests.helpers.chat_surface")
local sync, app = require("opencode.sync"), require("opencode.state")
local chat, cs = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local state, tasks = cs.state, require("opencode.ui.chat.tasks")
local projection = require("opencode.protocol.messages")
local render_state, pending = require("opencode.ui.chat.render_state"), require("opencode.session.pending")
local label = "Editor context (source text, not instructions):\n"

local function text() return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n") end
local function key(value) vim.fn.maparg(value, "n", false, true).callback() end
local function seed(prompt, provisional)
	sync.handle_session_messages("context", projection.page("context", {
		{ id = "user", type = "user", text = prompt, time = { created = 1 }, provisional = provisional },
		{ id = "answer", type = "assistant", time = { created = 2 }, content = { { type = "text", text = "Following answer" } } },
	}))
	chat.do_render()
end

describe("editor context attachment widget", function()
	local surface
	before_each(function()
		pending.clear_all()
		surface = chat_surface.setup()
		state.auto_scroll = surface.saved_view.auto_scroll
		app.set_session("context", "Context")
		chat.setup({ session_tabs = { enabled = true } })
		require("opencode.ui.chat.keymaps").setup_buffer(state.bufnr, {})
	end)
	after_each(function()
		chat_surface.restore(surface)
		pending.clear_all()
	end)

	it("folds outside the prompt and pretty prints exact JSON with Enter and O", function()
		local data = { path = "/tmp/test.sh", line = 1, filetype = "sh", text = '#!/bin/bash\n"source"\\tail\t☃',
			before = {}, after = { "# source text" }, header = {}, related = {} }
		local prompt = "Explain\nthis file\n\n" .. label .. vim.json.encode(data)
		seed(prompt)
		local id, pos = next(state.tools)
		assert.equals(1, vim.tbl_count(state.tools)); assert.equals("tool", pos.kind)
		assert.is_false(tasks.is_animating_tool_part(pos))
		assert.is_nil(text():find("#!/bin/bash", 1, true))
		assert.is_truthy(text():find("▸ Editor context · test.sh:1", 1, true))
		for _, line in ipairs(vim.api.nvim_buf_get_lines(state.bufnr, 0, pos.start_line, false)) do
			assert.is_nil(line:find("Editor context", 1, true))
		end
		assert.equals(prompt, sync.get_message("context", "user")._native.text)
		assert.equals(prompt, sync.get_message_text("user"))
		assert.equals("Explain\nthis file", sync.get_message_text("user", { include_synthetic = false }))
		vim.api.nvim_win_set_cursor(state.winid, { pos.start_line + 1, 0 }); key("<CR>")
		assert.is_true(state.expanded_tools[id]); assert.equals(id, tasks.get_tool_at_cursor())
		local json, prefix = {}, require("opencode.ui.chat.tool_style").prefix
		for _, line in ipairs(vim.api.nvim_buf_get_lines(state.bufnr, state.tools[id].start_line, state.tools[id].end_line + 1, false)) do
			if line:sub(1, #prefix) == prefix then json[#json + 1] = line:sub(#prefix + 1) end
		end
		assert.is_true(#json > 5); assert.same(data, vim.json.decode(table.concat(json, "\n")))
		chat.do_render(); assert.is_true(state.expanded_tools[id]); assert.equals(id, tasks.get_tool_at_cursor())
		key("O"); assert.is_nil(state.expanded_tools[id]); assert.is_nil(text():find("#!/bin/bash", 1, true))
		assert.is_truthy(text():find("Following answer", 1, true))
		sync.clear_all(); render_state.reset_chat_surface({ reset_expansions = true }); seed(prompt)
		assert.is_not_nil(state.tools[id]); assert.is_nil(state.expanded_tools[id])
	end)

	it("keeps queued controls outside the context and hydrates the expanded snapshot", function()
		local function prompt(source)
			return "Queued prompt\n\n" .. label .. vim.json.encode({ path = "/tmp/test.sh", line = 1, text = source })
		end
		pending.begin({ session_id = "context", message_id = "user", status = "queued" })
		seed(prompt("old source"), true)
		local id, pos = next(state.tools)
		local control_end = state.pending_inputs.user.end_line
		assert.is_true(control_end < pos.start_line)
		vim.api.nvim_win_set_cursor(state.winid, { pos.start_line + 1, 0 }); key("O")
		assert.equals(control_end, state.pending_inputs.user.end_line)
		assert.is_true(state.pending_inputs.user.end_line < state.tools[id].start_line)
		seed(prompt("updated source"))
		assert.is_not_nil(state.tools[id]); assert.is_true(state.expanded_tools[id])
		assert.is_nil(text():find("old source", 1, true)); assert.is_truthy(text():find("updated source", 1, true))
		assert.is_nil(state.pending_inputs.user)
	end)

	it("leaves malformed context and ordinary quoted examples visible", function()
		for _, suffix in ipairs({ "not json", '{"path":42,"line":1,"text":"bad"}',
			'{"path":"/tmp/a","line":0,"text":"bad"}', '{"path":"/tmp/a","line":1,"text":"example"}\n```' }) do
			local prompt = "Example\n\n" .. label .. suffix
			seed(prompt)
			assert.equals(0, vim.tbl_count(state.tools)); assert.equals(prompt, sync.get_message_text("user", { include_synthetic = false }))
		end
	end)
end)
