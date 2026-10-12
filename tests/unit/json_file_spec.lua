describe("atomic JSON persistence", function()
	local json_file = require("opencode.util.json_file")
	local uv = vim.uv or vim.loop
	local directory, path
	before_each(function()
		directory = vim.fn.tempname()
		vim.fn.mkdir(directory, "p")
		path = directory .. "/data.json"
		vim.fn.writefile({ '{"original":true}' }, path, "b")
	end)
	after_each(function() vim.fn.delete(directory, "rf") end)

	for _, consumer in ipairs({
		{ name = "preferences", script = 'local owner = require("opencode.preferences").open(path); assert(not owner.save({ agent = "build" }))' },
		{ name = "prompt history", script = 'local history = require("opencode.ui.input.history"); history.configure({ history_file = path }); history.load(); history.add("Keep in memory")' },
		{ name = "palette statistics", script = 'require("opencode.state").set_config({ palette = { frecency_file = path } }); local palette = require("opencode.ui.palette"); palette.setup(); palette.register({ id = "test.fifo", title = "FIFO", category = "actions", run = function() end }); palette.trigger("test.fifo")' },
	}) do
		it("does not block or replace a FIFO when loading " .. consumer.name, function()
			assert(uv.fs_unlink(path))
			vim.fn.system({ "mkfifo", path })
			assert.equals(0, vim.v.shell_error)
			local script = 'local path = vim.env.OPENCODE_FIFO_JSON; local ok, err = pcall(function() ' .. consumer.script
				.. '; assert(vim.uv.fs_lstat(path).type == "fifo") end); '
				.. 'if not ok then vim.api.nvim_err_writeln(tostring(err)); vim.cmd("cquit 1") end; vim.cmd("qa!")'
			local result = vim.system({ "nvim", "--headless", "--noplugin", "-u", vim.fn.getcwd() .. "/tests/minimal_init.lua",
				"-i", "NONE", "-c", "lua " .. script,
			}, { env = { OPENCODE_FIFO_JSON = path } }):wait(1500)
			assert.equals(0, result.code, result.stderr)
			assert.equals("fifo", uv.fs_lstat(path).type)
		end)
	end

	it("reads regular JSON and symlinks while rejecting missing, corrupt, and directory paths", function()
		for _, value in ipairs({ { text = "猫", entries = { 1, 2 } }, false, 42, vim.NIL }) do
			assert.is_true(json_file.write(path, value))
			assert.same(value, json_file.read(path))
			assert.same(value, vim.json.decode(table.concat(vim.fn.readfile(path))))
			assert.same({ "data.json" }, vim.fn.readdir(directory))
		end
		local link = directory .. "/link.json"
		assert(uv.fs_symlink("data.json", link))
		assert.same(vim.NIL, json_file.read(link))
		vim.fn.writefile({ "{broken" }, path, "b")
		assert.is_nil(json_file.read(path))
		assert.is_nil(json_file.read(directory))
		assert.is_nil(json_file.read(path .. ".missing"))
	end)

	it("returns the read error and closes the file when reading fails", function()
		local original_open, closed = io.open, false
		io.open = function()
			return {
				read = function() return nil, "read failure" end,
				close = function() closed = true; return true end,
			}
		end
		local ok, value, err = pcall(json_file.read, path)
		io.open = original_open
		assert.is_true(ok)
		assert.is_nil(value)
		assert.equals("read failure", err)
		assert.is_true(closed)
	end)

	it("updates the target of a configured symbolic link without replacing the link", function()
		local link = directory .. "/link.json"
		assert.is_truthy(uv.fs_symlink("data.json", link))
		assert.is_true(json_file.write(link, { replacement = true }))
		assert.equals("link", uv.fs_lstat(link).type)
		assert.same({ replacement = true }, vim.json.decode(table.concat(vim.fn.readfile(path))))
		assert.same({ "data.json", "link.json" }, vim.fn.readdir(directory))
		assert.is_truthy(uv.fs_unlink(path))
		assert.is_true(json_file.write(link, { recreated = true }))
		assert.equals("link", uv.fs_lstat(link).type)
		assert.same({ recreated = true }, vim.json.decode(table.concat(vim.fn.readfile(path))))
	end)

	it("preserves the destination and cleans temporary files on write, close, or rename failure", function()
		for _, method in ipairs({ "fs_write", "fs_close", "fs_rename" }) do
			local original = uv[method]
			uv[method] = function(...)
				if method == "fs_write" then
					local fd, encoded, offset = ...
					return original(fd, encoded:sub(1, 1), offset)
				end
				if method == "fs_close" then original(...) end
				return nil, "disk failure"
			end
			local ok, saved = pcall(json_file.write, path, { replacement = true })
			uv[method] = original
			assert.is_true(ok)
			assert.is_false(saved)
			assert.equals('{"original":true}', table.concat(vim.fn.readfile(path)))
			assert.same({ "data.json" }, vim.fn.readdir(directory))
		end
	end)
end)
