local request = require("opencode.permission.request")

describe("permission request projection", function()
	local home, cwd, project
	before_each(function()
		home, cwd = vim.env.HOME, vim.fn.getcwd()
		vim.env.HOME = "/home/tester"
		project = vim.fn.tempname()
		vim.fn.mkdir(project, "p")
		vim.fn.chdir(project)
		project = vim.fn.getcwd()
	end)
	after_each(function()
		vim.env.HOME = home
		vim.fn.chdir(cwd)
	end)

	it("shows paths relative to the project, then to the home directory", function()
		assert.equals("lua/init.lua", request.display_path(project .. "/lua/init.lua"))
		assert.equals("~/work/*", request.display_path("/home/tester/work/*"))
		assert.equals("~", request.display_path("/home/tester"))
		assert.equals("/home/tester2/work", request.display_path("/home/tester2/work"))
		assert.equals("/srv/data/*", request.display_path("/srv/data/*"))
		-- A wildcard over the whole project keeps the directory it covers.
		assert.is_truthy(request.display_path(project .. "/*"):find("/%*$"))
	end)

	it("describes resources and saved patterns in display form, commands verbatim", function()
		local directory = {
			permission_type = "external_directory", patterns = { "/home/tester/work/*", " " },
			always = { "/home/tester/work/*" }, tool_input = { directory = "/home/tester/work" },
		}
		local before = vim.deepcopy(directory)
		local described = request.describe(directory)
		assert.same(before, directory)
		assert.equals("External directory", described.title)
		assert.is_false(described.shell)
		assert.same({ "~/work/*" }, described.resources)
		assert.same({ "~/work/*" }, described.always)
		assert.same({ { label = "Path", value = "~/work" } }, described.details)

		local shell = request.describe({
			permission_type = "shell", tool_name = "bash", patterns = { "ls /home/tester" }, always = { "ls *" },
			tool_input = { command = "ls /home/tester", workdir = "/home/tester/work" },
		})
		assert.is_true(shell.shell)
		assert.is_true(shell.own)
		assert.equals("Shell", shell.title)
		assert.equals("Shell", shell.tool)
		assert.is_false(described.own)
		assert.equals("Neovim Edit", request.describe({ permission_type = "neovim_edit" }).title)
		assert.equals("ls /home/tester", shell.command)
		assert.same({ "ls /home/tester" }, shell.resources)
		assert.same({ { label = "Path", value = "~/work" } }, shell.details)
	end)
end)
