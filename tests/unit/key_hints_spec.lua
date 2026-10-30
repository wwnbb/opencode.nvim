local config = require("opencode.config")
local app = require("opencode.state")
local keymaps = require("opencode.util.keymap")
local chat = require("opencode.ui.chat.state").state

describe("key_hints.enabled", function()
	local saved_config, saved_chat
	local function text(lines) return table.concat(lines, "\n"):gsub("▏", ""):gsub("%s+", " ") end
	local function hide() app.set_config(config.merge({ key_hints = { enabled = false } })) end
	before_each(function()
		saved_config, saved_chat = app.get_config(), chat.config
		app.set_config(config.merge({}))
		chat.config = { keymaps = {} }
	end)
	after_each(function()
		app.set_config(saved_config)
		chat.config = saved_chat
	end)

	it("formats key pairs, literal hints and status pieces", function()
		local items = { { status = "1/2 answered" }, { "<CR>", "confirm" }, "do=get hunk", { "(disabled)", "custom" } }
		assert.equals("1/2 answered · <CR> confirm · do=get hunk · (disabled) custom", keymaps.hint(items))
		assert.equals("1/2 answered  <CR>:confirm  do=get hunk", keymaps.hint(items, { sep = "  ", join = ":", omit_disabled = true }))
		assert.is_nil(keymaps.hint({ { "", "close" } }, { omit_disabled = true }))
		assert.is_nil(keymaps.hint({}))
	end)

	it("defaults to shown and rejects non-boolean values", function()
		assert.is_true(config.merge({}).key_hints.enabled)
		assert.equals("q close", keymaps.hint({ { "q", "close" } }))
		hide()
		assert.is_nil(keymaps.hint({ { "q", "close" }, "do=get hunk" }))
		assert.equals("Acknowledged", keymaps.hint({ { status = "Acknowledged" }, { "<CR>", "continue" } }))
		assert.has_error(function() config.merge({ key_hints = { enabled = "no" } }) end,
			"opencode.nvim: key_hints.enabled must be a boolean")
		assert.has_error(function() config.merge({ key_hints = false }) end,
			"opencode.nvim: key_hints.enabled must be a boolean")
	end)

	it("drops the permission footer without leaving an extra blank row", function()
		local function render()
			return require("opencode.ui.permission_widget").get_lines_for_permission("p", {
				permission_type = "bash", status = "pending", selected_option = 1,
			})
		end
		local shown = render()
		assert.is_truthy(text(shown):find("confirm", 1, true))
		hide()
		local hidden = render()
		assert.is_nil(text(hidden):find("confirm", 1, true))
		assert.is_nil(text(hidden):find("move", 1, true))
		assert.equals(#shown - 2, #hidden)
	end)

	it("keeps question progress but drops its key hints", function()
		local questions = {
			{ question = "First", custom = true, options = { { label = "One" }, { label = "Two" } } },
			{ question = "Second", options = { { label = "Three" } } },
		}
		hide()
		local rendered = text(require("opencode.ui.question_widget").get_lines_for_question("q",
			{ questions = questions }, { current_tab = 1, selections = {} }, "pending"))
		assert.is_truthy(rendered:find("0/2 answered", 1, true))
		assert.is_nil(rendered:find("select", 1, true))
		assert.is_nil(rendered:find("continue", 1, true))
		assert.is_nil(rendered:find("custom", 1, true))
	end)

	it("drops menu footers but keeps an explicit footer", function()
		hide()
		local menu = require("opencode.ui.menu")
		local ctx = menu.open({ items = { "First" }, searchable = true, refocus_chat = false })
		local ok, err = pcall(function()
			local lines = vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false)
			local frame = table.concat(lines, " ")
			assert.is_nil(frame:find("type to filter", 1, true))
			assert.is_nil(frame:find("close", 1, true))
			assert.equals(vim.api.nvim_win_get_height(ctx.frame.winid), #lines)
		end)
		ctx.close()
		if not ok then error(err) end
		ctx = menu.open({ items = { "First" }, refocus_chat = false, footer = "Custom help" })
		ok, err = pcall(function()
			local frame = table.concat(vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false), " ")
			assert.is_truthy(frame:find("Custom help", 1, true))
		end)
		ctx.close()
		if not ok then error(err) end
	end)

	it("drops the expand key from overflow notices", function()
		local tool_panel = require("opencode.ui.chat.tool_panel")
		assert.is_truthy(tool_panel.overflow_text(3):find("to expand", 1, true))
		hide()
		assert.equals("… (3 more lines)", tool_panel.overflow_text(3))
	end)

	it("leaves the help screen key list unchanged", function()
		hide()
		local popup = require("opencode.ui.chat.help").show({ keymaps = {} })
		local ok, err = pcall(function()
			local rendered = table.concat(vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false), "\n")
			assert.is_truthy(rendered:find(keymaps.label("chat", "focus_input"), 1, true))
		end)
		popup:close()
		if not ok then error(err) end
	end)
end)
