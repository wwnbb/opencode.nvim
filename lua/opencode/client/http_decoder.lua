-- opencode.nvim - streaming HTTP response decoder

local M = {}

---@param message string
---@param extras? table
---@return table
local function make_error(message, extras)
	local err = {
		error = message,
		message = message,
	}

	if extras then
		for key, value in pairs(extras) do
			err[key] = value
		end
	end

	return err
end

---@param request_buffer string
---@return table|nil parsed
---@return string|nil remaining
---@return string|nil parse_error
local function parse_headers(request_buffer)
	local header_end = request_buffer:find("\r\n\r\n", 1, true)
	local delimiter_size = 4
	if not header_end then
		header_end = request_buffer:find("\n\n", 1, true)
		delimiter_size = 2
	end

	if not header_end then
		return nil, nil, nil
	end

	local header_blob = request_buffer:sub(1, header_end - 1)
	local remaining = request_buffer:sub(header_end + delimiter_size)
	local lines = {}
	for line in header_blob:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	local status_line = lines[1] or ""
	local status = tonumber(status_line:match("^HTTP/%d+%.%d+%s+(%d%d%d)"))
	if not status then
		return nil, nil, "Invalid HTTP status line: " .. status_line
	end

	local headers = {}
	for i = 2, #lines do
		local key, value = lines[i]:match("^([^:]+):%s*(.*)$")
		if key and value then
			local normalized = key:lower()
			local existing = headers[normalized]
			if existing then
				headers[normalized] = existing .. ", " .. value
			else
				headers[normalized] = value
			end
		end
	end

	return {
		status = status,
		headers = headers,
	}, remaining, nil
end

---@param callback function|nil
local function call(callback, ...)
	if type(callback) == "function" then
		callback(...)
	end
end

---@param opts table
---@return table
function M.new(opts)
	opts = opts or {}

	local state = {
		method = (opts.method or "GET"):upper(),
		headers_parsed = false,
		header_buffer = "",
		body_mode = "close",
		expected_length = nil,
		body_bytes = 0,
		chunk_buffer = "",
		chunk_size = nil,
		chunk_done = false,
		completed = false,
	}

	local decoder = {}

	local function emit_error(message)
		if state.completed then
			return
		end
		state.completed = true
		call(opts.on_error, make_error(message))
	end

	local function emit_complete()
		if state.completed then
			return
		end
		state.completed = true
		call(opts.on_complete)
	end

	local function emit_body(data)
		if data and data ~= "" then
			call(opts.on_body, data)
		end
	end

	local function decode_chunked()
		while true do
			if state.chunk_done then
				return true
			end

			if not state.chunk_size then
				local line_end = state.chunk_buffer:find("\r\n", 1, true)
				if not line_end then
					return false
				end

				local size_line = state.chunk_buffer:sub(1, line_end - 1)
				local size_hex = size_line:match("^%s*([0-9a-fA-F]+)")
				local parsed_size = size_hex and tonumber(size_hex, 16) or nil
				if not parsed_size then
					return nil, "Invalid chunk size"
				end

				state.chunk_size = parsed_size
				state.chunk_buffer = state.chunk_buffer:sub(line_end + 2)

				if state.chunk_size == 0 then
					local trailer_end = state.chunk_buffer:find("\r\n\r\n", 1, true)
					if trailer_end then
						state.chunk_buffer = state.chunk_buffer:sub(trailer_end + 4)
						state.chunk_done = true
						return true
					end
					if state.chunk_buffer:sub(1, 2) == "\r\n" then
						state.chunk_buffer = state.chunk_buffer:sub(3)
						state.chunk_done = true
						return true
					end
					return false
				end
			end

			local needed = state.chunk_size + 2
			if #state.chunk_buffer < needed then
				return false
			end

			local chunk = state.chunk_buffer:sub(1, state.chunk_size)
			local terminator = state.chunk_buffer:sub(state.chunk_size + 1, state.chunk_size + 2)
			if terminator ~= "\r\n" then
				return nil, "Invalid chunk terminator"
			end

			emit_body(chunk)
			state.chunk_buffer = state.chunk_buffer:sub(needed + 1)
			state.chunk_size = nil
		end
	end

	local function process_body(data)
		if state.completed or not data or data == "" then
			return
		end

		if state.body_mode == "none" then
			return
		end

		if state.body_mode == "length" then
			local remaining = (state.expected_length or 0) - state.body_bytes
			if remaining <= 0 then
				return
			end

			local body_piece = #data > remaining and data:sub(1, remaining) or data
			state.body_bytes = state.body_bytes + #body_piece
			emit_body(body_piece)

			if state.expected_length and state.body_bytes >= state.expected_length then
				emit_complete()
			end
			return
		end

		if state.body_mode == "chunked" then
			state.chunk_buffer = state.chunk_buffer .. data
			local ok, parse_err = decode_chunked()
			if ok == nil then
				emit_error("Failed to decode chunked response: " .. tostring(parse_err))
				return
			end
			if ok then
				emit_complete()
			end
			return
		end

		emit_body(data)
	end

	local function process_headers()
		local parsed, remaining, parse_err = parse_headers(state.header_buffer)
		if parse_err then
			emit_error(parse_err)
			return
		end
		if not parsed then
			return
		end

		state.headers_parsed = true
		state.header_buffer = ""

		call(opts.on_headers, parsed.status, parsed.headers)

		local transfer_encoding = (parsed.headers["transfer-encoding"] or ""):lower()
		local content_length = tonumber(parsed.headers["content-length"])
		local status = parsed.status

		if state.method == "HEAD" or status == 204 or status == 304 or (status >= 100 and status < 200) then
			state.body_mode = "none"
			emit_complete()
			return
		end

		if transfer_encoding:find("chunked", 1, true) then
			state.body_mode = "chunked"
		elseif content_length then
			state.expected_length = content_length
			if state.expected_length <= 0 then
				state.body_mode = "none"
				emit_complete()
				return
			end
			state.body_mode = "length"
		else
			state.body_mode = "close"
		end

		if remaining and remaining ~= "" then
			process_body(remaining)
		end
	end

	function decoder:push(data)
		if state.completed or not data or data == "" then
			return
		end

		if state.headers_parsed then
			process_body(data)
			return
		end

		state.header_buffer = state.header_buffer .. data
		process_headers()
	end

	function decoder:finish_eof()
		if state.completed then
			return
		end

		if not state.headers_parsed then
			emit_error("Connection closed before response headers")
			return
		end

		if state.body_mode == "close" then
			emit_complete()
			return
		end

		if state.body_mode == "length" then
			if state.expected_length and state.body_bytes >= state.expected_length then
				emit_complete()
				return
			end
			emit_error("Connection closed before full response body")
			return
		end

		if state.body_mode == "chunked" then
			if state.chunk_done then
				emit_complete()
				return
			end
			emit_error("Connection closed before chunked response completed")
			return
		end

		emit_complete()
	end

	function decoder:headers_parsed()
		return state.headers_parsed
	end

	return decoder
end

return M
