-- Native persistent PTY attachment. Terminal rendering belongs to the UI.
local M = {}
local client = require("opencode.client")
local state = require("opencode.state")
local pending = require("opencode.session.pending")

local function count(value)
	return type(value) == "number" and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end

local function dimensions(cols, rows)
	return count(cols) and count(rows) and cols > 0 and rows > 0 and cols <= 65535 and rows <= 65535
end

function M.connect(opts)
	local config, token = client.endpoint_config(), pending.token(opts.session_id)
	if type(opts.id) ~= "string" or not opts.id:match("^pty") or type(opts.attachment_id) ~= "string" or not count(opts.cursor or 0) then
		return nil, { message = "Invalid persistent terminal attachment" }
	end
	local stream, closed, attached, ready, offset = nil, false, false, false, opts.cursor or 0
	local handle = {}
	local function current()
		return not closed and pending.is_current(token) and client.endpoint_config().generation == config.generation
			and state.get_session().id == opts.session_id and state.get_session_directory(opts.session_id) == opts.directory
	end
	local watch
	function handle.close(reason)
		if closed then return end
		closed = true; state.off("*", watch)
		if stream then stream.close(); stream = nil end
		if reason and opts.on_close then opts.on_close(reason, offset) end
	end
	watch = function() if not current() then handle.close("stale") end end
	local function fail(message)
		handle.close("protocol_error")
		if opts.on_error then opts.on_error({ code = "pty_protocol", message = message }) end
	end
	local function interact(kind, cols, rows, data)
		if not current() or not attached or not ready or not dimensions(cols, rows) or not stream then return false end
		local header = string.char(kind, math.floor(cols / 256), cols % 256, math.floor(rows / 256), rows % 256)
		return stream.send(header .. (data or ""))
	end
	function handle.control(cols, rows) return interact(0, cols, rows) end
	function handle.input(data, cols, rows)
		if type(data) ~= "string" or #data > 1024 * 1024 then return false end
		-- Bound each input frame, including large pastes, without replaying input on reconnect.
		for start = 1, #data, 65536 do if not interact(1, cols, rows, data:sub(start, start + 65535)) then return false end end
		return true
	end
	function handle.cursor() return offset end
	function handle.is_ready() return current() and ready end
	state.on("*", watch)
	if not current() then handle.close(); return nil, { code = "stale_connection", message = "Terminal session or location changed" } end
	local encode = require("opencode.util.text").encode_uri_component
	local path = "/api/experimental/persistent-pty/" .. encode(opts.id) .. "/connect?cursor=" .. offset
		.. "&role=controller&attachment_id=" .. encode(opts.attachment_id) .. "&takeover=true&input_protocol=1"
	local open_err
	stream, open_err = require("opencode.client.websocket").open(vim.tbl_extend("force", config, { path = path,
		on_message = function(opcode, data)
			if not current() then handle.close(); return end
			if opcode == 2 then
				if not attached then fail("Terminal output arrived before attachment"); return end
				if not count(offset + #data) then fail("Invalid terminal output cursor"); return end
				offset = offset + #data
				if opts.on_data then opts.on_data(data, offset) end
				return
			end
			local ok, event = pcall(vim.json.decode, data)
			if not ok or type(event) ~= "table" or type(event.type) ~= "string" then fail("Invalid terminal control event"); return end
			if event.type == "attached" then
				if attached or event.inputProtocol ~= 1 or event.attachmentID ~= opts.attachment_id
					or require("opencode.client.v2").validate_pty(event.info) or event.info.id ~= opts.id or event.info.sessionID ~= opts.session_id
					or type(event.replay) ~= "table" or not count(event.replay.availableOffset) or not count(event.replay.endOffset)
					or event.replay.requestedOffset ~= offset or type(event.replay.truncated) ~= "boolean"
					or event.replay.availableOffset > event.replay.endOffset then fail("Invalid persistent terminal attachment response"); return end
				if event.replay.truncated or event.replay.availableOffset ~= offset or event.replay.endOffset - offset > 8 * 1024 * 1024 then
					handle.close()
					if opts.on_event then opts.on_event({ type = "resync" }, offset) end
					return
				end
				attached = true
			elseif not attached then fail("Terminal control arrived before attachment"); return
			elseif event.type == "replay_complete" then
				if not attached or not count(event.endOffset) or event.endOffset ~= offset then fail("Incomplete terminal replay"); return end
				ready = true
			elseif event.type == "resized" then
				if not dimensions(event.cols, event.rows) or type(event.checkpoint) ~= "string" or #event.checkpoint > 12 * 1024 * 1024 then fail("Invalid terminal resize event"); return end
			elseif event.type == "exited" then ready = false
			end
			if opts.on_event then opts.on_event(event, offset) end
		end,
		on_error = function(err)
			if current() and opts.on_error then opts.on_error(err) end
		end,
		on_close = function(reason)
			if not current() then handle.close(); return end
			ready = false
			state.off("*", watch)
			if opts.on_close then opts.on_close(reason, offset) end
		end,
	}))
	if not stream then handle.close(); return nil, open_err end
	if closed then stream.close() end
	return handle
end

return M
