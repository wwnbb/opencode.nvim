local state = require("opencode.state")
local config = require("opencode.config")
local menu = require("opencode.ui.menu")

local function mapping(buf, mode, key)
	local code = vim.api.nvim_replace_termcodes(key, true, true, true)
	for _, value in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
		if vim.api.nvim_replace_termcodes(value.lhs, true, true, true) == code then return value end
	end
end

describe("configurable menu and popup controls", function()
	local saved, ctx, field
	before_each(function() saved = state.get_config() end)
	after_each(function()
		if ctx then ctx.close(); ctx = nil end
		if field then field.close(); field = nil end
		require("opencode.ui.palette").hide()
		state.set_config(saved)
	end)

	it("inherits menu controls, prioritizes configured action keys and shows the resolved hints", function()
		state.set_config(config.merge({
			menu = { keymaps = { select = "L", close = false, next_normal = "J" } },
			model_menu = { keymaps = { favorite = { "k", "F" } } },
		}))
		local selected, favorites = nil, 0
		ctx = menu.open({ items = { "First", "Second" }, sort = false, refocus_chat = false,
			width = 110, keymap_scope = "model_menu", on_select = function(item) selected = item end,
			keys = { { action = "favorite", label = "favorite", handler = function() favorites = favorites + 1 end } },
		})
		local buf = ctx.popup.bufnr
		assert.is_nil(mapping(buf, "n", "<CR>"))
		assert.is_nil(mapping(buf, "n", "<Esc>"))
		assert.is_nil(mapping(buf, "n", "f"))
		assert.is_nil(mapping(buf, "n", "j"))
		mapping(buf, "n", "J").callback()
		assert.equals("Second", ctx.current())
		mapping(buf, "n", "k").callback()
		mapping(buf, "n", "F").callback()
		assert.equals(2, favorites)
		assert.equals("Second", ctx.current())
		local frame = table.concat(vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false), "\n")
		assert.is_truthy(frame:find("L:select", 1, true))
		assert.is_truthy(frame:find("k, F:favorite", 1, true))
		assert.is_nil((frame:find("k:up", 1, true)), frame .. " / " .. require("opencode.util.keymap").label("model_menu", "previous_normal"))
		assert.is_nil(frame:find("<Esc>", 1, true))
		mapping(buf, "n", "L").callback()
		assert.equals("Second", selected)
	end)

	it("disables numeric and toggle bindings and keeps external menu key definitions", function()
		state.set_config(config.merge({ menu = { keymaps = { option_1 = false, toggle = false } } }))
		local custom = 0
		ctx = menu.open({ items = { "One" }, multi_select = true, refocus_chat = false,
			keys = { { key = "z", label = "z:custom", handler = function() custom = custom + 1 end } },
		})
		assert.is_nil(mapping(ctx.popup.bufnr, "n", "1"))
		assert.is_nil(mapping(ctx.popup.bufnr, "n", "<Space>"))
		mapping(ctx.popup.bufnr, "n", "z").callback()
		assert.equals(1, custom)
	end)

	it("replaces all inherited aliases when a shared action is configured or disabled", function()
		state.set_config(config.merge({ menu = { keymaps = { close = false, next = "<C-f>", toggle = false } } }))
		ctx = menu.open({ items = { "First", "Second" }, searchable = true, multi_select = true, refocus_chat = false })
		for _, mode in ipairs({ "n", "i" }) do
			for _, key in ipairs({ "<C-c>", "<Down>" }) do assert.is_nil(mapping(ctx.input.bufnr, mode, key)) end
			assert.is_not_nil(mapping(ctx.input.bufnr, mode, "<C-f>"))
		end
		assert.is_nil(mapping(ctx.input.bufnr, "n", "<Esc>"))
		mapping(ctx.input.bufnr, "i", "<Esc>").callback()
		assert.is_true(vim.api.nvim_win_is_valid(ctx.popup.winid))
		for _, key in ipairs({ "q", "j", "<Space>" }) do assert.is_nil(mapping(ctx.input.bufnr, "n", key)) end
		for _, key in ipairs({ "<C-j>", "<C-n>", "<Tab>", "<C-Space>" }) do assert.is_nil(mapping(ctx.input.bufnr, "i", key)) end
	end)

	it("shows mode-specific action hints and returns to the same search from the content window", function()
		local renamed = 0
		ctx = menu.open({ items = { "First", "Second" }, searchable = true, refocus_chat = false,
			keymap_scope = "session_menu", confirm_label = "open", search_placeholder = "Filter sessions",
			keys = { { action = "rename", label = "rename", handler = function() renamed = renamed + 1 end } },
		})
		local function frame() return table.concat(vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false), " "):gsub("%s+", " ") end
		assert.is_truthy(frame():find("Search: type to filter", 1, true))
		assert.is_truthy(frame():find("<Down>:down", 1, true))
		assert.is_truthy(frame():find("<Esc>:actions", 1, true))
		assert.is_truthy(frame():find("<C-c>:close", 1, true))
		assert.is_nil(frame():find("r:rename", 1, true))
		vim.api.nvim_buf_set_lines(ctx.input.bufnr, 0, 1, false, { "Second" })
		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = ctx.input.bufnr })
		mapping(ctx.input.bufnr, "i", "<Esc>").callback()
		assert.equals(ctx.popup.winid, vim.api.nvim_get_current_win())
		assert.is_truthy(frame():find("Actions", 1, true))
		assert.is_truthy(frame():find("r:rename", 1, true))
		assert.is_truthy(frame():find("/, i:search", 1, true))
		assert.is_nil(frame():find("type to filter", 1, true))
		mapping(ctx.popup.bufnr, "n", "r").callback()
		assert.equals(1, renamed)
		mapping(ctx.popup.bufnr, "n", "/").callback()
		assert.equals(ctx.input.winid, vim.api.nvim_get_current_win())
		assert.same({ "Second" }, vim.api.nvim_buf_get_lines(ctx.input.bufnr, 0, 1, false))
		assert.equals("Second", ctx.current())
		assert.is_truthy(frame():find("Search: type to filter", 1, true))
	end)

	it("remaps and disables search mode controls and lets explicit close override Escape", function()
		state.set_config(config.merge({ menu = { keymaps = { search = "S", normal_mode = false, close_insert = "<Esc>" } } }))
		ctx = menu.open({ items = { "First" }, searchable = true, refocus_chat = false })
		assert.is_nil(mapping(ctx.input.bufnr, "n", "/"))
		assert.is_nil(mapping(ctx.popup.bufnr, "n", "i"))
		assert.is_not_nil(mapping(ctx.popup.bufnr, "n", "S"))
		local frame = table.concat(vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false), " ")
		assert.is_nil(frame:find(":actions", 1, true))
		assert.is_truthy(frame:find("<Esc>:close", 1, true))
		mapping(ctx.input.bufnr, "i", "<Esc>").callback()
		assert.is_false(vim.api.nvim_win_is_valid(ctx.popup.winid or -1))
		ctx = nil
		state.set_config(config.merge({ menu = { keymaps = { search = false, normal_mode = "<C-o>", close_insert = "<Esc>" } } }))
		ctx = menu.open({ items = { "First" }, searchable = true, refocus_chat = false })
		mapping(ctx.input.bufnr, "i", "<C-o>").callback()
		frame = table.concat(vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false), " ")
		assert.is_nil(frame:find(":search", 1, true))
		assert.is_nil(mapping(ctx.popup.bufnr, "n", "/"))
	end)

	it("keeps insert labels when a normal-only action displaces the same default key", function()
		state.set_config(config.merge({ session_menu = { keymaps = { rename = "<CR>" } } }))
		ctx = menu.open({ items = { "First" }, searchable = true, keymap_scope = "session_menu", refocus_chat = false,
			keys = { { action = "rename", label = "rename", handler = function() end } },
		})
		local function frame() return table.concat(vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false), " ") end
		assert.is_truthy(frame():find("<CR>:select", 1, true))
		mapping(ctx.input.bufnr, "i", "<Esc>").callback()
		assert.is_nil(frame():find("<CR>:select", 1, true))
		assert.is_truthy(frame():find("<CR>:rename", 1, true))
	end)

	it("uses popup controls for text fields without retaining the old bindings", function()
		state.set_config(config.merge({ popup = { keymaps = { submit = "<C-s>", cancel = false } } }))
		local submitted
		field = require("opencode.ui.float").create_input_popup({ default = "answer", on_submit = function(value) submitted = value end })
		local buf = vim.api.nvim_get_current_buf()
		assert.is_nil(mapping(buf, "i", "<CR>"))
		assert.is_nil(mapping(buf, "i", "<Esc>"))
		mapping(buf, "i", "<C-s>").callback()
		assert.equals("answer", submitted)
	end)

	it("inherits shared menu bindings in the command palette", function()
		state.set_config(config.merge({ menu = { keymaps = { select = "<C-s>", close = "<C-x>" } } }))
		local palette = require("opencode.ui.palette")
		palette.setup(); palette.show()
		local buf = vim.api.nvim_win_get_buf(palette.get_winids()[1])
		assert.is_nil(mapping(buf, "i", "<CR>"))
		assert.is_nil(mapping(buf, "i", "<Esc>"))
		assert.is_not_nil(mapping(buf, "i", "<C-s>"))
		mapping(buf, "i", "<C-x>").callback()
	end)

	it("handles configured password sequences and gives custom controls priority over defaults", function()
		state.set_config(config.merge({ password = { keymaps = {
			submit = { "zz", "<C-s>" }, cancel = "<F9>", backspace = "X", clear = "<CR>", paste = false,
		} } }))
		local submitted, displayed, buffer
		vim.defer_fn(function()
			buffer = vim.api.nvim_get_current_buf()
			displayed = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
			vim.api.nvim_input("ignored\rabcXqzz")
		end, 20)
		require("opencode.ui.float").create_input_popup({ password = true,
			on_submit = function(value) submitted = value end })
		assert.equals("abq", submitted)
		assert.is_truthy(displayed:find("zz / <C-s> submit", 1, true))
		assert.is_truthy(displayed:find("<F9>", 1, true))
		assert.is_false(vim.api.nvim_buf_is_valid(buffer))
	end)

	it("lets a custom password cancellation key replace default submission", function()
		state.set_config(config.merge({ password = { keymaps = { cancel = "<CR>" } } }))
		local cancelled, submitted
		vim.defer_fn(function() vim.api.nvim_input("secret\r") end, 20)
		require("opencode.ui.float").create_input_popup({ password = true,
			on_submit = function() submitted = true end, on_cancel = function() cancelled = true end })
		assert.is_true(cancelled)
		assert.is_nil(submitted)
	end)

	it("does not retain Ctrl-c cancellation when password cancellation is disabled", function()
		state.set_config(config.merge({ password = { keymaps = { cancel = false } } }))
		local reads, submitted, cancelled = 0, nil, nil
		local reader = require("luassert.stub")(vim.fn, "getcharstr", function()
			reads = reads + 1
			if reads == 1 then error("Vim:Interrupt") end
			return reads == 2 and "a" or "\r"
		end)
		local ok, err = pcall(require("opencode.ui.float").create_input_popup, { password = true,
			on_submit = function(value) submitted = value end, on_cancel = function() cancelled = true end })
		reader:revert()
		assert.is_true(ok, tostring(err))
		assert.equals("a", submitted)
		assert.is_nil(cancelled)
	end)
end)
