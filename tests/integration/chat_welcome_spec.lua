local surface_helper = require("tests.helpers.chat_surface")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local app_state = require("opencode.state")
local sync = require("opencode.sync")
local project = require("opencode.protocol.messages").project

describe("chat welcome", function()
	local surface, winid, columns, height
	local function lines()
		return vim.api.nvim_buf_get_lines(surface.bufnr, 0, -1, false)
	end
	local function text()
		return table.concat(lines(), "\n")
	end
	local function highlighted(group)
		local result, content = {}, lines()
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(surface.bufnr, cs.chat_hl_ns, 0, -1, { details = true })) do
			if mark[4].hl_group == group and mark[4].end_col > mark[3] then
				result[#result + 1] = content[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
			end
		end
		return result
	end
	local function assert_centered()
		local width = vim.api.nvim_win_get_width(winid)
		for _, line in ipairs(lines()) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= width, "Welcome overflows: " .. line)
			if vim.trim(line) ~= "" then
				local left = #line:match("^ *")
				local right = width - vim.fn.strdisplaywidth(line)
				assert.is_true(math.abs(left - right) <= 1, "Welcome is not centered: " .. line)
			end
		end
	end

	before_each(function()
		columns, height = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 120, 45
		surface = surface_helper.setup()
		winid = vim.api.nvim_open_win(surface.bufnr, true, {
			relative = "editor", row = 0, col = 0, width = 80, height = 24, style = "minimal",
		})
		state.winid = winid
		chat.create()
		chat.setup({ session_tabs = { enabled = true } })
		state.auto_scroll = false
	end)

	after_each(function()
		vim.wait(30)
		if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_win_close(winid, true) end
		surface_helper.restore(surface)
		vim.o.columns, vim.o.lines = columns, height
	end)

	it("centers a useful welcome with highlighted default shortcuts", function()
		chat.do_render()
		assert.is_truthy(text():find("What would you like to build?", 1, true))
		assert.is_truthy(text():find("i  Start a conversation", 1, true))
		assert.is_truthy(text():find("<C-p>  Command palette", 1, true))
		assert.is_truthy(text():find("?  Help & shortcuts", 1, true))
		assert.same({ "OpenCode" }, highlighted("OpenCodeWelcomeTitle"))
		assert.same({ "i", "<C-p>", "?" }, highlighted("OpenCodeWelcomeKey"))
		assert.is_true(#highlighted("OpenCodeWelcomeHint") > 0)
		assert.equals("", lines()[1])
		assert.is_true(#lines() <= vim.api.nvim_win_get_height(winid))
		assert_centered()
	end)

	it("shows and highlights the configured input shortcut", function()
		state.config.keymaps.focus_input = "<CR>"
		chat.do_render()
		assert.is_truthy(text():find("<CR>  Start a conversation", 1, true))
		assert.same({ "<CR>", "<C-p>", "?" }, highlighted("OpenCodeWelcomeKey"))
	end)

	it("welcomes both absent and empty sessions with session tabs on or off", function()
		for _, enabled in ipairs({ true, false }) do
			state.config.session_tabs.enabled = enabled
			for _, id in ipairs({ false, "empty" }) do
				app_state.set_session(id or nil, id and "Empty session" or nil)
				chat.do_render()
				assert.is_truthy(text():find("Start a conversation", 1, true))
				assert.same({ "OpenCode" }, highlighted("OpenCodeWelcomeTitle"))
			end
		end
	end)

	it("reflows on window resize and drops padding in a short window", function()
		chat.do_render()
		for _, size in ipairs({ { 60, 16 }, { 18, 20 }, { 80, 4 } }) do
			local generation = state.applied_render_generation
			vim.api.nvim_win_set_config(winid, { width = size[1], height = size[2] })
			vim.api.nvim_exec_autocmds("WinResized", { data = { windows = { winid } } })
			assert.is_true(vim.wait(500, function()
				return state.applied_render_generation > generation
			end, 5), "Resize did not rerender the welcome")
			assert_centered()
			local unwrapped = text():gsub("%s+", " ")
			assert.is_truthy(unwrapped:find("Start a conversation", 1, true))
			assert.is_truthy(unwrapped:find("Help & shortcuts", 1, true))
			if size[2] >= 9 then assert.is_true(#lines() <= size[2]) end
		end
		assert.equals("OpenCode", vim.trim(lines()[1]))
	end)

	it("replaces the welcome with the first message or local notice", function()
		app_state.set_session("welcome", "Welcome")
		chat.do_render()
		assert.is_truthy(text():find("Start a conversation", 1, true))
		sync.handle_session_messages("welcome", { project("welcome", {
			id = "first", type = "assistant", time = { created = 1, completed = 2 },
			content = { { type = "text", text = "First assistant response" } },
		}) })
		chat.do_render()
		assert.is_truthy(text():find("First assistant response", 1, true))
		assert.same({}, highlighted("OpenCodeWelcomeTitle"))
		assert.is_nil(text():find("Start a conversation", 1, true))
		sync.clear_all()
		chat.add_message("system", "Connection notice", { render = false })
		chat.do_render()
		assert.is_truthy(text():find("Connection notice", 1, true))
		assert.same({}, highlighted("OpenCodeWelcomeTitle"))
		assert.is_nil(text():find("Start a conversation", 1, true))
	end)
end)
