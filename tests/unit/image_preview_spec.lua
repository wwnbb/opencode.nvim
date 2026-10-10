describe("server attachment preview", function()
	local images = require("opencode.ui.images")
	local state, sync = require("opencode.state"), require("opencode.sync")
	local pending, menu = require("opencode.session.pending"), require("opencode.ui.menu")
	local open, menu_open, notify, paths, opened, notifications, picker
	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all()
		open, menu_open, notify = vim.ui.open, menu.open, vim.notify
		paths, opened, notifications = {}, {}, {}
		vim.ui.open = function(uri) opened[#opened + 1] = uri; return {} end
		menu.open = function(opts) picker = opts end
		vim.notify = function(message) notifications[#notifications + 1] = message end
	end)
	after_each(function()
		vim.ui.open, menu.open, vim.notify = open, menu_open, notify
		for _, path in ipairs(paths) do vim.fn.delete(path) end
		state.reset(); sync.clear_all(); pending.clear_all()
	end)
	it("opens the actual bytes in a private temporary file instead of a same-named local file", function()
		local path = vim.fn.tempname() .. ".png"; paths[#paths + 1] = path
		vim.fn.writefile({ "local unrelated file" }, path)
		local bytes = "\137PNG\0server bytes"
		local preview = assert(images.open({ mime = "image/png", filename = path,
			uri = "data:image/png;base64," .. vim.base64.encode(bytes) }))
		paths[#paths + 1] = preview
		assert.is_not.equals(path, preview)
		assert.equals(preview, opened[1])
		local fd = assert(vim.uv.fs_open(preview, "r", 0))
		assert.equals(bytes, vim.uv.fs_read(fd, #bytes, 0)); vim.uv.fs_close(fd)
		assert.equals(384, bit.band(vim.uv.fs_stat(preview).mode, 511))
		assert.equals("local unrelated file", vim.fn.readfile(path)[1])
	end)
	it("uses the remote image URI and rejects missing content or malformed encoding", function()
		local uri = "https://example.invalid/generated.png?image=1"
		assert.equals(uri, images.open({ mime = "image/png", uri = uri, filename = "/local/generated.png" }))
		for _, file in ipairs({ { mime = "image/png", uri = "file:///remote/image.png" },
			{ mime = "image/png", filename = "/remote/image.png" },
			{ mime = "image/png", uri = "data:image/png;base64,INVALID!" },
			{ mime = "image/png", uri = "data:image/png,hello" }, { mime = "text/plain", data = "Yg==" } }) do
			local result, err = images.open(file)
			assert.is_nil(result); assert.is_string(err)
		end
		assert.equals(1, #opened)
		vim.ui.open = function() return nil, "viewer unavailable" end
		local result, err = images.open({ mime = "image/png", uri = uri })
		assert.is_nil(result); assert.equals("viewer unavailable", err)
	end)
	it("lists user attachments and tool result images once and guards stale selection", function()
		state.set_session("s", "Session")
		sync.handle_message_updated({ id = "msg_1", sessionID = "s", role = "user" })
		sync.handle_message_updated({ id = "msg_2", sessionID = "s", role = "assistant" })
		local image = { type = "file", mime = "image/png", uri = "https://example.invalid/a.png", name = "A" }
		sync.handle_part_updated(vim.tbl_extend("force", image, { id = "part_1", messageID = "msg_1" }))
		sync.handle_part_updated({ id = "part_2", messageID = "msg_2", type = "tool", state = { content = {
			image, { type = "file", mime = "image/webp", uri = "https://example.invalid/b.webp", name = "B" },
			{ type = "file", mime = "text/plain", uri = "https://example.invalid/txt" } } } })
		images.show()
		assert.equals(2, #picker.items)
		picker.on_select(picker.items[2]); assert.equals("https://example.invalid/b.webp", opened[1])
		state.set_session("other", "Other")
		picker.on_select(picker.items[1]); assert.equals(1, #opened)
		images.show(); assert.matches("No available image", notifications[1])
	end)
end)
