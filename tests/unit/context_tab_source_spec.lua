describe("editor source across chat tab creation", function()
	local context = require("opencode.context")
	local original_tab, source_tab, buffers, tabs
	local function buffer(text, ordinary)
		local buf = vim.api.nvim_create_buf(ordinary, not ordinary)
		buffers[#buffers + 1] = buf
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
		if ordinary then vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
		else vim.bo[buf].filetype = "opencode" end
		return buf
	end
	before_each(function()
		original_tab, buffers, tabs = vim.api.nvim_get_current_tabpage(), {}, {}
		vim.cmd("tabnew")
		source_tab = vim.api.nvim_get_current_tabpage()
		tabs[#tabs + 1] = source_tab
		vim.api.nvim_win_set_buf(0, buffer("source first pane", true))
		vim.cmd("vsplit")
		vim.api.nvim_win_set_buf(0, buffer("source second pane", true))
		context.setup()
	end)
	after_each(function()
		pcall(vim.api.nvim_del_augroup_by_name, "OpenCodeContext")
		for _, tab in ipairs(tabs) do
			if vim.api.nvim_tabpage_is_valid(tab) then
				vim.api.nvim_set_current_tabpage(tab)
				vim.cmd("tabclose!")
			end
		end
		vim.api.nvim_set_current_tabpage(original_tab)
		for _, buf in ipairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
		end
		context.clear()
	end)
	local function create_chat_tab()
		vim.cmd("tabnew")
		tabs[#tabs + 1] = vim.api.nvim_get_current_tabpage()
		vim.api.nvim_win_set_buf(0, buffer("chat", false))
	end
	it("preserves the original source window and both visible file panes", function()
		local source = context.source()
		local first, second, third = context.preserve_source(function()
			create_chat_tab()
			return "first", nil, "third"
		end)
		assert.same({ "first", nil, "third" }, { first, second, third })
		assert.same(source, context.source())
		local expanded = assert(context.expand("@visible", {}, assert(context.capture()))).text
		assert.is_truthy(expanded:find("source first pane", 1, true))
		assert.is_truthy(expanded:find("source second pane", 1, true))
	end)
	it("restores the source when tab creation fails", function()
		local source = context.source()
		local ok, err = pcall(context.preserve_source, function()
			create_chat_tab()
			error("failed while creating chat")
		end)
		assert.is_false(ok)
		assert.is_truthy(err:find("failed while creating chat", 1, true))
		assert.same(source, context.source())
	end)
end)
