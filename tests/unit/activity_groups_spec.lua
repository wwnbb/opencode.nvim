local activity = require("opencode.ui.chat.activity")
local sync = require("opencode.sync")

local function thought(id, text, time)
	return { id = id, type = "reasoning", text = text or "Reasoning", time = time }
end

local function tool(id, name, status, input)
	return { id = id, type = "tool", tool = name, state = { status = status or "completed", input = input or {} } }
end

local function collect(steps, interaction)
	local messages, parts = {}, {}
	for i, step in ipairs(steps) do
		local message = { id = "m" .. i, sessionID = "s", role = step.role or "assistant", finish = step.finish }
		messages[#messages + 1] = message
		parts[message.id] = { parts = step.parts or {} }
	end
	return activity.collect(messages, function(id) return parts[id] end, interaction)
end

local function text(group, expanded)
	return table.concat(activity.render(group, expanded).lines, "\n")
end

describe("Thought and Explore groups", function()
	before_each(function()
		sync.clear_all()
		require("opencode.state").set_config({ thinking = { enabled = true } })
	end)

	it("groups consecutive reasoning across steps and sums v2 durations", function()
		local groups = collect({
			{ parts = { thought("a", "first", { created = 100, completed = 316 }) } },
			{ parts = { thought("b", "second", { created = 500, completed = 4100 }) }, finish = "stop" },
		})
		assert.equals(groups.a, groups.b)
		assert.is_truthy(text(groups.a):find("+ Thought · 2 steps · 3.8s", 1, true))
		assert.is_nil(text(groups.a):find("first", 1, true))
		assert.is_truthy(text(groups.a, true):find("▏  second", 1, true))
	end)

	it("counts reads and searches across assistant steps without dumping file output", function()
		local read = tool("a", "read", "completed", { filePath = "Cargo.toml" })
		read.state.output = "hidden file output"
		local groups = collect({ { parts = { read } }, { parts = {
			tool("b", "grep", "completed", { pattern = "main" }), tool("c", "glob", "completed", { pattern = "*.rs" }),
		} } })
		assert.equals(groups.a, groups.c)
		assert.is_truthy(text(groups.a):find("→ Explored — 1 read, 2 searches", 1, true))
		assert.is_nil(text(groups.a):find("Cargo.toml", 1, true))
		assert.is_truthy(text(groups.a, true):find("↘ Explored — 1 read, 2 searches", 1, true))
		assert.is_truthy(text(groups.a, true):find("\n → Read Cargo.toml", 1, true))
		assert.is_truthy(text(groups.a, true):find('\n ● Grep "main"', 1, true))
		assert.is_nil(text(groups.a, true):find("hidden file output", 1, true))
	end)

	it("keeps text, other tools, user messages and final answers as boundaries", function()
		local groups = collect({
			{ parts = { tool("a", "read"), { type = "text", text = "answer" }, tool("b", "read"),
				tool("shell", "bash"), tool("c", "read") }, finish = "stop" },
			{ parts = { tool("d", "read") } }, { role = "user" }, { parts = { tool("e", "read") } },
		})
		for _, id in ipairs({ "a", "b", "c", "d", "e" }) do assert.equals(id, groups[id].first_part_id) end
	end)

	it("includes rg in consecutive exploration across assistant steps", function()
		local groups = collect({
			{ parts = { tool("read", "read"), tool("rg", "rg", "running", { pattern = "main" }) } },
			{ parts = { tool("glob", "glob"), tool("grep", "grep") } },
		})
		assert.equals(groups.read, groups.rg)
		assert.equals(groups.rg, groups.grep)
		assert.is_truthy(text(groups.read):find("Exploring — 1 read, 3 searches", 1, true))
		assert.is_nil(text(groups.read):find("main", 1, true))
	end)

	it("keeps rg permission requests outside exploration groups", function()
		local groups = collect({ { parts = {
			tool("before", "read"), tool("pending", "rg", "pending"), tool("after", "rg"),
		} } }, function(_, part) return part.id == "pending" end)
		assert.is_nil(groups.pending)
		assert.equals("before", groups.before.first_part_id)
		assert.equals("after", groups.after.first_part_id)
	end)

	it("keeps failed rg discoverable without forcing its details open", function()
		local failed = tool("rg", "rg", "error", { pattern = "[" })
		failed.state.error = "ripgrep failed: invalid regex"
		local groups = collect({ { parts = { tool("read", "read"), failed } } })
		local rendered = text(groups.read)
		assert.is_truthy(rendered:find("Explored — 1 read, 1 search", 1, true))
		assert.is_truthy(rendered:find("● rg [pattern=[]", 1, true))
		assert.is_nil(rendered:find("error: ripgrep failed: invalid regex", 1, true))
		local opened = activity.render(groups.read, false, { rg = true })
		assert.is_truthy(table.concat(opened.lines, "\n"):find("error: ripgrep failed: invalid regex", 1, true))
	end)

	it("does not hide permissions or suppress reasoning beside an interaction", function()
		local groups = collect({ { parts = { thought("t"), tool("pending", "read", "pending"), tool("done", "read") } } },
			function(_, part) return part.id == "pending" end)
		assert.is_not_nil(groups.t)
		assert.is_nil(groups.pending)
		assert.equals("done", groups.done.first_part_id)
	end)

	it("shows active status, retains errors while folded, and omits redacted thoughts", function()
		local failed = tool("error", "read", "error", { path = "missing.lua" })
		failed.state.error = "File not found"
		local groups = collect({ { parts = { thought("redacted", "[REDACTED]"), failed, tool("running", "read", "running") } } })
		assert.is_nil(groups.redacted)
		assert.is_truthy(text(groups.error):find("Exploring — 2 reads", 1, true))
		assert.is_truthy(text(groups.error):find("File not found", 1, true))
	end)
end)
