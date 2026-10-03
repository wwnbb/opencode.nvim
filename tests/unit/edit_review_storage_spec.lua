describe("opencode edit review storage", function()
	local changes = require("opencode.artifact.changes")
	local edits = require("opencode.edit.state")
	local root
	local original_open
	local original_remove
	local modified_buf
	local original_time, original_fs_write, original_fs_close
	local original_fs_rename
	local original_fs_fsync
	local original_fs_open, original_fs_ftruncate
	local original_has, original_system
	local original_fn_system
	local function write(path, content)
		local file = assert(io.open(path, "wb"))
		assert(file:write(content))
		assert(file:close())
	end
	local function read(path)
		local file = assert(io.open(path, "rb"))
		local content = file:read("*all")
		file:close()
		return content
	end
	before_each(function()
		original_open = io.open
		original_remove = os.remove
		original_time, original_fs_write, original_fs_close = os.time, vim.uv.fs_write, vim.uv.fs_close
		original_fs_rename = vim.uv.fs_rename
		original_fs_fsync = vim.uv.fs_fsync
		original_fs_open, original_fs_ftruncate = vim.uv.fs_open, vim.uv.fs_ftruncate
		original_has, original_system = vim.fn.has, vim.system
		original_fn_system = vim.fn.system
		root = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		changes.setup({ auto_backup = false })
		changes.clear()
		edits.clear_all()
	end)
	after_each(function()
		io.open = original_open
		os.remove = original_remove
		os.time, vim.uv.fs_write, vim.uv.fs_close = original_time, original_fs_write, original_fs_close
		vim.uv.fs_rename = original_fs_rename
		vim.uv.fs_fsync = original_fs_fsync
		vim.uv.fs_open, vim.uv.fs_ftruncate = original_fs_open, original_fs_ftruncate
		vim.fn.has, vim.system = original_has, original_system
		vim.fn.system = original_fn_system
		if modified_buf and vim.api.nvim_buf_is_valid(modified_buf) then vim.api.nvim_buf_delete(modified_buf, { force = true }) end
		modified_buf = nil
		edits.clear_all()
		changes.clear()
		changes.setup({})
		vim.uv.fs_chmod(root, 493)
		vim.fn.delete(root, "rf")
	end)

	it("keeps the same default confirmation rules through public setup", function()
		local config = require("opencode.config")
		for _, opts in ipairs({ { auto_backup = false }, config.merge({ changes = { auto_backup = false } }).changes }) do
			changes.setup(opts)
			for _, filename in ipairs({ "go.mod", "package.json.backup", "Cargo.toml.backup", ".env", "config.conf" }) do
				local id = changes.add_change(root .. "/" .. filename, "", "proposal", { file_type = "add" })
				assert.is_true(changes.get(id).requires_confirm, filename)
				local ok, err = changes.accept(id)
				assert.is_false(ok)
				assert.equals("Confirmation required", err)
				assert.is_nil(vim.uv.fs_lstat(root .. "/" .. filename))
			end
			local ordinary = changes.add_change(root .. "/ordinary.lua", "", "proposal")
			assert.is_false(changes.get(ordinary).requires_confirm)
		end
	end)

	it("snapshots custom confirmation patterns without extending or aliasing them", function()
		local config = require("opencode.config")
		local before = vim.deepcopy(config.defaults.changes)
		local opts = { auto_backup = false, file_patterns_to_confirm = { "private%.txt$" } }
		changes.setup(opts)
		opts.file_patterns_to_confirm[1] = "never-match"
		local id = changes.add_change(root .. "/private.txt", "", "proposal")
		assert.is_true(changes.get(id).requires_confirm)
		assert.is_false(changes.get(changes.add_change(root .. "/go.mod", "", "proposal")).requires_confirm)
		assert.same(before, config.defaults.changes)
	end)

	it("creates private backups with the exact original bytes", function()
		local path, backup_dir = root .. "/.env", root .. "/backups"
		changes.setup({ auto_backup = true, backup_dir = backup_dir })
		for _, original in ipairs({ "", "\239\187\191TOKEN=example\r\n\0tail" }) do
			write(path, original)
			assert.equals(1, vim.fn.setfperm(path, "rw-------"))
			local backup = changes.get(changes.add_change(path, original, "changed")).backup_path
			assert.is_string(backup)
			assert.equals(original, read(backup))
			assert.equals("rw-------", vim.fn.getfperm(backup))
		end
	end)

	it("does not read a symbolic link while creating a review backup", function()
		local target, path = root .. "/private", root .. "/link"
		write(target, "private original")
		assert(vim.uv.fs_symlink(target, path))
		changes.setup({ auto_backup = true, backup_dir = root .. "/backups" })
		local id = changes.add_change(path, "before", "proposal")
		assert.is_nil(changes.get(id).backup_path)
		assert.equals("private original", read(target))
		assert.equals("link", vim.uv.fs_lstat(path).type)
	end)

	it("does not block on a FIFO while creating or accepting a review", function()
		local path = root .. "/pipe"
		vim.fn.system({ "mkfifo", path })
		assert.equals(0, vim.v.shell_error)
		assert.equals("fifo", vim.uv.fs_lstat(path).type)
		local script = 'local changes = require("opencode.artifact.changes"); '
			.. 'changes.setup({ auto_backup = true, backup_dir = vim.env.OPENCODE_BACKUP_DIR }); '
			.. 'local id = changes.add_change(vim.env.OPENCODE_FIFO_PATH, "before", "proposal"); '
			.. 'assert(changes.get(id).backup_path == nil); '
			.. 'assert(not changes.accept(id, { force = true })); '
			.. 'assert(vim.uv.fs_lstat(vim.env.OPENCODE_FIFO_PATH).type == "fifo"); vim.cmd("qa!")'
		local result = vim.system({ "nvim", "--headless", "-u", "NONE", "-i", "NONE",
			"--cmd", "set rtp+=" .. vim.fn.getcwd(), "-c", "lua " .. script,
		}, { env = { OPENCODE_FIFO_PATH = path, OPENCODE_BACKUP_DIR = root .. "/backups" } }):wait(1500)
		assert.equals(0, result.code, result.stderr)
	end)

	it("keeps an earlier backup when a change ID is reused", function()
		os.time = function() return 1234 end
		local path = root .. "/file"
		write(path, "first original")
		changes.setup({ auto_backup = true, backup_dir = root .. "/backups" })
		local id = changes.add_change(path, "first original", "proposal")
		local backup = changes.get(id).backup_path
		changes.clear()
		write(path, "second original")
		local next_id = changes.add_change(path, "second original", "proposal")
		assert.equals(id, next_id)
		local next_backup = changes.get(next_id).backup_path
		assert.is_string(next_backup)
		assert.is_not.equals(backup, next_backup)
		assert.equals("first original", read(backup))
		assert.equals("second original", read(next_backup))
	end)

	it("does not follow an existing link at the backup destination", function()
		os.time = function() return 1234 end
		local path, target, backup_dir = root .. "/file", root .. "/target", root .. "/backups"
		write(path, "original"); write(target, "preserved")
		vim.fn.mkdir(backup_dir, "p")
		local backup = backup_dir .. "/file_change_1234_1.bak"
		assert(vim.uv.fs_symlink(target, backup))
		changes.setup({ auto_backup = true, backup_dir = backup_dir })
		local id = changes.add_change(path, "original", "proposal")
		local created = changes.get(id).backup_path
		assert.is_string(created)
		assert.is_not.equals(backup, created)
		assert.equals("original", read(created))
		assert.equals("preserved", read(target))
		assert.equals("link", vim.uv.fs_lstat(backup).type)
	end)

	for _, failure in ipairs({ "write", "close" }) do
		it("removes an incomplete backup after a " .. failure .. " failure", function()
			local path, backup_dir = root .. "/file", root .. "/backups"
			write(path, "original")
			changes.setup({ auto_backup = true, backup_dir = backup_dir })
			if failure == "write" then
				vim.uv.fs_write = function(fd, bytes, offset) return original_fs_write(fd, bytes:sub(1, 1), offset) end
			else
				vim.uv.fs_close = function(fd) original_fs_close(fd); return nil, "close failure" end
			end
			local id = changes.add_change(path, "original", "proposal")
			assert.is_nil(changes.get(id).backup_path)
			assert.equals("original", read(path))
			assert.same({}, vim.fn.readdir(backup_dir))
		end)
	end

	it("keeps the review available if the backup directory cannot be created", function()
		local path, backup_dir = root .. "/file", root .. "/backups"
		write(path, "original"); write(backup_dir, "occupied")
		changes.setup({ auto_backup = true, backup_dir = backup_dir })
		local ok, id = pcall(changes.add_change, path, "original", "proposal")
		assert.is_true(ok)
		assert.is_nil(changes.get(id).backup_path)
		assert.equals(changes.STATUS.PENDING, changes.get(id).status)
		assert.equals("original", read(path))
		assert.equals("occupied", read(backup_dir))
	end)

	it("can accept every file in a patch larger than the history budget", function()
		local files = {}
		for index = 1, 101 do
			files[index] = { filePath = root .. "/" .. index, before = "", after = "new\n", type = "add" }
		end
		edits.add_edit("large", "session", files)
		assert.is_true(edits.accept_all("large"))
		assert.equals("all_accepted", edits.get_resolution("large"))
		for _, file in ipairs(files) do assert.equals("new\n", read(file.filePath)) end
	end)

	it("trims resolved history without evicting an older pending review", function()
		changes.setup({ auto_backup = false, max_changes = 2 })
		local pending = changes.add_change(root .. "/pending", "", "proposed", { file_type = "add" })
		local resolved = {}
		for index = 1, 4 do
			resolved[index] = changes.add_change(root .. "/resolved" .. index, "", "value")
			assert.is_true(changes.resolve_manually(resolved[index]))
		end
		assert.is_not_nil(changes.get(pending))
		assert.equals(3, #changes.get_all())
		assert.is_nil(changes.get(resolved[1]))
		assert.is_not_nil(changes.get(resolved[4]))
		assert.is_true(changes.accept(pending))
		assert.equals("proposed", read(root .. "/pending"))
	end)

	for _, content in ipairs({ "", "original\n" }) do
		it("deletes an accepted file with content " .. vim.inspect(content), function()
			local path = root .. "/delete"
			write(path, content)
			edits.add_edit("delete", "session", { { filePath = path, before = content, after = "", type = "delete" } })
			assert.is_true(edits.accept_file("delete", 1))
			assert.equals(0, vim.fn.filereadable(path))
			assert.equals("all_accepted", edits.get_resolution("delete"))
		end)
	end

	it("rejecting a deletion restores an already removed file", function()
		local path = root .. "/restore"
		write(path, "original\n")
		edits.add_edit("restore", "session", { { filePath = path, before = "original\n", after = "", type = "delete" } })
		assert(os.remove(path))
		assert.is_true(edits.reject_file("restore", 1))
		assert.equals("original\n", read(path))
	end)

	it("restores the original BOM independently from the proposed BOM", function()
		local path = root .. "/bom"
		write(path, "before\n")
		edits.add_edit("bom", "session", { {
			filePath = path, before = "before\n", after = "after\n", type = "update", bom = true, before_bom = false,
		} })
		write(path, "\xEF\xBB\xBFafter\n")
		assert.is_true(edits.reject_file("bom", 1))
		assert.equals("before\n", read(path))
	end)

	for _, action in ipairs({ "accept", "reject" }) do
		it("retries a failed " .. action .. " without losing the review to history trimming", function()
			local path = root .. "/retry"
			write(path, "before\n")
			local estate = edits.add_edit("retry", "session", {
				{ filePath = path, before = "before\n", after = "after\n", type = "update" },
			})
			if action == "reject" then write(path, "after\n") end
			vim.uv.fs_open = function(name, mode, permissions)
				if mode == "wx" then return nil, "temporary write failure" end
				return original_fs_open(name, mode, permissions)
			end
			local ok, err = edits[action .. "_file"]("retry", 1)
			assert.is_false(ok)
			assert.equals("temporary write failure", err)
			assert.equals("pending", estate.files[1].status)
			vim.uv.fs_open = original_fs_open
			changes.setup({ auto_backup = false, max_changes = 1 })
			for index = 1, 3 do
				local id = changes.add_change(root .. "/history" .. index, "", "value")
				assert.is_true(changes.resolve_manually(id))
			end
			assert.equals(1, #changes.get_pending())
			assert.is_true(edits[action .. "_file"]("retry", 1))
			assert.equals(action == "accept" and "after\n" or "before\n", read(path))
			assert.equals(action == "accept" and "accepted" or "rejected", estate.files[1].status)
		end)
	end

	for _, kind in ipairs({ "update", "add", "delete" }) do
		it("preserves unsaved buffers while accepting a local " .. kind, function()
			local path = root .. "/protected"
			local before, after = kind == "add" and "" or "before\n", kind == "delete" and "" or "after\n"
			if kind ~= "add" then write(path, before) end
			local estate = edits.add_edit("protected", "session", {
				{ filePath = path, before = before, after = after, type = kind },
			})
			modified_buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_name(modified_buf, path)
			vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, { "unsaved manual edit" })
			local ok, err = edits.accept_file("protected", 1)
			assert.is_false(ok)
			assert.is_truthy(err:find("unsaved buffer changes", 1, true))
			if kind == "add" then assert.is_nil(vim.uv.fs_lstat(path)) else assert.equals(before, read(path)) end
			assert.same({ "unsaved manual edit" }, vim.api.nvim_buf_get_lines(modified_buf, 0, -1, false))
			assert.equals("pending", estate.files[1].status)
			assert.equals(changes.STATUS.PENDING, changes.get(estate.files[1].change_id).status)
			vim.api.nvim_buf_delete(modified_buf, { force = true }); modified_buf = nil
			assert.is_true(edits.accept_file("protected", 1))
			if kind == "delete" then assert.is_nil(vim.uv.fs_lstat(path)) else assert.equals(after, read(path)) end
		end)
	end

	it("preserves changed disk snapshots when accepting directly unless forced", function()
		for _, case in ipairs({
			{ kind = "update", disk = "manual edit" },
			{ kind = "update" },
			{ kind = "update", disk = "before\r\n", before = "before\n" },
			{ kind = "update", disk = "\239\187\191before" },
			{ kind = "add", disk = "manual new file" },
			{ kind = "delete", disk = "manual edit" },
		}) do
			local path = root .. "/conflict"
			vim.fn.delete(path)
			if case.disk then write(path, case.disk) end
			local id = changes.add_change(path, case.before or "before", "proposal", { file_type = case.kind })
			local ok, err = changes.accept(id)
			assert.is_false(ok, vim.inspect(case))
			assert.is_truthy(err:find("File changed since review", 1, true))
			assert.equals(changes.STATUS.PENDING, changes.get(id).status)
			if case.disk then assert.equals(case.disk, read(path)) else assert.is_nil(vim.uv.fs_lstat(path)) end
			assert.is_true(changes.accept(id, { force = true }))
			if case.kind == "delete" then assert.is_nil(vim.uv.fs_lstat(path)) else assert.equals("proposal", read(path)) end
		end
	end)

	it("protects unsaved buffers even when the change is accepted directly with force", function()
		local path = root .. "/direct"
		write(path, "before")
		local id = changes.add_change(path, "before", "after")
		modified_buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(modified_buf, path)
		vim.api.nvim_buf_set_lines(modified_buf, 0, -1, false, { "unsaved manual edit" })
		local ok, err = changes.accept(id, { force = true })
		assert.is_false(ok)
		assert.is_truthy(err:find("unsaved buffer changes", 1, true))
		assert.equals("before", read(path))
		assert.equals(changes.STATUS.PENDING, changes.get(id).status)
	end)

	it("protects replacement symbolic links when accepting changes directly", function()
		for _, kind in ipairs({ "update", "add", "delete" }) do
			for _, force in ipairs({ false, true }) do
				local path, target = root .. "/direct-link", root .. "/target"
				write(target, "private original")
				local id = changes.add_change(path, "before", "proposal", { file_type = kind })
				assert(vim.uv.fs_symlink(target, path))
				local ok, err = changes.accept(id, { force = force })
				assert.is_false(ok)
				assert.is_truthy(err:find("link", 1, true))
				assert.equals("private original", read(target))
				assert.equals("link", vim.uv.fs_lstat(path).type)
				assert.equals(changes.STATUS.PENDING, changes.get(id).status)
				assert(os.remove(path))
			end
		end
	end)

	it("preserves a replacement directory when accepting a deletion directly", function()
		local path = root .. "/directory"
		local id = changes.add_change(path, "before", "", { file_type = "delete" })
		vim.fn.mkdir(path)
		local ok, err = changes.accept(id, { force = true })
		assert.is_false(ok)
		assert.is_truthy(err:find("directory", 1, true))
		assert.equals("directory", vim.uv.fs_lstat(path).type)
		assert.equals(changes.STATUS.PENDING, changes.get(id).status)
	end)

	it("returns an inspection error when a parent path is occupied by a file", function()
		local parent = root .. "/occupied"
		write(parent, "preserved")
		local id = changes.add_change(parent .. "/child", "", "proposal", { file_type = "add" })
		local called, ok, err = pcall(changes.accept, id)
		assert.is_true(called)
		assert.is_false(ok)
		assert.is_truthy(err:find("ENOTDIR", 1, true))
		assert.equals("preserved", read(parent))
		assert.equals(changes.STATUS.PENDING, changes.get(id).status)
	end)

	for _, action in ipairs({ "accept", "reject" }) do
		it("returns a retryable error when " .. action .. " cannot create a parent directory", function()
			local path = root .. "/parent/file"
			local kind = action == "accept" and "add" or "delete"
			local id = changes.add_change(path, "original", "proposal", { file_type = kind })
			assert(vim.uv.fs_chmod(root, 365))
			assert.is_false(vim.uv.fs_access(root, "W"))
			local called, ok, err = pcall(changes[action], id)
			assert.is_true(called)
			assert.is_false(ok)
			assert.is_truthy(err:find("E739", 1, true), err)
			assert.equals(changes.STATUS.FAILED, changes.get(id).status)
			assert.equals(id, changes.get_pending()[1].id)
			assert.is_nil(vim.uv.fs_lstat(path))
			assert(vim.uv.fs_chmod(root, 493))
			assert.is_true(changes[action](id))
			assert.equals(action == "accept" and "proposal" or "original", read(path))
			assert.equals(0, #changes.get_pending())
		end)
	end

	it("reports non-throwing write errors and permits manual resolution afterwards", function()
		local path = root .. "/failed"
		write(path, "before")
		local id = changes.add_change(path, "before", "after")
		vim.uv.fs_write = function() return nil, "disk full" end
		local ok, err = changes.accept(id)
		assert.is_false(ok)
		assert.equals("disk full", err)
		assert.is_true(changes.resolve_manually(id))
	end)

	for _, action in ipairs({ "accept", "reject" }) do
		it("preserves disk bytes and permits retry after a partial " .. action .. " write", function()
			local path = root .. "/transaction"
			for _, failure in ipairs({ "write", "short write", "write throws", "truncate", "sync", "close", "close throws", "rename" }) do
				local before, after = "\239\187\191before\r\n\0tail", "\239\187\191after\r\n\0tail"
				local disk = action == "accept" and before or after
				write(path, disk)
				local id = changes.add_change(path, before, after)
				vim.uv.fs_write = function(fd, bytes, offset)
					if failure == "write" or failure == "short write" or failure == "write throws" then
						local written = original_fs_write(fd, bytes:sub(1, 2), offset)
						if failure == "short write" then return written end
						if failure == "write throws" then error("disk full") end
						return nil, "disk full"
					end
					return original_fs_write(fd, bytes, offset)
				end
				if failure == "rename" then vim.uv.fs_rename = function() return nil, "rename failure" end end
				if failure == "sync" then vim.uv.fs_fsync = function() return nil, "sync failure" end end
				if failure == "truncate" then vim.uv.fs_ftruncate = function() return nil, "truncate failure" end end
				if failure == "close" or failure == "close throws" then
					vim.uv.fs_close = function(fd)
						original_fs_close(fd)
						if failure == "close throws" then error("close failure") end
						return nil, "close failure"
					end
				end
				local ok, err = changes[action](id)
				vim.uv.fs_write, vim.uv.fs_rename = original_fs_write, original_fs_rename
				vim.uv.fs_fsync, vim.uv.fs_close = original_fs_fsync, original_fs_close
				vim.uv.fs_ftruncate = original_fs_ftruncate
				assert.is_false(ok, failure)
				assert.is_string(err)
				assert.equals(disk, read(path), failure)
				assert.equals(changes.STATUS.FAILED, changes.get(id).status)
				assert.same({ "transaction" }, vim.fn.readdir(root))
				assert.is_true(changes[action](id))
				assert.equals(action == "accept" and after or before, read(path))
			end
		end)
	end

	it("retains file ownership, permissions and extended attributes after replacement", function()
		local path = root .. "/attributes"
		for _, permissions in ipairs({ "rwxr-x--x", "rw-------" }) do
			write(path, "before")
			assert.equals(1, vim.fn.setfperm(path, permissions))
			local stat = vim.uv.fs_stat(path)
			local xattr = vim.fn.has("mac") == 1 and vim.fn.executable("xattr") == 1
			if xattr then
				vim.fn.system({ "xattr", "-w", "com.opencode.test", "preserve", path })
				assert.equals(0, vim.v.shell_error)
				vim.fn.system({ "chmod", "+a", "everyone allow read", path })
				assert.equals(0, vim.v.shell_error)
			end
			local acl = xattr and vim.fn.system({ "ls", "-le", path }):match("\n(.+)$")
			if xattr then assert.is_truthy(acl:find("allow read", 1, true)) end
			assert.is_true(changes.accept(changes.add_change(path, "before", "after")))
			assert.equals("after", read(path))
			assert.equals(permissions, vim.fn.getfperm(path))
			assert.equals(stat.uid, vim.uv.fs_stat(path).uid)
			assert.equals(stat.gid, vim.uv.fs_stat(path).gid)
			if xattr then
				assert.equals("preserve\n", vim.fn.system({ "xattr", "-p", "com.opencode.test", path }))
				assert.equals(0, vim.v.shell_error)
				assert.equals(acl, vim.fn.system({ "ls", "-le", path }):match("\n(.+)$"))
			end
		end
	end)

	it("does not publish a partial new file and keeps the usual creation permissions", function()
		local control, path = root .. "/control", root .. "/created"
		write(control, "")
		local permissions = vim.fn.getfperm(control)
		for _, action in ipairs({ "accept", "reject" }) do
			local kind = action == "accept" and "add" or "delete"
			local id = changes.add_change(path, "original\0bytes", "proposal\0bytes", { file_type = kind })
			vim.uv.fs_write = function(fd, bytes, offset)
				original_fs_write(fd, bytes:sub(1, 2), offset)
				return nil, "disk full"
			end
			local ok, err = changes[action](id)
			vim.uv.fs_write = original_fs_write
			assert.is_false(ok)
			assert.equals("disk full", err)
			assert.is_nil(vim.uv.fs_lstat(path))
			assert.same({ "control" }, vim.fn.readdir(root))
			assert.is_true(changes[action](id))
			assert.equals(action == "accept" and "proposal\0bytes" or "original\0bytes", read(path))
			assert.equals(permissions, vim.fn.getfperm(path))
			assert(os.remove(path))
		end
	end)

	it("finishes new-file writes without reopening files restricted by umask", function()
		if vim.fn.has("win32") == 1 then return end
		local script = [[
			local changes = require("opencode.artifact.changes")
			changes.setup({ auto_backup = false })
			local root = vim.env.OPENCODE_UMASK_ROOT
			local bytes = "\239\187\191source\r\n\0tail"
			local control = assert(io.open(root .. "/control", "wb"))
			assert(control:write(bytes)); assert(control:close())
			assert(vim.fn.getfperm(root .. "/control") == "r--------")
			for _, action in ipairs({ "accept", "reject" }) do
				local path = root .. "/" .. action
				local id = changes.add_change(path, bytes, bytes, { file_type = action == "accept" and "add" or "delete" })
				local ok, err = changes[action](id)
				assert(ok, err)
				local file = assert(io.open(path, "rb"))
				assert(file:read("*a") == bytes); assert(file:close())
				assert(vim.fn.getfperm(path) == "r--------")
			end
		]]
		local command = 'local ok, err = pcall(function() ' .. script
			.. ' end); if not ok then vim.api.nvim_err_writeln(tostring(err)); vim.cmd("cquit 1") end; vim.cmd("qa!")'
		local result = vim.system({ "sh", "-c", 'umask 277; exec "$@"', "sh",
			"nvim", "--headless", "-u", "NONE", "-i", "NONE", "--cmd", "set rtp+=" .. vim.fn.getcwd(),
			"-c", "lua " .. command,
		}, { env = { OPENCODE_UMASK_ROOT = root } }):wait(2000)
		assert.equals(0, result.code, result.stderr)
		assert.same({ "accept", "control", "reject" }, vim.fn.readdir(root))
	end)

	it("preserves an original changed while the replacement is written", function()
		local path = root .. "/raced"
		write(path, "before")
		local id = changes.add_change(path, "before", "after")
		vim.uv.fs_write = function(fd, bytes, offset)
			local other = assert(original_open(path, "wb"))
			assert(other:write("manual edit")); assert(other:close())
			return original_fs_write(fd, bytes, offset)
		end
		local ok, err = changes.accept(id)
		vim.uv.fs_write = original_fs_write
		assert.is_false(ok)
		assert.is_truthy(err:find("File changed while writing", 1, true))
		assert.equals("manual edit", read(path))
		assert.same({ "raced" }, vim.fn.readdir(root))
	end)

	it("does not publish a temporary path substituted after writing its descriptor", function()
		local path, target = root .. "/published", root .. "/target"
		write(target, "preserved")
		for _, kind in ipairs({ "file", "link" }) do
			local temporary
			vim.uv.fs_open = function(name, mode, permissions)
				local fd, err = original_fs_open(name, mode, permissions)
				if mode == "wx" then temporary = name end
				return fd, err
			end
			vim.uv.fs_write = function(fd, bytes, offset)
				local written = original_fs_write(fd, bytes, offset)
				assert(vim.uv.fs_unlink(temporary))
				if kind == "file" then assert(vim.uv.fs_copyfile(target, temporary))
				else assert(vim.uv.fs_symlink(target, temporary)) end
				return written
			end
			local id = changes.add_change(path, "", "proposal", { file_type = "add" })
			local ok, err = changes.accept(id)
			vim.uv.fs_open, vim.uv.fs_write = original_fs_open, original_fs_write
			assert.is_false(ok)
			assert.is_truthy(err:find("Temporary file changed", 1, true))
			assert.is_nil(vim.uv.fs_lstat(path))
			assert.equals("preserved", read(target))
			assert.same({ "target" }, vim.fn.readdir(root))
			assert.is_true(changes.accept(id))
			assert.equals("proposal", read(path))
			assert(os.remove(path))
		end
	end)

	it("closes the retained descriptor if metadata copying replaces its file", function()
		if vim.fn.has("win32") == 1 then return end
		local path, held = root .. "/descriptor", nil
		write(path, "before")
		vim.uv.fs_open = function(name, mode, permissions)
			local fd, err = original_fs_open(name, mode, permissions)
			if mode == "wx" then held = fd end
			return fd, err
		end
		vim.fn.system = function(argv)
			local output = original_fn_system(argv)
			if argv[1] == "cp" then
				local temporary = argv[#argv]
				assert(vim.uv.fs_copyfile(path, temporary .. ".replacement"))
				assert(original_fs_rename(temporary .. ".replacement", temporary))
			end
			return output
		end
		local id = changes.add_change(path, "before", "after")
		local ok, err = changes.accept(id)
		vim.fn.system, vim.uv.fs_open = original_fn_system, original_fs_open
		assert.is_false(ok)
		assert.is_truthy(err:find("Could not preserve file attributes", 1, true))
		assert.is_nil(vim.uv.fs_fstat(held))
		assert.equals("before", read(path))
		assert.same({ "descriptor" }, vim.fn.readdir(root))
		assert.is_true(changes.accept(id))
		assert.equals("after", read(path))
	end)

	it("preserves hard-link relationships for manual resolution", function()
		local path, link = root .. "/original", root .. "/alias"
		write(path, "before")
		assert(vim.uv.fs_link(path, link))
		local id = changes.add_change(path, "before", "after")
		local ok, err = changes.accept(id, { force = true })
		assert.is_false(ok)
		assert.is_truthy(err:find("hard links", 1, true))
		assert.equals("before", read(path))
		assert.equals("before", read(link))
		assert.equals(vim.uv.fs_stat(path).ino, vim.uv.fs_stat(link).ino)
		assert.equals(changes.STATUS.FAILED, changes.get(id).status)
	end)

	it("passes Windows paths as data and commits only after ACL preparation succeeds", function()
		local path = root .. "/$($env:USERNAME) ' source"
		vim.fn.has = function(feature) return feature == "win32" and 1 or original_has(feature) end
		for _, failure in ipairs({ "acl", "replace", "partial replace", "failed restore", "none" }) do
			write(path, "before")
			assert.equals(1, vim.fn.setfperm(path, "rw-------"))
			local prepared, replaced, recovery = false, false, nil
			vim.system = function(argv, opts)
				assert.same({ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command" }, vim.list_slice(argv, 1, 4))
				assert.equals(path, opts.env.OPENCODE_WRITE_SOURCE)
				recovery = opts.env.OPENCODE_WRITE_BACKUP
				assert.is_nil(argv[5]:find(path, 1, true))
				return { wait = function()
					if argv[5]:find("Set-Acl", 1, true) then
						assert.is_truthy(argv[5]:find("Get-Acl -LiteralPath", 1, true))
						if failure == "acl" then return { code = 1, stderr = "acl failure" } end
						prepared = true
					else
						assert.is_true(prepared)
						assert.is_truthy(argv[5]:find("[System.IO.File]::Replace", 1, true))
						assert.is_truthy(argv[5]:find("$env:OPENCODE_WRITE_BACKUP", 1, true))
						if failure == "replace" then return { code = 1, stderr = "replace failure" } end
						assert(original_fs_rename(opts.env.OPENCODE_WRITE_SOURCE, recovery))
						if failure == "partial replace" or failure == "failed restore" then
							return { code = 1, stderr = failure .. " failure" }
						end
						assert(original_fs_rename(opts.env.OPENCODE_WRITE_TEMP, opts.env.OPENCODE_WRITE_SOURCE))
						replaced = true
					end
					return { code = 0, stderr = "" }
				end }
			end
			if failure == "failed restore" then vim.uv.fs_rename = function() return nil, "restore failure" end end
			local id = changes.add_change(path, "before", "after")
			local ok, err = changes.accept(id)
			vim.uv.fs_rename = original_fs_rename
			assert.equals(failure == "none", ok)
			assert.equals(failure == "none", replaced)
			if failure == "failed restore" then
				assert.is_nil(vim.uv.fs_lstat(path))
				assert.equals("before", read(recovery))
				assert.is_truthy(err:find(recovery, 1, true))
				assert(original_fs_rename(recovery, path))
			end
			assert.equals(failure == "none" and "after" or "before", read(path))
			if failure ~= "none" then
				assert.is_truthy(err:find(failure .. " failure", 1, true))
				assert.equals(changes.STATUS.FAILED, changes.get(id).status)
			end
			assert.same({ vim.fn.fnamemodify(path, ":t") }, vim.fn.readdir(root))
		end
	end)

	it("keeps a failed new-file deletion pending and retries it", function()
		local path = root .. "/new"
		local estate = edits.add_edit("new", "session", {
			{ filePath = path, before = "", after = "proposal\n", type = "add" },
		})
		write(path, "proposal\n")
		os.remove = function(name)
			if name == path then return nil, "temporary deletion failure" end
			return original_remove(name)
		end
		local ok, err = edits.reject_file("new", 1)
		assert.is_false(ok)
		assert.equals("temporary deletion failure", err)
		assert.equals("pending", estate.files[1].status)
		assert.equals(changes.STATUS.FAILED, changes.get(estate.files[1].change_id).status)
		assert.equals("proposal\n", read(path))
		os.remove = original_remove
		assert.is_true(edits.reject_file("new", 1))
		assert.is_nil(vim.uv.fs_lstat(path))
		assert.equals("rejected", estate.files[1].status)
	end)

	for _, failure in ipairs({ "read", "close" }) do
		it("keeps a review pending when reading the current file fails at " .. failure, function()
			local path = root .. "/unreadable"
			write(path, "")
			local estate = edits.add_edit("unreadable", "session", {
				{ filePath = path, before = "", after = "proposal", type = "update" },
			})
			local original_bytes = failure == "read" and "manual edits" or ""
			write(path, original_bytes)
			io.open = function(name, mode)
				local handle, err = original_open(name, mode)
				if name ~= path or mode ~= "rb" or not handle then return handle, err end
				return {
					read = function(_, ...)
						if failure == "read" then return nil, "temporary read failure" end
						return handle:read(...)
					end,
					close = function()
						handle:close()
						if failure == "close" then return nil, "temporary close failure" end
						return true
					end,
				}
			end
			local ok, err = edits.accept_file("unreadable", 1)
			io.open = original_open
			assert.is_false(ok)
			assert.equals("temporary " .. failure .. " failure", err)
			assert.equals(original_bytes, read(path))
			assert.equals("pending", estate.files[1].status)
			assert.equals(changes.STATUS.PENDING, changes.get(estate.files[1].change_id).status)
		end)
	end

	for _, action in ipairs({ "resolve_file", "resolve_all" }) do
		it("keeps an unreadable manual " .. action .. " pending for retry", function()
			local path = root .. "/manual"
			write(path, "before\n")
			local estate = edits.add_edit("manual", "session", {
				{ filePath = path, before = "before\n", after = "after\n", type = "update" },
			})
			io.open = function(name, mode)
				if name == path and mode == "rb" then return nil, "temporary read failure" end
				return original_open(name, mode)
			end
			local ok, err = edits[action]("manual", 1)
			assert.is_false(ok)
			assert.equals("temporary read failure", err)
			assert.equals("pending", estate.files[1].status)
			assert.equals(changes.STATUS.PENDING, changes.get(estate.files[1].change_id).status)
			io.open = original_open
			assert.is_true(edits[action]("manual", 1))
			assert.equals("rejected", estate.files[1].status)
			assert.equals("before\n", read(path))
		end)
	end

	it("keeps manual confirmation pending if the final disk read fails", function()
		local path = root .. "/final-read"
		write(path, "before\n")
		local estate = edits.add_edit("final-read", "session", {
			{ filePath = path, before = "before\n", after = "after\n", type = "update" },
		})
		local reads = 0
		io.open = function(name, mode)
			if name == path and mode == "rb" then
				reads = reads + 1
				if reads == 2 then return nil, "final read failure" end
			end
			return original_open(name, mode)
		end
		local ok, err = edits.resolve_file("final-read", 1)
		assert.is_false(ok)
		assert.equals("final read failure", err)
		assert.equals("pending", estate.files[1].status)
		assert.equals(changes.STATUS.PENDING, changes.get(estate.files[1].change_id).status)
	end)

	for _, kind in ipairs({ "update", "add" }) do
		it("does not follow a replacement symbolic link while accepting an " .. kind, function()
			local path, target = root .. "/reviewed", root .. "/other"
			local before = kind == "update" and "before" or ""
			if kind == "update" then write(path, before) end
			local estate = edits.add_edit("link", "session", {
				{ filePath = path, before = before, after = "proposal", type = kind },
			})
			if kind == "update" then assert(os.remove(path)); write(target, before) end
			assert(vim.uv.fs_symlink(target, path))
			local ok, err = edits.accept_file("link", 1)
			assert.is_false(ok)
			assert.is_truthy(err:find("link", 1, true))
			assert.equals("link", vim.uv.fs_lstat(path).type)
			if kind == "update" then assert.equals(before, read(target)) else assert.is_nil(vim.uv.fs_stat(target)) end
			assert.equals("pending", estate.files[1].status)
		end)
	end
end)
