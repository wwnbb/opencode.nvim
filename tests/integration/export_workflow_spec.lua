local actions = require("opencode.actions")
local app_state = require("opencode.state")
local menu = require("opencode.ui.menu")
local projection = require("opencode.protocol.messages")
local registry = require("opencode.command_registry")
local slash = require("opencode.slash")
local sync = require("opencode.sync")

describe("complete session export workflow", function()
	local originals, requests, menus, format_calls, notices, initial_tab, views
	local session_id = "export-workflow"
	local transcript = {
		info = { id = session_id, title = "Server transcript",
			location = { directory = "/tmp/export" }, time = { created = 1, updated = 2 } },
		messages = { { id = "server-old", type = "user", text = "SERVER_OLD_MESSAGE" } },
	}

	local function choose(menu_options, value)
		for _, item in ipairs(menu_options.items or {}) do
			if type(item) == "table" and item.value == value then
				menu_options.on_select(item)
				return
			end
		end
		error("Missing export option " .. value .. ": " .. vim.inspect(menu_options.items))
	end

	local function label(menu_options, value)
		for _, item in ipairs(menu_options.items or {}) do
			if type(item) == "table" and item.value == value then return item.label end
		end
		return nil
	end

	local function run_slash(name)
		assert.is_true(slash.execute(slash.parse("/" .. name)))
	end

	before_each(function()
		initial_tab = vim.api.nvim_get_current_tabpage()
		app_state.reset(); sync.clear_all()
		app_state.set_config(vim.deepcopy(require("opencode.config").defaults))
		app_state.set_session(session_id, "Export")
		sync.handle_session_messages(session_id, projection.page(session_id, {
			{ id = "cached-recent", type = "user", text = "CACHE_ONLY_MESSAGE", time = { created = 2 } },
		}))
		originals = {
			export_session = actions.export_session,
			menu_open = menu.open,
			formatter = package.loaded["opencode.export"],
			notify = vim.notify,
			setreg = vim.fn.setreg,
			getreg = vim.fn.getreg,
		}
		requests, menus, format_calls, notices, views = {}, {}, {}, {}, {}
		actions.export_session = function(id, opts, callback)
			requests[#requests + 1] = { id = id, opts = vim.deepcopy(opts) }
			callback(nil, vim.deepcopy(transcript))
		end
		menu.open = function(options)
			menus[#menus + 1] = options
			return { close = function() end }
		end
		package.loaded["opencode.export"] = {
			markdown = function(data, opts)
				format_calls[#format_calls + 1] = { format = "markdown", data = vim.deepcopy(data), opts = vim.deepcopy(opts) }
				return "# " .. data.info.title .. "\n\n" .. data.messages[1].text .. "\n"
			end,
			json = function(data)
				format_calls[#format_calls + 1] = { format = "json", data = vim.deepcopy(data) }
				return vim.json.encode(data)
			end,
		}
		vim.notify = function(message) notices[#notices + 1] = tostring(message) end
		slash.register_defaults()
	end)

	after_each(function()
		for _, view in ipairs(views) do require("opencode.ui.chat.state").remove(view) end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= initial_tab and vim.api.nvim_tabpage_is_valid(tab) then
				vim.api.nvim_set_current_tabpage(tab)
				vim.cmd("tabclose!")
			end
		end
		if vim.api.nvim_tabpage_is_valid(initial_tab) then vim.api.nvim_set_current_tabpage(initial_tab) end
		actions.export_session = originals.export_session
		menu.open = originals.menu_open
		package.loaded["opencode.export"] = originals.formatter
		vim.notify = originals.notify
		vim.fn.setreg = originals.setreg
		vim.fn.getreg = originals.getreg
		app_state.reset(); sync.clear_all()
	end)
	it("exports the owning pane after focus changes and cancels its stale response after rebinding", function()
		local view = require("opencode.ui.chat.state").new()
		view.session_id, view.visible = session_id, true
		views[#views + 1] = view
		local context = { view = view, session_id = session_id }
		require("opencode.ui.export").show(context)
		app_state.set_session("other", "Other")
		choose(menus[1], "copy")
		assert.equals(session_id, requests[1].id)
		local reply
		actions.export_session = function(id, _, callback) assert.equals(session_id, id); reply = callback end
		require("opencode.ui.export").run({ action = "copy" }, context)
		view.generation = view.generation + 1
		reply(nil, transcript)
		assert.equals(1, #format_calls)
	end)

	it("routes /copy and palette Copy through the complete server export instead of the visible cache", function()
		assert.equals("session.copy", registry.get_slash("copy").id)
		run_slash("copy")
		assert.same({ id = session_id, opts = {} }, requests[1])
		assert.same({ thinking = true, tools = true }, format_calls[1].opts)
		assert.equals("SERVER_OLD_MESSAGE", format_calls[1].data.messages[1].text)
		assert.equals("# Server transcript\n\nSERVER_OLD_MESSAGE\n", vim.fn.getreg('"'))
		assert.is_nil(vim.fn.getreg('"'):find("CACHE_ONLY_MESSAGE", 1, true))

		assert.is_true(registry.run("session.copy", { source = "palette" }))
		assert.equals(2, #requests)
		assert.equals(2, #format_calls)
	end)

	it("reports a system clipboard failure while retaining the transcript in the unnamed register", function()
		vim.fn.setreg = function(register, content)
			if register == "+" then return 1 end
			return originals.setreg(register, content)
		end
		run_slash("copy")
		assert.equals("# Server transcript\n\nSERVER_OLD_MESSAGE\n", vim.fn.getreg('"'))
		assert.is_true(notices[#notices]:find("Could not copy to system clipboard", 1, true) ~= nil)
	end)

	it("detects a clipboard readback mismatch without losing the unnamed register", function()
		vim.fn.setreg = function(register, content)
			if register == "+" then return 0 end
			return originals.setreg(register, content)
		end
		vim.fn.getreg = function(register)
			if register == "+" then return "different content" end
			return originals.getreg(register)
		end
		run_slash("copy")
		assert.equals("# Server transcript\n\nSERVER_OLD_MESSAGE\n", vim.fn.getreg('"'))
		assert.is_true(notices[#notices]:find("Could not copy to system clipboard", 1, true) ~= nil)
	end)

	it("offers Markdown thinking and tools controls, then forwards their choices", function()
		assert.equals("session.export", registry.get_slash("export").id)
		run_slash("export")
		assert.equals(1, #menus)
		assert.equals("Format: Markdown", label(menus[1], "format"))
		assert.equals("Include thinking: Yes", label(menus[1], "thinking"))
		assert.equals("Include tools: Yes", label(menus[1], "tools"))
		assert.equals("Copy export", label(menus[1], "copy"))
		assert.equals("Open export buffer", label(menus[1], "buffer"))

		choose(menus[1], "thinking")
		assert.equals("Include thinking: No", label(menus[2], "thinking"))
		choose(menus[2], "tools")
		assert.equals("Include tools: No", label(menus[3], "tools"))
		choose(menus[3], "copy")
		assert.same({ id = session_id, opts = {} }, requests[1])
		assert.same({ thinking = false, tools = false }, format_calls[1].opts)
		assert.equals("SERVER_OLD_MESSAGE", format_calls[1].data.messages[1].text)
	end)

	for _, target in ipairs({ "another session", "no active session" }) do
		it("exports the opening session after switching to " .. target, function()
			require("opencode.ui.export").show()
			app_state.set_session(target == "another session" and "export-other" or nil, "Other")
			choose(menus[1], "format")
			choose(menus[2], "copy")
			assert.same({ { id = session_id, opts = { sanitize = false } } }, requests)
		end)
	end

	for _, invalidation in ipairs({ "connection", "session" }) do
		it("cancels all export menu choices after " .. invalidation .. " invalidation", function()
			local pending = require("opencode.session.pending")
			for _, choice in ipairs({ "format", "copy", "buffer" }) do
				require("opencode.ui.export").show()
				local count = #menus
				if invalidation == "connection" then pending.invalidate() else pending.clear_session(session_id) end
				choose(menus[count], choice)
				assert.same({}, requests)
				assert.same({}, format_calls)
				assert.equals(count, #menus)
			end
		end)
	end

	it("sends JSON sanitize to the server and copies the returned object", function()
		require("opencode.ui.export").show()
		choose(menus[1], "format")
		assert.equals("Format: JSON", label(menus[2], "format"))
		assert.is_nil(label(menus[2], "thinking"))
		assert.is_nil(label(menus[2], "tools"))
		assert.equals("Sanitize sensitive data: No", label(menus[2], "sanitize"))
		choose(menus[2], "sanitize")
		assert.equals("Sanitize sensitive data: Yes", label(menus[3], "sanitize"))
		choose(menus[3], "copy")
		assert.same({ id = session_id, opts = { sanitize = true } }, requests[1])
		assert.equals("json", format_calls[1].format)
		assert.same(transcript, vim.json.decode(vim.fn.getreg('"')))
	end)

	it("opens the complete Markdown export in an editable buffer that can be saved", function()
		require("opencode.ui.export").show()
		choose(menus[1], "buffer")
		assert.same({ id = session_id, opts = {} }, requests[1])
		assert.equals(2, #vim.api.nvim_list_tabpages())
		local bufnr = vim.api.nvim_get_current_buf()
		assert.equals("", vim.api.nvim_buf_get_name(bufnr))
		assert.equals("markdown", vim.bo[bufnr].filetype)
		assert.is_true(vim.bo[bufnr].modifiable)
		assert.is_true(vim.bo[bufnr].modified)
		assert.same({ "# Server transcript", "", "SERVER_OLD_MESSAGE" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		local path = vim.fn.tempname() .. ".md"
		vim.cmd("silent write " .. vim.fn.fnameescape(path))
		assert.same({ "# Server transcript", "", "SERVER_OLD_MESSAGE" }, vim.fn.readfile(path))
		vim.fn.delete(path)
	end)
end)
