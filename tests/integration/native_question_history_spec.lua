describe("native question history", function()
	it("restores durable answers once without reviving an interactive form", function()
		local fixture = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/form-history/native.json"), "\n"))
		local app, sync, chat = require("opencode"), require("opencode.sync"), require("opencode.ui.chat")
		local session, forms = require("opencode.session"), require("opencode.question.state")
		app.setup({ server = { auto_start = false }, lualine = { enabled = false } })
		local sid = fixture.session.id
		session.remember(fixture.session); session.set_active(sid, "Question history", { preserve_cache = true })
		sync.handle_session_messages(sid, require("opencode.protocol.v2.messages").page(sid, fixture.native.data))
		for _ = 1, 2 do
			chat.open(); chat.do_render()
			local text = table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n")
			local _, count = text:gsub("History: Blue answer", "")
			assert.equals(1, count)
			assert.equals(0, #forms.get_all_active())
			chat.close()
		end
		require("opencode.cleanup").reset_all()
	end)

	it("does not claim unanswered or failed tools were answered", function()
		local render = require("opencode.ui.chat.question_result").render_tool
		for _, status in ipairs({ "running", "error", "cancelled" }) do
			assert.is_nil(render({ protocol = "v2", tool = "question", state = {
				status = status, input = { questions = { { header = "Question" } } }, metadata = { answers = {} },
			} }))
		end
	end)
end)
