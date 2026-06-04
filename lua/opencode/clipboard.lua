-- opencode.nvim - Clipboard helpers for prompt paste support

local M = {}

local uv = vim.uv or vim.loop

local IMAGE_MIME_BY_EXT = {
	avif = "image/avif",
	bmp = "image/bmp",
	gif = "image/gif",
	heic = "image/heic",
	jpeg = "image/jpeg",
	jpg = "image/jpeg",
	png = "image/png",
	tif = "image/tiff",
	tiff = "image/tiff",
	webp = "image/webp",
}

---@return string
local function platform()
	local uname = uv and uv.os_uname and uv.os_uname() or {}
	local sysname = string.lower(uname.sysname or "")
	local release = string.lower(uname.release or "")

	if sysname:find("darwin", 1, true) then
		return "darwin"
	end
	if sysname:find("windows", 1, true) or sysname:find("mingw", 1, true) then
		return "windows"
	end
	if release:find("microsoft", 1, true) or release:find("wsl", 1, true) then
		return "wsl"
	end
	return "linux"
end

---@param command string[]
---@return boolean ok
---@return string output
local function run(command)
	local output = vim.fn.system(command)
	return vim.v.shell_error == 0, output
end

---@param value string
---@return string
local function trim(value)
	return vim.trim(value or "")
end

---@param value string
---@return string
local function applescript_string(value)
	return (value:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

---@param value string
---@return string
local function percent_decode(value)
	return (value:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

---@param data string
---@return string|nil
local function encode_base64(data)
	if vim.base64 and type(vim.base64.encode) == "function" then
		return vim.base64.encode(data)
	end

	local ok, encoded = pcall(vim.fn.base64encode, data)
	if ok then
		return encoded
	end

	return nil
end

---@param data any
---@return string|nil
local function binary_to_string(data)
	if type(data) == "string" then
		return data
	end

	if vim.fn.exists("*blob2list") == 1 then
		local ok, bytes = pcall(vim.fn.blob2list, data)
		if ok and type(bytes) == "table" then
			local chunks = {}
			for i, byte in ipairs(bytes) do
				if type(byte) ~= "number" then
					return nil
				end
				chunks[i] = string.char(byte)
			end
			return table.concat(chunks)
		end
	end

	return nil
end

---@param filepath string
---@return string|nil data
---@return string|nil err
local function read_file_base64(filepath)
	local ok, data = pcall(vim.fn.readblob, filepath)
	if not ok then
		return nil, "Cannot read file"
	end

	data = binary_to_string(data)
	if type(data) ~= "string" then
		return nil, "Cannot read file"
	end
	if data == "" then
		return nil, "File is empty"
	end

	local encoded = encode_base64(data)
	if not encoded then
		return nil, "Failed to encode file"
	end
	return encoded, nil
end

---@return table|nil
local function read_macos_image()
	if vim.fn.executable("osascript") ~= 1 then
		return nil
	end

	local tmpfile = vim.fn.tempname() .. ".png"
	local escaped = applescript_string(tmpfile)
	local ok = run({
		"osascript",
		"-e",
		'set imageData to the clipboard as "PNGf"',
		"-e",
		'set fileRef to open for access POSIX file "' .. escaped .. '" with write permission',
		"-e",
		"set eof fileRef to 0",
		"-e",
		"write imageData to fileRef",
		"-e",
		"close access fileRef",
	})

	if not ok then
		os.remove(tmpfile)
		return nil
	end

	local data = read_file_base64(tmpfile)
	os.remove(tmpfile)
	if not data then
		return nil
	end

	return {
		data = data,
		mime = "image/png",
		filename = "clipboard.png",
	}
end

---@return table|nil
local function read_windows_image()
	local exe = nil
	for _, candidate in ipairs({ "powershell.exe", "powershell", "pwsh" }) do
		if vim.fn.executable(candidate) == 1 then
			exe = candidate
			break
		end
	end
	if not exe then
		return nil
	end

	local script = table.concat({
		"Add-Type -AssemblyName System.Windows.Forms;",
		"$img = [System.Windows.Forms.Clipboard]::GetImage();",
		"if ($img) {",
		"$ms = New-Object IO.MemoryStream;",
		"$img.Save($ms, [Drawing.Imaging.ImageFormat]::Png);",
		"[Convert]::ToBase64String($ms.ToArray())",
		"}",
	}, " ")

	local ok, output = run({ exe, "-NonInteractive", "-NoProfile", "-Command", script })
	local data = ok and trim(output) or ""
	if data == "" then
		return nil
	end

	return {
		data = data,
		mime = "image/png",
		filename = "clipboard.png",
	}
end

---@param command string[]
---@return table|nil
local function read_command_image(command)
	local ok, output = run(command)
	if not ok or type(output) ~= "string" or output == "" then
		return nil
	end

	local data = encode_base64(output)
	if not data then
		return nil
	end

	return {
		data = data,
		mime = "image/png",
		filename = "clipboard.png",
	}
end

---@return table|nil
local function read_linux_image()
	if vim.fn.executable("wl-paste") == 1 then
		local content = read_command_image({ "wl-paste", "-t", "image/png" })
		if content then
			return content
		end
	end

	if vim.fn.executable("xclip") == 1 then
		return read_command_image({ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" })
	end

	return nil
end

---@return table|nil
local function read_text()
	for _, register in ipairs({ "+", "*" }) do
		local ok, text = pcall(vim.fn.getreg, register)
		if ok and type(text) == "string" and text ~= "" then
			return {
				data = text,
				mime = "text/plain",
			}
		end
	end
	return nil
end

---@param filepath string
---@return string|nil
local function mime_for_path(filepath)
	local ext = filepath:match("%.([^./\\]+)$")
	ext = ext and string.lower(ext) or ""
	return IMAGE_MIME_BY_EXT[ext]
end

---@param text string
---@return string|nil
local function path_from_text(text)
	local raw = trim(text):gsub("^['\"]+", ""):gsub("['\"]+$", "")
	if raw == "" or raw:find("\n", 1, true) then
		return nil
	end

	if raw:sub(1, 7) == "file://" then
		raw = raw:gsub("^file://localhost", "")
		raw = raw:gsub("^file://", "")
		raw = percent_decode(raw)
	elseif platform() ~= "windows" then
		raw = raw:gsub("\\(.)", "%1")
	end

	local filepath = vim.fn.fnamemodify(raw, ":p")
	if filepath == "" or vim.fn.filereadable(filepath) ~= 1 then
		return nil
	end

	return filepath
end

---Read an image file as an OpenCode file part source.
---@param filepath string
---@param mime? string
---@return table|nil content
---@return string|nil err
function M.read_image_file(filepath, mime)
	local data, err = read_file_base64(filepath)
	if not data then
		return nil, err
	end

	return {
		data = data,
		mime = mime or mime_for_path(filepath) or "application/octet-stream",
		filename = vim.fn.fnamemodify(filepath, ":t"),
		filepath = filepath,
	}, nil
end

---If pasted text is an image path or file URL, read it as image content.
---@param text string
---@return table|nil content
function M.image_from_text(text)
	local filepath = path_from_text(text)
	if not filepath then
		return nil
	end

	local mime = mime_for_path(filepath)
	if not mime then
		return nil
	end

	local content = M.read_image_file(filepath, mime)
	return content
end

---Read clipboard content, preferring image data over text.
---@return table|nil content { data: string, mime: string, filename?: string, filepath?: string }
function M.read()
	local os = platform()
	local image = nil
	if os == "darwin" then
		image = read_macos_image()
	elseif os == "windows" or os == "wsl" then
		image = read_windows_image()
	else
		image = read_linux_image()
	end

	if image then
		return image
	end

	local text = read_text()
	if text then
		return text
	end

	return nil
end

return M
