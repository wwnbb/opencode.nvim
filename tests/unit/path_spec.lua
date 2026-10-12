describe("opencode.util.path", function()
	local path = require("opencode.util.path")
	local state = require("opencode.state")
	after_each(function() state.reset() end)

	it("preserves roots and normalizes Windows paths independently of the host", function()
		assert.is_nil(path.normalize(nil))
		assert.is_nil(path.normalize(""))
		assert.equals("/", path.normalize("/"))
		assert.equals("C:/", path.normalize("C:/"))
		assert.equals("C:/", path.normalize([[C:\]]))
		assert.equals("C:/remote/project", path.normalize([[C:\remote\project\]]))
		assert.equals("//server/share", path.normalize([[\\server\share\]]))
		assert.equals("//server/share/file.lua", path.normalize([[\\server\share\file.lua]]))
	end)

	it("preserves literal backslashes in POSIX paths", function()
		if vim.fn.has("win32") == 1 then return end
		assert.equals([[/remote/a\b/file.lua]], path.normalize([[/remote/a\b/file.lua]]))
	end)

	it("matches normalized descendants at directory boundaries", function()
		local root = path.normalize([[C:\remote\project\]])
		assert.is_true(path.within(root, root))
		assert.is_true(path.within(path.normalize([[C:\remote\project\file.lua]]), root))
		assert.is_false(path.within(path.normalize([[C:\remote\project-other\file.lua]]), root))
		assert.is_true(path.within("C:/file.lua", path.normalize("C:/")))
		assert.is_true(path.within("/file.lua", path.normalize("/")))
	end)

	it("maps diagnostic filenames from Windows servers to local paths", function()
		state.set_config({ server = { shared_filesystem = false, path_mappings = {
			{ remote = [[C:\remote\project]], local_root = "/local/project" },
			{ remote = [[\\server\share]], local_root = "/local/share" },
		} } })
		local diagnostics = require("opencode.diagnostics")
		assert.equals("/local/project/src/file.lua", diagnostics.local_path([[C:\remote\project\src\file.lua]]))
		assert.equals("/local/share/file.lua", diagnostics.local_path([[\\server\share\file.lua]]))
		assert.is_nil(diagnostics.local_path([[C:\remote\project-other\file.lua]]))
	end)
end)
