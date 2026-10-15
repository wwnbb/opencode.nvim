describe("catalog actions across project and connection changes", function()
	local actions = require("opencode.actions")
	local client = require("opencode.client")
	local lifecycle = require("opencode.lifecycle")
	local state = require("opencode.state")
	local sync = require("opencode.sync")
	local pending = require("opencode.session.pending")
	local menu = require("opencode.ui.menu")
	local saved, scheduled, reply, request_opts, selected

	local cases = {
		{ method = "list_agents", domain = "agents", data = { { id = "agent-a", name = "Agent A" } }, read = sync.get_agents },
		{ method = "get_config_providers", domain = "providers",
			data = { providers = { { id = "provider-a", models = {} } }, default = { ["provider-a"] = "model-a" } }, read = sync.get_providers },
	}

	local function select_project(directory)
		state.upsert_session({ id = directory, title = directory, directory = directory })
		state.set_session(directory, directory)
		sync.select_catalog_location(directory)
	end

	local function flush()
		while #scheduled > 0 do table.remove(scheduled, 1)() end
	end

	before_each(function()
		state.reset()
		sync.clear_all()
		pending.clear_all()
		saved = { ensure = lifecycle.ensure_connected, schedule = vim.schedule, menu = menu.open,
			agent = actions.select_agent, model = actions.select_model }
		selected = {}
		actions.select_agent = function(id) selected[#selected + 1] = id end
		actions.select_model = function(model) selected[#selected + 1] = model end
		for _, case in ipairs(cases) do
			saved[case.method] = client[case.method]
			client[case.method] = function(callback, opts) reply, request_opts = callback, opts end
		end
		scheduled, reply, request_opts = {}, nil, nil
		lifecycle.ensure_connected = function(callback) callback() end
		vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
		select_project("/project-a")
	end)

	after_each(function()
		for _, case in ipairs(cases) do client[case.method] = saved[case.method] end
		lifecycle.ensure_connected, vim.schedule = saved.ensure, saved.schedule
		menu.open = saved.menu
		actions.select_agent, actions.select_model = saved.agent, saved.model
		state.reset()
		sync.clear_all()
		pending.clear_all()
	end)

	it("opens the model picker in the guarded action callback", function()
		local command, opened
		require("opencode.ui.palette.model").register({ register = function(definition)
			if definition.id == "model.switch" then command = definition end
		end })
		menu.open = function(opts) opened = opts end
		command.run()
		reply(nil, { providers = { { id = "provider-a", models = { ["model-a"] = { name = "Model A" } } } }, default = {} })
		table.remove(scheduled, 1)()
		assert.is_not_nil(opened)
		assert.equals("[provider-a] Model A", opened.items[1].label)
		assert.same({}, scheduled)
	end)

	local pickers = {
		{ module = "agent", id = "agent.switch", data = cases[1].data, value = "agent-a" },
		{ module = "model", id = "model.switch", data = { providers = {
			{ id = "provider-a", models = { ["model-a"] = { name = "Model A" } } },
		}, default = {} }, value = { providerID = "provider-a", modelID = "model-a" } },
	}
	local function open_picker(picker)
		local command
		require("opencode.ui.palette." .. picker.module).register({ register = function(record)
			if record.id == picker.id then command = record end
		end })
		command.run()
	end
	local function switch_tab()
		state.upsert_session({ id = "same-project-tab", directory = "/project-a" })
		state.set_session("same-project-tab", "Other")
	end
	for _, picker in ipairs(pickers) do
		it(picker.module .. " picker allows its catalog to initialize while connecting", function()
			local opened
			menu.open = function(opts) opened = opts end
			sync.select_catalog_location(nil)
			open_picker(picker)
			sync.select_catalog_location("/project-a")
			reply(nil, picker.data); flush()
			assert.is_not_nil(opened)
			opened.on_select(opened.items[1])
			assert.same({ picker.value }, selected)
		end)
		for _, invalidation in ipairs({ "connection", "tab", "closed session", "project", "none" }) do
			it(picker.module .. " picker owns its selection across " .. invalidation .. " changes", function()
				local opened
				menu.open = function(opts) opened = opts end
				open_picker(picker)
				reply(nil, picker.data); flush()
				assert.is_not_nil(opened)
				if invalidation == "connection" then pending.invalidate()
				elseif invalidation == "tab" then switch_tab()
				elseif invalidation == "closed session" then pending.clear_session("/project-a")
				elseif invalidation == "project" then
					state.upsert_session({ id = "/project-a", directory = "/project-b" })
					sync.select_catalog_location("/project-b")
				end
				opened.on_select(opened.items[1])
				assert.same(invalidation == "none" and { picker.value } or {}, selected)
			end)
		end
		it(picker.module .. " picker does not open when its loading session changed within the same project", function()
			local opened = false
			menu.open = function() opened = true end
			open_picker(picker)
			switch_tab()
			reply(nil, picker.data); flush()
			assert.is_false(opened)
		end)
	end

	it("does not start catalog requests on a replacement connection", function()
		local connected = {}
		lifecycle.ensure_connected = function(callback) connected[#connected + 1] = callback end
		for _, case in ipairs(cases) do actions[case.method](function() error("stale callback") end) end
		pending.invalidate()
		for _, callback in ipairs(connected) do callback() end
		assert.is_nil(reply)
	end)

	it("loads an explicitly requested provider catalog independently of the active chat directory", function()
		local connected, completed = nil, 0
		local opts = { directory = "/settings-project/" }
		lifecycle.ensure_connected = function(callback) connected = callback end
		actions.get_config_providers(function(err, data)
			assert.is_nil(err)
			assert.same(cases[2].data, data)
			completed = completed + 1
		end, opts)
		select_project("/project-b")
		connected()
		assert.same({ directory = "/settings-project" }, request_opts)
		assert.same({ directory = "/settings-project/" }, opts)
		reply(nil, cases[2].data); flush()
		assert.equals(1, completed)
		assert.same({}, sync.get_providers())
		assert.same(cases[2].data, sync.get_location_catalog("/settings-project", "providers").data)
	end)

	it("keeps explicit provider requests guarded against replacement connections", function()
		local connected, completed = nil, 0
		lifecycle.ensure_connected = function(callback) connected = callback end
		local function request()
			actions.get_config_providers(function() completed = completed + 1 end, { directory = "/settings-project" })
		end
		request()
		pending.invalidate(); connected()
		assert.is_nil(reply)
		request(); connected()
		reply(nil, cases[2].data)
		pending.invalidate(); flush()
		assert.equals(0, completed)
		assert.is_nil(sync.get_location_catalog("/settings-project", "providers"))
	end)

	for _, case in ipairs(cases) do
		it(case.domain .. " load and publish the active session's catalog", function()
			local completed = 0
			actions[case.method](function(err, data)
				assert.is_nil(err)
				assert.same(case.data, data)
				completed = completed + 1
			end)
			assert.same({ directory = "/project-a" }, request_opts)
			reply(nil, case.data)
			flush()
			assert.equals(1, completed)
			assert.is_true(#case.read() > 0)
			assert.same(case.data, sync.get_location_catalog("/project-a", case.domain).data)
		end)

		it(case.domain .. " keep delayed results in their original project", function()
			local connected, completed = nil, 0
			lifecycle.ensure_connected = function(callback) connected = callback end
			actions[case.method](function() completed = completed + 1 end)
			select_project("/project-b")
			connected()
			assert.same({ directory = "/project-a" }, request_opts)
			reply(nil, case.data)
			flush()
			assert.same({}, case.read())
			assert.same(case.data, sync.get_location_catalog("/project-a", case.domain).data)
			assert.equals(0, completed)
		end)

		it(case.domain .. " ignore results queued before the connection changes", function()
			local completed = 0
			actions[case.method](function() completed = completed + 1 end)
			reply(nil, case.data)
			pending.invalidate()
			sync.clear_all()
			flush()
			assert.same({}, case.read())
			assert.is_nil(sync.get_location_catalog("/project-a", case.domain))
			assert.equals(0, completed)
		end)
	end
end)
