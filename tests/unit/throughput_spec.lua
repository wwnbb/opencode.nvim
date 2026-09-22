local throughput = require("opencode.ui.chat.throughput")

local function assistant(id, created, streamed, output, reasoning)
	return {
		id = id,
		type = "assistant",
		time = { created = created, streamed = streamed, completed = (streamed or created) + 60000 },
		tokens = { input = 10000, output = output, reasoning = reasoning, cache = { read = 5000, write = 1000 } },
	}
end

describe("turn throughput", function()
	it("weights model steps by request time and excludes tool execution, input and cache tokens", function()
		local messages = {
			{ type = "user" },
			assistant("a", 1000, 2000, 60, 40),
			assistant("b", 62000, 66000, 80, 20),
		}
		local original = vim.deepcopy(messages)
		assert.same({ a = 100, b = 40 }, throughput.by_message(messages))
		assert.same(original, messages)
	end)

	it("keeps steering prompts in a native turn and resets at idle boundaries", function()
		assert.same({ a = 100, b = 40, c = 10, d = 20 }, throughput.by_message({
			{ type = "user" },
			assistant("a", 0, 1000, 100),
			{ type = "user" },
			{ type = "synthetic" },
			{ type = "model-switched" },
			assistant("b", 2000, 6000, 100),
			{ type = "idle", hidden = true },
			{ type = "user" },
			assistant("c", 7000, 8000, 10),
			{ type = "idle", hidden = true },
			assistant("d", 9000, 10000, 20),
		}))
	end)

	it("uses the most recent user or synthetic prompt when history has no idle markers", function()
		assert.same({ a = 100, b = 25, c = 10 }, throughput.by_message({
			{ role = "user" },
			assistant("a", 0, 1000, 100),
			{ role = "user" },
			assistant("b", 2000, 6000, 100),
			{ type = "synthetic" },
			assistant("c", 7000, 8000, 10),
		}))
	end)

	it("hides a turn with unfinished or missing timing instead of substituting completion time", function()
		local first = assistant("a", 0, nil, 100)
		local second = assistant("b", 2000, 3000, 100)
		assert.same({}, throughput.by_message({ first, second }))
		first.time.streamed = 1000
		assert.same({ a = 100, b = 100 }, throughput.by_message({ first, second }))
		second.time.streamed = nil
		assert.same({ a = 100 }, throughput.by_message({ first, second }))
	end)

	it("omits empty, zero-time and invalid metrics and recovers for the next turn", function()
		assert.same({}, throughput.by_message({}))
		local cases = {
			assistant("a", 0, 1000, 0, 0),
			assistant("a", 1000, 1000, 100),
			assistant("a", 2000, 1000, 100),
			assistant("a", 0, 1000, -1),
			assistant("a", 0, 1000, math.huge),
			assistant("a", 0, 1000, "100"),
			assistant("a", 0, 1000, 0 / 0),
			assistant("a", 0, math.huge, 100),
			{ id = "a", type = "assistant" },
		}
		for _, message in ipairs(cases) do
			assert.same({}, throughput.by_message({ message }))
			assert.same({ b = 50 }, throughput.by_message({
				message, { type = "idle" }, { type = "user" }, assistant("b", 0, 1000, 50),
			}))
		end
		assert.same({ a = 20 }, throughput.by_message({ assistant("a", 0, 1000, nil, 20) }))
	end)

	it("derives identical rates from recorded SSE and HTTP history", function()
		local sync = require("opencode.sync")
		local projection = require("opencode.protocol.v2.messages")
		local function fixture(name)
			return vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/runtime/" .. name .. ".json"), "\n"))
		end
		sync.clear_all()
		local ok, err = xpcall(function()
			local sid = fixture("session").data.id
			for _, event in ipairs(fixture("events")) do
				sync.handle_v2_event(event)
				if event.type == "session.execution.succeeded" then break end
			end
			local live = throughput.by_message(sync.get_messages(sid))
			local id = "msg_0c5cc4dcb001Wl1MEph2QletdJ"
			assert.equals(28 / 3.678, live[id])
			sync.clear_all()
			sync.handle_session_messages(sid, projection.page(sid, fixture("history").data))
			assert.same(live, throughput.by_message(sync.get_messages(sid)))
		end, debug.traceback)
		sync.clear_all()
		assert.is_true(ok, err)
	end)
end)
