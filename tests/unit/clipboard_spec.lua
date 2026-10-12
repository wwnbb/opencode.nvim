describe("clipboard image files", function()
	local path, link
	after_each(function()
		if link then vim.fn.delete(link); link = nil end
		if path then vim.fn.delete(path); path = nil end
	end)

	it("encodes file bytes as base64 and preserves the explicit MIME type", function()
		path = vim.fn.tempname() .. ".png"
		vim.fn.writefile({ "abc" }, path)
		local content, err = require("opencode.clipboard").read_image_file(path, "image/png")
		assert.is_nil(err)
		assert.equals("YWJjCg==", content.data)
		assert.equals("image/png", content.mime)
	end)
	it("rejects image FIFOs without blocking direct reads or pasted path detection", function()
		path = vim.fn.tempname() .. ".png"
		vim.fn.system({ "mkfifo", path })
		assert.equals(0, vim.v.shell_error)
		local script = 'local clipboard = require("opencode.clipboard"); '
			.. 'local image, err = clipboard.read_image_file(vim.env.OPENCODE_FIFO_IMAGE); '
			.. 'assert(image == nil and err == "Cannot read file"); '
			.. 'assert(clipboard.image_from_text(vim.env.OPENCODE_FIFO_IMAGE) == nil); vim.cmd("qa!")'
		local result = vim.system({ "nvim", "--headless", "-u", "NONE", "-i", "NONE",
			"--cmd", "set rtp+=" .. vim.fn.getcwd(), "-c", "lua " .. script,
		}, { env = { OPENCODE_FIFO_IMAGE = path } }):wait(1500)
		assert.equals(0, result.code, result.stderr)
		assert.equals("fifo", vim.uv.fs_lstat(path).type)
	end)

	it("keeps regular image symlinks readable and rejects invalid paths", function()
		local clipboard = require("opencode.clipboard")
		path = vim.fn.tempname() .. ".png"
		vim.fn.writefile({ "bytes" }, path)
		link = path .. ".link.png"
		assert(vim.uv.fs_symlink(path, link))
		assert.equals(vim.base64.encode("bytes\n"), clipboard.read_image_file(link).data)
		assert.equals(vim.base64.encode("bytes\n"), clipboard.image_from_text(link).data)
		for _, invalid in ipairs({ false, {}, 42, path .. "\0.png", path .. ".missing" }) do
			local ok, image, err = pcall(clipboard.read_image_file, invalid)
			assert.is_true(ok)
			assert.is_nil(image)
			assert.equals("Cannot read file", err)
		end
	end)

end)

describe("clipboard command images", function()
	local directory, saved
	local uv = vim.uv or vim.loop
	local clipboard = require("opencode.clipboard")
	local bytes = "\137PNG\r\n\26\n\0\1\255payload"

	local function executable(name, body)
		local path = directory .. "/" .. name
		vim.fn.writefile({ "#!/bin/sh", body }, path)
		assert(uv.fs_chmod(path, 493))
	end

	before_each(function()
		directory = vim.fn.tempname()
		vim.fn.mkdir(directory, "p")
		saved = { path = vim.env.PATH, uname = uv.os_uname, getreg = vim.fn.getreg, system = vim.system, tempname = vim.fn.tempname }
		vim.env.PATH = directory
		uv.os_uname = function() return { sysname = "Linux", release = "test" } end
		vim.fn.getreg = function() return "text fallback" end
	end)

	after_each(function()
		vim.env.PATH, uv.os_uname, vim.fn.getreg, vim.system = saved.path, saved.uname, saved.getreg, saved.system
		vim.fn.tempname = saved.tempname
		vim.fn.delete(directory, "rf")
	end)

	for _, tool in ipairs({ "wl-paste", "xclip" }) do
		it("preserves binary image bytes and keeps stderr separate with " .. tool, function()
			executable(tool, [[printf '\211PNG\015\012\032\012\000\001\377payload'; printf 'diagnostic' >&2]])
			local content = clipboard.read()
			assert.equals("image/png", content.mime)
			assert.equals(vim.base64.encode(bytes), content.data)
			assert.equals("clipboard.png", content.filename)
		end)
	end

	it("returns PNG content on Windows and WSL and falls back when PowerShell fails", function()
		executable("powershell.exe", "exit 1")
		local result = { code = 0, stdout = " \r\n" .. vim.base64.encode(bytes) .. "\r\n" }
		vim.system = function(command)
			assert.equals("powershell.exe", command[1])
			return { wait = function() return result end }
		end
		for _, uname in ipairs({ { sysname = "Windows_NT" }, { sysname = "Linux", release = "microsoft-WSL2" } }) do
			uv.os_uname = function() return uname end
			result.code = 0
			assert.same({ data = vim.base64.encode(bytes), mime = "image/png", filename = "clipboard.png" }, clipboard.read())
			result.code = 1
			assert.same({ data = "text fallback", mime = "text/plain" }, clipboard.read())
		end
	end)

	it("returns macOS PNG content and removes temporary files after success or failure", function()
		executable("osascript", "exit 1")
		uv.os_uname = function() return { sysname = "Darwin" } end
		local tmpfile, code = directory .. "/clipboard.png", 0
		vim.fn.tempname = function() return directory .. "/clipboard" end
		vim.system = function(command)
			assert.equals("osascript", command[1])
			vim.fn.writefile({ "image bytes" }, tmpfile, "b")
			return { wait = function() return { code = code, stdout = "" } end }
		end
		assert.same({ data = vim.base64.encode("image bytes"), mime = "image/png", filename = "clipboard.png" }, clipboard.read())
		assert.is_nil(uv.fs_stat(tmpfile))
		code = 1
		assert.same({ data = "text fallback", mime = "text/plain" }, clipboard.read())
		assert.is_nil(uv.fs_stat(tmpfile))
	end)

	it("falls back to text if the image command fails or cannot spawn", function()
		executable("wl-paste", "exit 1")
		assert.equals("text/plain", clipboard.read().mime)
		vim.system = function() error("Executable disappeared") end
		assert.equals("text fallback", clipboard.read().data)
		vim.fn.getreg = function() return "" end
		assert.is_nil(clipboard.read())
		assert.equals(1, select("#", clipboard.read()))
	end)
end)

describe("clipboard local file URLs", function()
	local directory, previous_cwd, path
	local clipboard = require("opencode.clipboard")
	before_each(function()
		directory, previous_cwd = vim.fn.tempname(), vim.fn.getcwd()
		vim.fn.mkdir(directory, "p")
		vim.cmd.cd(vim.fn.fnameescape(directory))
		path = directory .. "/image é #.png"
		vim.fn.writefile({ "image bytes" }, path)
	end)
	after_each(function()
		vim.cmd.cd(vim.fn.fnameescape(previous_cwd))
		vim.fn.delete(directory, "rf")
	end)

	it("uses native decoding for absolute, localhost and single-slash file URLs", function()
		local uri = vim.uri_from_fname(path)
		for _, value in ipairs({ uri, (uri:gsub("^file://", "file://localhost")), (uri:gsub("^file://", "FILE://LOCALHOST")), (uri:gsub("^file://", "file:")) }) do
			local content = assert(clipboard.image_from_text(value), value)
			assert.equals(path, content.filepath)
			assert.equals(vim.base64.encode("image bytes\n"), content.data)
		end
	end)

	it("prefers a literal existing backslash path over its unescaped neighbour", function()
		path = directory .. "/image\\ name.png"
		local neighbour = directory .. "/image name.png"
		vim.fn.writefile({ "literal image" }, path)
		vim.fn.writefile({ "different image" }, neighbour)
		for _, value in ipairs({ path, "'" .. path .. "'", '"' .. path .. '"', "./image\\ name.png" }) do
			local content = assert(clipboard.image_from_text(value), value)
			assert.equals(vim.uv.fs_realpath(path), vim.uv.fs_realpath(content.filepath))
			assert.equals(vim.base64.encode("literal image\n"), content.data)
		end
		local escaped = directory .. "/escaped image.png"
		vim.fn.writefile({ "escaped image" }, escaped)
		assert.equals(escaped, clipboard.image_from_text(escaped:gsub(" ", "\\ ")).filepath)
		assert(vim.uv.fs_unlink(path))
		assert(vim.uv.fs_symlink(path .. ".missing", path))
		assert.is_nil(clipboard.image_from_text(path))
	end)

	it("does not treat remote authorities as relative files or localhost prefixes", function()
		for _, authority in ipairs({ "remote", "localhost-other" }) do
			local accidental = authority == "remote" and "remote/image.png" or "-other/image.png"
			vim.fn.mkdir(vim.fn.fnamemodify(accidental, ":h"), "p")
			vim.fn.writefile({ "unrelated local image" }, accidental)
			assert.is_nil(clipboard.image_from_text("file://" .. authority .. "/image.png"))
		end
	end)

	it("rejects decoded NUL bytes and relative file URLs without throwing", function()
		for _, value in ipairs({ "file:///tmp/image%00.png", "file:relative.png" }) do
			local ok, content = pcall(clipboard.image_from_text, value)
			assert.is_true(ok, value)
			assert.is_nil(content)
		end
	end)
end)
