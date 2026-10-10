-- Preview the attachment's bytes or remote URI, never a same-named local file.
local M = {}
local previews = {}
local extensions = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif",
	["image/webp"] = "webp", ["image/avif"] = "avif", ["image/bmp"] = "bmp",
	["image/tiff"] = "tiff", ["image/heic"] = "heic", ["image/svg+xml"] = "svg" }

function M.open(file)
	if type(file) ~= "table" then return nil, "Image content is unavailable from the server" end
	local mime = file.mime
	local uri = file.uri or file.url
	local data = file.data
	if type(uri) == "string" and uri:match("^data:") then
		local embedded_mime, encoded = uri:match("^data:([^;,]+);base64,(.*)$")
		if not embedded_mime then return nil, "Unsupported image data URI" end
		mime, data = embedded_mime, encoded
	end
	if type(mime) ~= "string" or not mime:match("^image/") then return nil, "Attachment is not an image" end
	if type(data) == "string" then
		if not extensions[mime] then return nil, "Unsupported image type: " .. mime end
		if data == "" or #data % 4 ~= 0 or data:find("[^A-Za-z0-9+/=]") or data:find("=[^=]") then
			return nil, "Invalid image encoding"
		end
		local ok, bytes = pcall(vim.base64.decode, data)
		if not ok or not bytes or bytes == "" then return nil, "Invalid image encoding" end
		local path = vim.fn.tempname() .. "." .. extensions[mime]
		local fd = vim.uv.fs_open(path, "wx", 384)
		if not fd then return nil, "Could not create image preview" end
		local written = vim.uv.fs_write(fd, bytes, 0)
		local closed = vim.uv.fs_close(fd)
		if written ~= #bytes or not closed then vim.uv.fs_unlink(path); return nil, "Could not write image preview" end
		previews[#previews + 1] = path
		uri = path
	elseif type(uri) ~= "string" or not uri:match("^https?://[^%s]+$") then
		return nil, "Image content is unavailable from the server"
	end
	local ok, result, err = pcall(vim.ui.open, uri)
	if not ok or not result then return nil, tostring(err or result or "Could not open image preview") end
	return uri
end

function M.items(session_id)
	local sync, items, seen = require("opencode.sync"), {}, {}
	if not session_id then return items end
	local function add(file)
		if type(file) ~= "table" or type(file.mime) ~= "string" or not file.mime:match("^image/") then return end
		local uri = file.uri or file.url
		local key = uri or file.data
		if not key or seen[key] then return end
		seen[key] = true
		items[#items + 1] = { label = file.name or file.filename or ("Image " .. (#items + 1)), description = file.mime, file = file }
	end
	for _, message in ipairs(sync.get_messages(session_id)) do
		for _, part in ipairs(sync.get_parts(message.id)) do
			if part.type == "file" then add(part) end
			if part.type == "tool" then
				for _, content in ipairs((part.state or {}).content or {}) do if content.type == "file" then add(content) end end
			end
		end
	end
	return items
end

function M.show()
	local sid = require("opencode.state").get_session().id
	local items = M.items(sid)
	if #items == 0 then vim.notify("No available image attachments in this session", vim.log.levels.INFO); return end
	local pending = require("opencode.session.pending")
	local token = pending.token(sid)
	require("opencode.ui.menu").open({ title = " Image Attachments ", items = items, width = 70,
		on_select = function(item)
			if not pending.is_current(token) or require("opencode.state").get_session().id ~= sid then return end
			local path, err = M.open(item.file)
			if not path then vim.notify(err, vim.log.levels.WARN) end
		end })
end

function M.register(palette)
	palette.register({ id = "action.images", title = "Preview Image Attachments", category = "actions",
		slash = { name = "images" }, on_select = function(ctx) return ctx.run() end,
		run = M.show, enabled = function() return require("opencode.state").get_session().id ~= nil end })
end

vim.api.nvim_create_autocmd("VimLeavePre", { group = vim.api.nvim_create_augroup("OpenCodeImagePreviews", { clear = true }),
	callback = function() for _, path in ipairs(previews) do vim.uv.fs_unlink(path) end end })
return M
