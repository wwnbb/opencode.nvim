describe("server and write-only environment workflows", function()
	local state, actions, menu, pending, float = require("opencode.state"), require("opencode.actions"), require("opencode.ui.menu"), require("opencode.session.pending"), require("opencode.ui.float")
	local saved, picker, input, notices, request, calls, status
	before_each(function()
		state.reset(); pending.clear_all(); state.set_session("s", "Session"); state.upsert_session({ id = "s", location = { directory = "/project" } })
		saved = { open = menu.open, input = float.create_input_popup, notify = vim.notify,
			environment = actions.set_session_environment, status = actions.managed_server_status, manage = actions.manage_server }
		picker, input, request, calls, notices = nil, nil, nil, 0, {}
		menu.open = function(opts) picker = opts end
		float.create_input_popup = function(opts) input = opts end
		vim.notify = function(message) notices[#notices + 1] = message end
		actions.set_session_environment = function(id, variables, callback) request = { id = id, variables = variables, callback = callback } end
		status = { discovered = false, can_manage = false, url = "https://remote/base" }
		actions.managed_server_status = function() return vim.deepcopy(status) end
		actions.manage_server = function(_, callback) calls = calls + 1; callback() end
	end)
	after_each(function()
		menu.open, float.create_input_popup, vim.notify = saved.open, saved.input, saved.notify
		actions.set_session_environment, actions.managed_server_status, actions.manage_server = saved.environment, saved.status, saved.manage
		state.reset(); pending.clear_all()
	end)
	it("uses a secret input and confirms complete replacement including PATH", function()
		require("opencode.ui.palette.environment").show()
		assert.matches("Write%-only", picker.message); picker.on_select(picker.items[1]); assert.is_true(input.password)
		input.on_submit('{"PATH":"/bin","SECRET":"private-value"}')
		assert.matches("including PATH", picker.message); assert.is_nil(request)
		picker.on_select("Replace complete environment")
		assert.equals("s", request.id); assert.equals("private-value", request.variables.SECRET)
		request.callback(); assert.equals("Session environment replaced", notices[1])
	end)
	it("imports a local JSON map and offers empty replacement without claiming inheritance", function()
		local file = vim.fn.tempname(); vim.fn.writefile({ '{"PATH":"/bin"}' }, file)
		require("opencode.ui.palette.environment").show(); picker.on_select(picker.items[2]); input.on_submit(file); vim.fn.delete(file)
		picker.on_select("Replace complete environment"); assert.same({ PATH = "/bin" }, request.variables)
		require("opencode.ui.palette.environment").show(); assert.matches("Does not restore", picker.items[3].description)
		picker.on_select(picker.items[3]); picker.on_select("Replace complete environment"); assert.same(vim.empty_dict(), request.variables)
	end)
	it("rejects invalid values without logging secret JSON and guards late session changes", function()
		require("opencode.ui.palette.environment").show(); picker.on_select(picker.items[1]); input.on_submit('{"SECRET":123,"private-value":"x"}')
		assert.is_nil(request); assert.is_nil(table.concat(notices):find("private-value", 1, true))
		input.on_submit('{"PATH":"/bin"}'); state.set_session("other", "Other"); picker.on_select("Replace complete environment"); assert.is_nil(request)
	end)
	it("reports unsupported servers and rejects workspace-only shells", function()
		require("opencode.ui.palette.environment").show(); picker.on_select(picker.items[3]); picker.on_select("Replace complete environment")
		request.callback({ status = 404, message = "private-value" }); assert.matches("does not support", notices[1]); assert.is_nil(notices[1]:find("private-value", 1, true))
		state.upsert_session({ id = "s", location = { directory = "/project", workspaceID = "remote" } }); picker = nil
		require("opencode.ui.palette.environment").show(); assert.is_nil(picker); assert.matches("workspace", notices[2])
	end)
	it("hides native installer actions on remote hosts and rejects stale ownership", function()
		require("opencode.ui.palette.server").show(); assert.equals(1, #picker.items)
		status = { discovered = true, can_manage = true, pid = 42, url = "http://localhost:4096" }
		require("opencode.ui.palette.server").show(); assert.equals(3, #picker.items)
		local update = picker.items[3]; status.pid = 43; picker.on_select(update); assert.equals(0, calls); assert.matches("changed", notices[1])
		require("opencode.ui.palette.server").show(); picker.on_select(picker.items[3]); assert.equals(0, calls)
		picker.on_select("Continue"); assert.equals(1, calls)
	end)
end)
