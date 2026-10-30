-- An owned server ends with the Neovim that spawned it: on a normal exit even
-- when setup() never ran, and on SIGKILL through the watchdog.
local uv = vim.uv or vim.loop

describe("owned server exit", function()
	local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h")
	local directory, children, servers

	local function alive(pid)
		local ok, result = pcall(uv.kill, pid, 0)
		return ok and result == 0
	end

	local function wait_for(predicate, why)
		assert(vim.wait(10000, predicate, 20), why)
	end

	-- The fake server never prints its listening line, so it stays in startup
	-- (120s deadline) until something signals it.
	local function fake_server()
		local script = directory .. "/opencode"
		vim.fn.writefile({ "#!/bin/sh", "echo $$ > \"$OPENCODE_NVIM_FAKE_PID\"", "exec sleep 120" }, script)
		vim.fn.setfperm(script, "rwx------")
		return script
	end

	---@param lua string[] Child statements; `lifecycle` and `spawned()` are in scope.
	local function start_editor(lua)
		local pid_file = directory .. "/server.pid"
		local prelude = {
			"local lifecycle = require('opencode.lifecycle')",
			"local function spawned() return vim.wait(10000, function() return vim.fn.filereadable(vim.env.OPENCODE_NVIM_FAKE_PID) == 1 end, 20) end",
		}
		local child = vim.system({
			vim.v.progpath, "--headless", "--noplugin", "-u", tests_dir .. "/minimal_init.lua",
			"-c", "lua " .. table.concat(vim.list_extend(prelude, lua), "; "),
		}, { env = { OPENCODE_NVIM_FAKE_PID = pid_file, OPENCODE_NVIM_FAKE_SERVER = fake_server() } })
		children[#children + 1] = child
		wait_for(function() return vim.fn.filereadable(pid_file) == 1 and #vim.fn.readfile(pid_file) > 0 end,
			"editor did not spawn the fake server")
		local pid = assert(tonumber(vim.fn.readfile(pid_file)[1]))
		servers[#servers + 1] = pid
		assert.is_true(alive(pid), "fake server should be running")
		return child, pid
	end

	local options = {
		"lifecycle.opts.command = vim.env.OPENCODE_NVIM_FAKE_SERVER",
		"lifecycle.opts.use_shell_env = false",
		"lifecycle.opts.startup_timeout = 120000",
	}

	before_each(function()
		directory = vim.fn.tempname()
		vim.fn.mkdir(directory, "p")
		children, servers = {}, {}
	end)

	after_each(function()
		for _, child in ipairs(children) do pcall(child.kill, child, 9) end
		for _, pid in ipairs(servers) do
			if alive(pid) then pcall(uv.kill, pid, 9) end
		end
		vim.fn.delete(directory, "rf")
	end)

	it("stops a server spawned without setup() when Neovim quits", function()
		-- No watchdog: only the exit autocommand can stop this server.
		local child, pid = start_editor(vim.list_extend({
			"package.loaded['opencode.server_watchdog'] = { start = function() end }",
		}, vim.list_extend(vim.deepcopy(options), { "assert(lifecycle.start())", "assert(spawned())", "vim.cmd('qa!')" })))
		assert.equals(0, child:wait(10000).code)
		wait_for(function() return not alive(pid) end, "server outlived :qa!")
	end)

	it("stops the server when Neovim is killed", function()
		local child, pid = start_editor(vim.list_extend(vim.deepcopy(options), { "lifecycle.setup({})", "assert(lifecycle.start())" }))
		child:kill(9)
		child:wait(10000)
		wait_for(function() return not alive(pid) end, "server outlived a killed Neovim")
	end)

	it("keeps the server when shutdown_on_exit is off", function()
		local child, pid = start_editor(vim.list_extend(vim.deepcopy(options),
			{ "lifecycle.setup({ shutdown_on_exit = false })", "assert(lifecycle.start())", "assert(spawned())", "vim.cmd('qa!')" }))
		child:wait(10000)
		vim.wait(500)
		assert.is_true(alive(pid), "shutdown_on_exit = false should leave the server running")
	end)
end)
