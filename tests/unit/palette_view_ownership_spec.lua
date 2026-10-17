describe("palette pane ownership", function()
	local palette, registry = require("opencode.ui.palette"), require("opencode.command_registry")
	local app, sync = require("opencode.state"), require("opencode.sync")
	local views, actions = require("opencode.ui.chat.state"), require("opencode.actions")
	local menu = require("opencode.ui.menu")
	local panes, original_tab, tab, saved, commands, picker, selected, providers

	local function flush()
		local done = false
		vim.schedule(function() done = true end)
		assert.is_true(vim.wait(500, function() return done end, 5))
	end
	local function focus(view)
		app.set_session(view.session_id, view.session_id, { runtime = false })
		views.activate(view)
		vim.api.nvim_set_current_win(view.winid)
	end
	local function pane(id)
		local view = views.new()
		view.session_id, view.visible, view.winid = id, true, vim.api.nvim_get_current_win()
		view.bufnr = vim.api.nvim_create_buf(false, true)
		vim.bo[view.bufnr].filetype = "opencode"
		vim.api.nvim_win_set_buf(view.winid, view.bufnr)
		app.upsert_session({ id = id, directory = "/project", agent = "build", model = { providerID = "p", id = "one" } })
		panes[#panes + 1] = view
		return view
	end
	before_each(function()
		original_tab = vim.api.nvim_get_current_tabpage()
		saved = { config = app.get_config(), session = app.get_session(), menu = menu.open,
			providers = actions.get_config_providers, agents = actions.list_agents,
			model = actions.select_model, agent = actions.select_agent, variant = actions.select_variant }
		app.set_config(vim.tbl_deep_extend("force", vim.deepcopy(require("opencode.config").defaults), { palette = { frecency = false } }))
		providers = { { id = "p", models = { one = { name = "One", variants = { high = {} } }, two = { name = "Two" } } } }
		sync.handle_providers(providers)
		sync.handle_agents({ { id = "build", name = "Build" }, { id = "plan", name = "Plan" } })
		commands, selected, panes, picker = {}, {}, {}, nil
		menu.open = function(opts) picker = opts end
		actions.get_config_providers = function(callback) callback(nil, { providers = providers }) end
		actions.list_agents = function(callback) callback(nil) end
		for _, name in ipairs({ "model", "agent", "variant" }) do
			actions["select_" .. name] = function(value, opts) selected[#selected + 1] = { name = name, value = value, session_id = opts.session_id } end
		end
		local registrations = { register = function(command) commands[command.id] = command end }
		require("opencode.ui.palette.model").register(registrations)
		require("opencode.ui.palette.agent").register(registrations)
		vim.cmd("tabnew")
		tab = vim.api.nvim_get_current_tabpage()
		pane("palette-a")
		vim.cmd("vsplit")
		pane("palette-b")
		focus(panes[1])
	end)
	after_each(function()
		palette.hide()
		registry.unregister("test.pane-owner")
		menu.open = saved.menu
		actions.get_config_providers, actions.list_agents = saved.providers, saved.agents
		actions.select_model, actions.select_agent, actions.select_variant = saved.model, saved.agent, saved.variant
		for _, view in ipairs(panes) do views.remove(view) end
		vim.api.nvim_set_current_tabpage(tab)
		vim.cmd("tabclose!")
		vim.api.nvim_set_current_tabpage(original_tab)
		for _, view in ipairs(panes) do vim.api.nvim_buf_delete(view.bufnr, { force = true }) end
		require("opencode.session.selection").clear_all()
		sync.clear_all()
		app.set_session(saved.session.id, saved.session.name, { runtime = false })
		app.set_config(saved.config)
		flush()
	end)

	it("passes the original view through delayed palette execution", function()
		local received
		registry.register({ id = "test.pane-owner", title = "Unique owner command", category = "actions", run = function(context) received = context end })
		palette.show()
		local buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Unique owner command" })
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
		vim.fn.maparg("<CR>", "i", false, true).callback()
		focus(panes[2])
		flush()
		assert.equals(panes[1], received.view)
		assert.equals("palette-a", received.session_id)
		assert.equals(panes[1].generation, received.generation)
		assert.equals(panes[2].winid, vim.api.nvim_get_current_win())
	end)

	it("anchors a delayed palette opening to its captured pane", function()
		local context = palette.capture_context()
		focus(panes[2])
		palette.show(context)
		local frame = palette.get_winids()[3]
		assert.equals(panes[1].winid, vim.api.nvim_win_get_config(frame).win)
		palette.hide()
		assert.equals(panes[1].winid, vim.api.nvim_get_current_win())
	end)

	for _, case in ipairs({ { "model.switch", "model" }, { "agent.switch", "agent" }, { "model.variant", "variant" } }) do
		it("keeps " .. case[2] .. " selection bound to its original pane", function()
			commands[case[1]].run()
			assert.equals(panes[1], picker.context.view)
			local item = picker.items[#picker.items]
			focus(panes[2])
			picker.on_select(item)
			assert.equals(1, #selected)
			assert.equals(case[2], selected[1].name)
			assert.equals("palette-a", selected[1].session_id)
			views.remove(panes[1])
			picker.on_select(item)
			assert.equals(1, #selected)
		end)
	end

	it("does not open a delayed picker over another pane", function()
		local reply
		actions.get_config_providers = function(callback) reply = callback end
		commands["model.switch"].run()
		focus(panes[2])
		reply(nil, { providers = providers })
		assert.is_nil(picker)
	end)
end)
