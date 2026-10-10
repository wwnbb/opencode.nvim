-- RFC 6455 framing over the same endpoint/auth and TCP/TLS channels as HTTP.
local M = {}
local bit = require("bit")
local schedule = require("opencode.util.schedule").schedule_callback
local auth = require("opencode.client.auth")
local MAX_MESSAGE, MAX_HEADER = 8 * 1024 * 1024, 64 * 1024

local function be32(value)
	return string.char(bit.band(bit.rshift(value, 24), 255), bit.band(bit.rshift(value, 16), 255), bit.band(bit.rshift(value, 8), 255), bit.band(value, 255))
end

local function u32(text, index)
	local a, b, c, d = text:byte(index, index + 3)
	return bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
end

-- SHA-1 is required only for the fixed WebSocket handshake, not authentication.
local function sha1(text)
	local length = #text
	text = text .. "\128" .. string.rep("\0", (55 - length) % 64) .. be32(math.floor(length / 536870912)) .. be32(length * 8)
	local h = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 }
	for start = 1, #text, 64 do
		local w = {}
		for index = 0, 15 do w[index] = u32(text, start + index * 4) end
		for index = 16, 79 do w[index] = bit.rol(bit.bxor(w[index - 3], w[index - 8], w[index - 14], w[index - 16]), 1) end
		local a, b, c, d, e = unpack(h)
		for index = 0, 79 do
			local f, k
			if index < 20 then f, k = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d)), 0x5A827999
			elseif index < 40 then f, k = bit.bxor(b, c, d), 0x6ED9EBA1
			elseif index < 60 then f, k = bit.bor(bit.band(b, c), bit.band(b, d), bit.band(c, d)), 0x8F1BBCDC
			else f, k = bit.bxor(b, c, d), 0xCA62C1D6 end
			local next_a = bit.tobit(bit.rol(a, 5) + f + e + k + w[index])
			e, d, c, b, a = d, c, bit.rol(b, 30), a, next_a
		end
		for index, value in ipairs({ a, b, c, d, e }) do h[index] = bit.tobit(h[index] + value) end
	end
	local bytes = {}; for _, value in ipairs(h) do bytes[#bytes + 1] = be32(value) end
	return table.concat(bytes)
end

local function random(size)
	local ok, value = pcall((vim.uv or vim.loop).random, size)
	if ok and type(value) == "string" and #value == size then return value end
end

local function frame(opcode, data)
	local mask = random(4)
	if not mask then return nil, "Could not generate a WebSocket mask" end
	local length, prefix = #data
	if length < 126 then prefix = string.char(0x80 + opcode, 0x80 + length)
	elseif length <= 65535 then prefix = string.char(0x80 + opcode, 254, math.floor(length / 256), length % 256)
	else prefix = string.char(0x80 + opcode, 255) .. be32(0) .. be32(length) end
	local bytes = {}
	for index = 1, length do bytes[index] = string.char(bit.bxor(data:byte(index), mask:byte((index - 1) % 4 + 1))) end
	return prefix .. mask .. table.concat(bytes)
end

function M.open(opts)
	if type(opts.path) ~= "string" or opts.path == "" or opts.path:find("[%s%z]") then
		return nil, { message = "Invalid WebSocket path" }
	end
	local endpoint, endpoint_err = require("opencode.client.endpoint").resolve(opts)
	if not endpoint then return nil, endpoint_err end
	local nonce = random(16)
	local key = nonce and auth.encode_base64(nonce)
	local accept = key and auth.encode_base64(sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	if not key or not accept then return nil, { message = "Could not create the WebSocket handshake" } end
	local authorization, auth_err = auth.header((opts.auth or {}).username or "opencode", (opts.auth or {}).password)
	if auth_err then return nil, { message = auth_err } end
	local host = endpoint.host:find(":", 1, true) and ("[" .. endpoint.host .. "]") or endpoint.host
	local headers, headers_err = require("opencode.client.headers").merge({ Host = host .. ":" .. endpoint.port,
		Upgrade = "websocket", Connection = "Upgrade", ["Sec-WebSocket-Key"] = key, ["Sec-WebSocket-Version"] = "13", Authorization = authorization })
	if not headers then return nil, { message = headers_err } end
	local path = require("opencode.client.endpoint").join(endpoint, opts.path)
	if type(path) ~= "string" or path:find("[%s%z]") then return nil, { message = "Invalid WebSocket path" } end
	local request = { "GET " .. path .. " HTTP/1.1" }
	for name, value in pairs(headers) do request[#request + 1] = name .. ": " .. value end
	request[#request + 1], request[#request + 2] = "", ""
	local buffer, active, ready, connection, fragmented, chunks, total = "", true, false, nil, nil, {}, 0
	local socket = {}
	local function finish(err, reason)
		if not active then return end
		active = false
		if connection then connection.close(); connection = nil end
		if err then schedule(opts.on_error, err) end
		schedule(opts.on_close, reason or "closed")
	end
	local function send(opcode, data)
		if not active or not ready or not connection then return false end
		local encoded, encode_err = frame(opcode, data)
		if not encoded then finish({ message = encode_err }); return false end
		return connection.send(encoded)
	end
	function socket.send(data)
		if type(data) ~= "string" or #data > MAX_MESSAGE then return false end
		return send(2, data)
	end
	function socket.close()
		if active and ready then send(8, string.char(3, 232)) end
		finish(nil, "detached")
	end
	function socket.is_active() return active end
	local function invalid(message) finish({ code = "websocket_protocol", message = message }, "protocol_error") end
	local function parse_frames()
		while active and #buffer >= 2 do
			local first, second = buffer:byte(1, 2)
			local fin, opcode, length, offset = bit.band(first, 128) ~= 0, bit.band(first, 15), bit.band(second, 127), 3
			if bit.band(first, 112) ~= 0 or bit.band(second, 128) ~= 0 then invalid("Invalid or masked server WebSocket frame"); return end
			if length == 126 then
				if #buffer < 4 then return end
				length, offset = buffer:byte(3) * 256 + buffer:byte(4), 5
				if length < 126 then invalid("Invalid WebSocket frame length"); return end
			elseif length == 127 then
				if #buffer < 10 then return end
				local high = u32(buffer, 3)
				length, offset = u32(buffer, 7), 11
				if high ~= 0 or length < 65536 then invalid("Oversized or invalid WebSocket frame"); return end
			end
			if length < 0 or length > MAX_MESSAGE or total + length > MAX_MESSAGE then invalid("WebSocket replay exceeded 8 MiB"); return end
			if opcode >= 8 and (not fin or length > 125) then invalid("Invalid WebSocket control frame"); return end
			if #buffer < offset + length - 1 then return end
			local data = buffer:sub(offset, offset + length - 1)
			buffer = buffer:sub(offset + length)
			if opcode == 8 then
				if length == 1 then invalid("Invalid WebSocket close frame"); return end
				local code = length >= 2 and (data:byte(1) * 256 + data:byte(2)) or 1000
				if not ((code >= 1000 and code <= 1014 and not vim.tbl_contains({ 1004, 1005, 1006 }, code)) or (code >= 3000 and code <= 4999)) then
					invalid("Invalid WebSocket close code"); return
				end
				send(8, data)
				if code >= 4000 or code == 1008 then finish({ close_code = code, message = "Terminal connection closed (code " .. code .. ")" }, "unavailable")
				else finish(nil, "eof") end
				return
			elseif opcode == 9 then send(10, data)
			elseif opcode == 10 then -- Pong.
			elseif opcode == 1 or opcode == 2 or opcode == 0 then
				if (opcode == 0 and not fragmented) or (opcode ~= 0 and fragmented) then invalid("Invalid WebSocket continuation"); return end
				if opcode ~= 0 then fragmented = opcode end
				chunks[#chunks + 1], total = data, total + length
				if fin then
					local kind, message = fragmented, table.concat(chunks)
					fragmented, chunks, total = nil, {}, 0
					schedule(opts.on_message, kind, message)
				end
			else invalid("Unsupported WebSocket opcode"); return end
		end
	end
	local function read(err, data)
		if not active then return end
		if err then finish({ message = "WebSocket read failed" }, "read_error"); return end
		if not data then finish(nil, "eof"); return end
		buffer = buffer .. data
		if not ready then
			local boundary = buffer:find("\r\n\r\n", 1, true)
			if not boundary then if #buffer > MAX_HEADER then invalid("WebSocket headers exceeded 64 KiB") end; return end
			if boundary > MAX_HEADER then invalid("WebSocket headers exceeded 64 KiB"); return end
			local header = buffer:sub(1, boundary - 1)
			local status = tonumber(header:match("^HTTP/1%.[01] (%d%d%d)"))
			local response = {}
			for name, value in header:gmatch("\r\n([^:]+):%s*([^\r\n]+)") do
				name, value = name:lower(), vim.trim(value)
				if response[name] then invalid("Duplicate WebSocket response header"); return end
				response[name] = value
			end
			if status ~= 101 then finish({ status = status, message = "WebSocket upgrade rejected (HTTP " .. tostring(status) .. ")" }); return end
			if (response.upgrade or ""):lower() ~= "websocket" or not ("," .. (response.connection or ""):lower():gsub("%s", "") .. ","):find(",upgrade,", 1, true)
				or response["sec-websocket-accept"] ~= accept then invalid("Invalid WebSocket upgrade handshake"); return end
			ready = true
			if connection then connection.stop_timeout() end
			buffer = buffer:sub(boundary + 4)
			schedule(opts.on_open)
		end
		parse_frames()
	end
	local backend = endpoint.scheme == "https" and require("opencode.client.tls_connection") or require("opencode.client.tcp_connection")
	local open_err
	connection, open_err = backend.open({ host = endpoint.host, port = endpoint.port, tls = opts.tls, data = table.concat(request, "\r\n"), timeout = 10000,
		on_read = read, on_error = function(_, err) finish(err, "connection_error") end })
	if not connection then active = false; return nil, open_err end
	if not active then connection.close() end
	return socket
end

return M
