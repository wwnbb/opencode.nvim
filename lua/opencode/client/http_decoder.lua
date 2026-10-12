-- opencode.nvim - streaming HTTP response decoder

local M = {}
local MAX_EXACT_INTEGER = 9007199254740991

local function parse_fields(lines, first)
	local headers, previous = {}, nil
	for i = first or 1, #lines do
		local line = lines[i]:gsub("\r$", "")
		local folded = line:match("^[ \t]")
		local key, value
		if folded then
			if not previous then return nil end
			value = line:match("^[ \t]+(.-)[ \t]*$")
		else
			key, value = line:match("^([^:]+):[ \t]*(.-)[ \t]*$")
			if not key or not key:match("^[!#$%%&'*+.^_`|~%w-]+$") then return nil end
		end
		if value:find("[%z\1-\8\10-\31\127]") then return nil end
		if folded then
			headers[previous] = (headers[previous] .. " " .. value):match("^[ \t]*(.-)[ \t]*$")
		else
			previous = key:lower()
			local existing = headers[previous]
			headers[previous] = existing and (existing .. ", " .. value) or value
		end
	end
	return headers
end

---@param request_buffer string
---@return table|nil parsed
---@return string|nil remaining
---@return string|nil parse_error
local function parse_headers(request_buffer)
	local header_end, delimiter_end = request_buffer:find("\r?\n\r?\n")

	if not header_end then
		return nil, nil, nil
	end

	local header_blob = request_buffer:sub(1, header_end - 1)
	local remaining = request_buffer:sub(delimiter_end + 1)
	local lines = vim.split(header_blob, "\n", { plain = true })
	local status_line = (lines[1] or ""):gsub("\r$", "")
	local version, status_code, reason = status_line:match("^HTTP/(%d%.%d)%s+(%d%d%d)(.*)$")
	local status = tonumber(status_code)
	if not status or (reason ~= "" and not reason:match("^%s")) then
		return nil, nil, "Invalid HTTP status line: " .. status_line
	end

	local headers = parse_fields(lines, 2)
	if not headers then return nil, nil, "Invalid HTTP header line" end
	if version == "1.0" and headers["transfer-encoding"] ~= nil then
		return nil, nil, "Transfer-Encoding is invalid in HTTP/1.0"
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
		body_bytes = 0,
		chunk_buffer = "",
		chunk_parts = {},
		chunk_bytes = 0,
		completed = false,
	}

	local decoder = {}

	local function emit_error(message)
		if state.completed then
			return
		end
		state.completed = true
		call(opts.on_error, { error = message, message = message })
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
			if not state.chunk_size then
				local line_end = state.chunk_buffer:find("\r\n", 1, true)
				if not line_end then
					return false
				end

				local size_line = state.chunk_buffer:sub(1, line_end - 1)
				local size_hex, extension = size_line:match("^%s*([0-9a-fA-F]+)%s*(.*)$")
				local parsed_size = size_hex and tonumber(size_hex, 16) or nil
				if not parsed_size or parsed_size < 0 or parsed_size > MAX_EXACT_INTEGER
					or (extension ~= "" and extension:sub(1, 1) ~= ";") then
					return nil, "Invalid chunk size"
				end

				state.chunk_size = parsed_size
				state.chunk_buffer = state.chunk_buffer:sub(line_end + 2)
			end

			-- Keep reading trailers after a split zero-size chunk header.
			if state.chunk_size == 0 then
				if state.chunk_buffer:sub(1, 2) == "\r\n" then
					state.chunk_buffer = state.chunk_buffer:sub(3)
					return true
				end
				local trailer_end = state.chunk_buffer:find("\r\n\r\n", 1, true)
				if trailer_end then
					local fields = parse_fields(vim.split(state.chunk_buffer:sub(1, trailer_end - 1), "\n", { plain = true }))
					if not fields then return nil, "Invalid HTTP trailer line" end
					state.chunk_buffer = state.chunk_buffer:sub(trailer_end + 4)
					return true
				end
				return false
			end

			local take = math.min(state.chunk_size - state.chunk_bytes, #state.chunk_buffer)
			if take > 0 then
				state.chunk_parts[#state.chunk_parts + 1] = state.chunk_buffer:sub(1, take)
				state.chunk_bytes = state.chunk_bytes + take
				state.chunk_buffer = state.chunk_buffer:sub(take + 1)
			end
			if state.chunk_bytes < state.chunk_size or #state.chunk_buffer < 2 then return false end
			if state.chunk_buffer:sub(1, 2) ~= "\r\n" then return nil, "Invalid chunk terminator" end

			local chunk = table.concat(state.chunk_parts)
			state.chunk_buffer = state.chunk_buffer:sub(3)
			state.chunk_size, state.chunk_bytes, state.chunk_parts = nil, 0, {}
			emit_body(chunk)
		end
	end

	local function process_body(data)
		if state.completed or not data or data == "" then
			return
		end

		if state.body_mode == "length" then
			local remaining = state.expected_length - state.body_bytes
			if remaining <= 0 then
				return
			end

			local body_piece = #data > remaining and data:sub(1, remaining) or data
			state.body_bytes = state.body_bytes + #body_piece
			emit_body(body_piece)

			if state.body_bytes >= state.expected_length then
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
		-- Informational responses precede the final HTTP response. A 101 ends
		-- HTTP framing instead; upgraded protocols are not decoded here.
		while parsed and parsed.status >= 100 and parsed.status < 200 and parsed.status ~= 101 do
			state.header_buffer = remaining
			parsed, remaining, parse_err = parse_headers(state.header_buffer)
		end
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
		local raw_length = parsed.headers["content-length"]
		local content_length
		local status = parsed.status

		if state.method == "HEAD" or status == 204 or status == 304 or (status >= 100 and status < 200) then
			emit_complete()
			return
		end

		if transfer_encoding:match("^chunked%s*$") or transfer_encoding:match(",%s*chunked%s*$") then
			state.body_mode = "chunked"
		elseif transfer_encoding ~= "" then
			state.body_mode = "close"
		elseif raw_length then
			for value in (raw_length .. ","):gmatch("(.-),") do
				local digits = value:match("^%s*(%d+)%s*$")
				local length = digits and tonumber(digits)
				if not length or length > MAX_EXACT_INTEGER or (content_length and content_length ~= length) then
					emit_error("Invalid Content-Length")
					return
				end
				content_length = length
			end
			state.expected_length = content_length
			if state.expected_length <= 0 then
				emit_complete()
				return
			end
			state.body_mode = "length"
		else
			state.body_mode = "close"
		end

		process_body(remaining)
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

		-- A direct on_body callback may reenter EOF before process_body completes.
		if state.body_mode == "length" then
			if state.body_bytes >= state.expected_length then
				emit_complete()
				return
			end
			emit_error("Connection closed before full response body")
			return
		end

		if state.body_mode == "chunked" then
			emit_error("Connection closed before chunked response completed")
			return
		end
	end

	function decoder:headers_parsed()
		return state.headers_parsed
	end

	return decoder
end

return M
