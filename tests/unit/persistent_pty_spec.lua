describe("native persistent PTY attachment protocol", function()
	local actions = require("opencode.actions")
	local state = require("opencode.state")
	local pending = require("opencode.session.pending")
	local stubs, socket, wire, sent, received, events, errors, closes, closed, generation, info
	local function event(value) wire.on_message(1, vim.json.encode(value)) end
	local function connect(cursor)
		local handle, err = actions.connect_terminal({ id = "pty_one", session_id = "s", directory = "/remote/project", cursor = cursor or 100,
			attachment_id = "attachment", on_data = function(data, offset) received[#received + 1] = { data, offset } end,
			on_event = function(value, offset) events[#events + 1] = { value, offset } end,
			on_error = function(err) errors[#errors + 1] = err end, on_close = function(reason, offset) closes[#closes + 1] = { reason, offset } end })
		assert.is_nil(err); return handle
	end
	local function attached(overrides)
		event(vim.tbl_extend("force", { type = "attached", attachmentID = "attachment", inputProtocol = 1, info = info,
			replay = { requestedOffset = 100, availableOffset = 100, endOffset = 104, truncated = false } }, overrides or {}))
	end
	before_each(function()
		state.reset(); pending.clear_all()
		state.upsert_session({ id = "s", title = "S", directory = "/remote/project" }); state.set_session("s", "S")
		stubs, sent, received, events, errors, closes, closed, generation = {}, {}, {}, {}, {}, {}, 0, 1
		info = { id = "pty_one", sessionID = "s", cwd = "/remote/project", title = "Terminal", command = "/bin/sh", args = {}, pid = 10,
			status = "running", size = { cols = 80, rows = 24 }, output = { head = 0, tail = 104 } }
		local stub = require("luassert.stub")
		stubs[#stubs + 1] = stub(require("opencode.client"), "endpoint_config", function() return { generation = generation, host = "localhost", port = 4096 } end)
		socket = { close = function() closed = closed + 1 end, send = function(data) sent[#sent + 1] = data; return true end }
		stubs[#stubs + 1] = stub(require("opencode.client.websocket"), "open", function(opts) wire = opts; return socket end)
	end)
	after_each(function()
		for index = #stubs, 1, -1 do stubs[index]:revert() end
		state.reset(); pending.clear_all()
	end)
	it("replays bytes from the cursor and sends framed control/input only once ready", function()
		local handle = connect()
		assert.truthy(wire.path:find("cursor=100&role=controller&attachment_id=attachment&takeover=true&input_protocol=1", 1, true))
		assert.is_false(handle.input("early", 80, 24))
		attached(); wire.on_message(2, "a\27[m")
		event({ type = "replay_complete", endOffset = 104 })
		assert.same({ { "a\27[m", 104 } }, received)
		assert.equals(104, handle.cursor()); assert.is_true(handle.is_ready())
		assert.is_true(handle.control(300, 24)); assert.is_true(handle.input("echo test\r", 300, 24))
		assert.equals("\0\1\44\0\24", sent[1])
		assert.equals("\1\1\44\0\24echo test\r", sent[2])
		handle.close()
	end)
	it("restores a truncated replay from a fresh snapshot rather than appending across a gap", function()
		local handle = connect()
		attached({ replay = { requestedOffset = 100, availableOffset = 200, endOffset = 220, truncated = true } })
		assert.equals(1, closed); assert.equals("resync", events[1][1].type)
		wire.on_message(2, "gap"); assert.equals(0, #received); assert.is_false(handle.is_ready())
	end)
	it("requires native ownership and complete replay offsets", function()
		local handle = connect()
		local wrong = vim.deepcopy(info); wrong.sessionID = "other"
		attached({ info = wrong }); assert.equals("pty_protocol", errors[1].code)
		handle = connect(); attached(); event({ type = "replay_complete", endOffset = 104 })
		assert.equals(2, #errors); assert.is_false(handle.is_ready())
	end)
	it("guards frames after session changes away and back, endpoint revision and deletion", function()
		for _, invalidation in ipairs({ "selection", "endpoint", "deleted" }) do
			state.set_session("s", "S")
			local handle = connect(); attached()
			if invalidation == "selection" then state.set_session("other", "Other"); state.set_session("s", "S")
			elseif invalidation == "endpoint" then generation = generation + 1
			else pending.clear_session("s") end
			wire.on_message(2, "late")
			assert.is_false(handle.input("late", 80, 24)); handle.close()
		end
		assert.equals(0, #received); assert.equals(0, #sent)
	end)
	it("rejects invalid dimensions, caps paste size and does not replay input after reconnect", function()
		local handle = connect(); attached(); wire.on_message(2, "1234"); event({ type = "replay_complete", endOffset = 104 })
		assert.is_false(handle.control(0, 24)); assert.is_false(handle.control(80, 65536))
		assert.is_false(handle.input(string.rep("x", 1024 * 1024 + 1), 80, 24))
		assert.is_true(handle.input(string.rep("x", 70000), 80, 24)); assert.equals(2, #sent)
		wire.on_close("eof"); assert.same({ { "eof", 104 } }, closes)
		assert.is_false(handle.is_ready()); assert.is_false(handle.input("after disconnect", 80, 24))
		handle.close()
	end)
end)
