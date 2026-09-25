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

describe("Thought, Explore and Execute groups", function()
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

	it("groups execute invocations across steps and reveals only the selected call list", function()
		local first, second = tool("a", "execute"), tool("b", "execute")
		first.state.output, second.state.output = "first result", "second result"
		first.state.metadata = { toolCalls = { { tool = "mcp.search", status = "completed" } } }
		second.state.metadata = { toolCalls = { { tool = "mcp.read", status = "completed" } } }
		local groups = collect({ { parts = { first }, finish = "tool-calls" }, { parts = { second } } })
		assert.equals(groups.a, groups.b)
		assert.equals("activity:execute:a", groups.a.id)
		assert.equals("→ Executed — 2 calls", vim.trim(text(groups.a)))
		local leaves = activity.render(groups.a, true)
		assert.equals(4, #leaves.lines)
		assert.equals("a", leaves.children.a.id)
		assert.equals("b", leaves.children.b.id)
		assert.is_truthy(table.concat(leaves.lines, "\n"):find("mcp.search", 1, true))
		assert.is_nil(table.concat(leaves.lines, "\n"):find("result", 1, true))
		local opened = table.concat(activity.render(groups.a, true, { b = true }).lines, "\n")
		assert.is_truthy(opened:find("↳ ✓ mcp.read", 1, true))
		assert.is_nil(opened:find("↳ ✓ mcp.search", 1, true))
		assert.is_nil(opened:find("second result", 1, true))
		assert.is_nil(opened:find("first result", 1, true))
	end)

	it("keeps execute permissions outside groups and running status across a text boundary", function()
		local groups = collect({ { parts = {
			tool("before", "execute"), tool("permission", "execute", "pending"),
			tool("running", "execute", "running"), { type = "text", text = "Progress" }, tool("after", "execute"),
		} } }, function(_, part) return part.id == "permission" end)
		assert.is_nil(groups.permission)
		assert.equals("before", groups.before.first_part_id)
		assert.equals("running", groups.running.first_part_id)
		assert.equals("after", groups.after.first_part_id)
		assert.is_true(groups.running.completed)
		assert.is_true(activity.is_working(groups.running))
		assert.is_truthy(text(groups.running):find("Executing — 1 call", 1, true))
	end)

	it("keeps MCP child failures and cancelled execute visible without opening their results", function()
		local failed = tool("failed", "execute")
		failed.state.output = "details of failure"
		failed.state.metadata = { toolCalls = { { tool = "mcp.read", status = "error" } } }
		local cancelled = tool("cancelled", "execute", "cancelled")
		local groups = collect({ { parts = { tool("ok", "execute"), failed, cancelled } } })
		local closed = activity.render(groups.ok, false)
		local closed_text = table.concat(closed.lines, "\n")
		assert.is_truthy(closed_text:find("Executed — 3 calls · 2 failed", 1, true))
		assert.is_truthy(closed_text:find("mcp.read", 1, true))
		assert.is_nil(closed_text:find("details of failure", 1, true))
		assert.is_false(activity.is_working(groups.ok))
		local opened = table.concat(activity.render(groups.ok, false, { failed = true }).lines, "\n")
		assert.is_truthy(opened:find("↳ ✗ mcp.read", 1, true))
		assert.is_nil(opened:find("details of failure", 1, true))
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

-- Both tool families must keep the same container behavior even though their
-- leaf widgets format different inputs and results.
for _, family in ipairs({
	{ kind = "explore", tool = "read", done = "Explored", active = "Exploring", count = "reads" },
	{ kind = "execute", tool = "execute", done = "Executed", active = "Executing", count = "calls" },
}) do
	describe(family.kind .. " shared tool group behavior", function()
		before_each(function()
			sync.clear_all()
			require("opencode.state").set_config({ thinking = { enabled = true } })
		end)

		local function call(id, status)
			local part = tool(id, family.tool, status, { path = id .. ".txt", code = "return 1" })
			part.state.output = "private-result-" .. id
			if family.kind == "execute" then
				part.state.metadata = { toolCalls = { { tool = "mcp." .. id, status = "completed" } } }
			end
			return part
		end

		local function header_highlight(rendered)
			for _, hl in ipairs(rendered.highlights) do
				if hl.line == 0 then return hl.hl_group end
			end
		end

		it("shares grouping across steps and all visible boundaries", function()
			local groups = collect({
				{ parts = { call("a") }, finish = "tool-calls" },
				{ parts = { { type = "text", text = "  " }, call("b"),
					{ type = "text", text = "Progress" }, call("text"), tool("shell", "bash"),
					call("other"), call("permission", "pending"), call("after_permission") }, finish = "stop" },
				{ parts = { call("final") } }, { role = "user" }, { parts = { call("user") } },
			}, function(_, part) return part.id == "permission" end)
			assert.equals(groups.a, groups.b)
			assert.equals("activity:" .. family.kind .. ":a", groups.a.id)
			assert.is_nil(groups.permission)
			assert.is_nil(groups.shell)
			for _, id in ipairs({ "text", "other", "after_permission", "final", "user" }) do
				assert.equals(id, groups[id].first_part_id)
			end
		end)

		it("keeps explicit active status despite closed groups and stale completion timestamps", function()
			for _, status in ipairs({ "pending", "running", "streaming" }) do
				local active = call("active", status)
				active.state.time = { created = 1, completed = 2, start = 1, ["end"] = 2 }
				local groups = collect({ { parts = { active, { type = "text", text = "Progress" } }, finish = "stop" } })
				assert.is_true(groups.active.completed)
				assert.is_true(activity.is_working(groups.active), status)
				local rendered = activity.render(groups.active, false)
				assert.is_truthy(rendered.lines[1]:find(family.active .. " — ", 1, true))
				assert.equals("OpenCodeToolGroup", header_highlight(rendered))
			end
		end)

		it("treats terminal states as finished even without completion timestamps", function()
			for _, status in ipairs({ "completed", "error", "cancelled", "canceled", "interrupted" }) do
				local groups = collect({ { parts = { call("terminal", status) } } })
				assert.is_false(activity.is_working(groups.terminal), status)
				assert.is_truthy(text(groups.terminal):find(family.done .. " — ", 1, true))
			end
		end)

		it("uses completion timestamps when a historical tool has no status", function()
			for _, completed_time in ipairs({ { completed = 20 }, { ["end"] = 20 } }) do
				local historical = call("historical")
				historical.state.status = nil
				historical.state.time = completed_time
				local groups = collect({ { parts = { historical } } })
				assert.is_false(activity.is_working(groups.historical))
				assert.is_truthy(text(groups.historical):find(family.done .. " — ", 1, true))
			end
		end)

		it("resolves current sync status instead of retaining the collected status", function()
			local original = call("live", "running")
			local groups = collect({ { parts = { original }, finish = "stop" } })
			assert.is_true(activity.is_working(groups.live))
			local updated = call("live", "completed")
			updated.messageID, updated.sessionID = "m1", "s"
			sync.handle_part_updated(updated)
			assert.is_false(activity.is_working(groups.live))
			assert.is_truthy(text(groups.live):find(family.done .. " — ", 1, true))
		end)

		it("keeps failed leaves reachable and uses the same themed error header", function()
			for _, failure in ipairs({
				{ status = "error" },
				{ status = "completed", error = "tool failed" },
				{ status = "completed", metadata = { error = true } },
				{ status = "cancelled" },
				{ status = "canceled" },
				{ status = "interrupted" },
			}) do
				local failed = call("failed")
				failed.state = vim.tbl_deep_extend("force", failed.state, failure)
				local groups = collect({ { parts = { call("ok"), failed } } })
				local rendered = activity.render(groups.ok, false)
				assert.is_truthy(rendered.lines[1]:find("2 " .. family.count .. " · 1 failed", 1, true))
				assert.equals("OpenCodeActivityError", header_highlight(rendered))
				assert.is_nil(rendered.children.ok.start_line)
				assert.is_not_nil(rendered.children.failed.start_line)
				assert.is_nil(table.concat(rendered.lines, "\n"):find("private-result-failed", 1, true))
				local opened = activity.render(groups.ok, false, { failed = true })
				assert.is_true(opened.children.failed.end_line - opened.children.failed.start_line
					> rendered.children.failed.end_line - rendered.children.failed.start_line)
			end
		end)

		it("does not treat absent or empty errors as failures", function()
			for _, empty in ipairs({ "", "  ", false, vim.NIL }) do
				local healthy = call("healthy")
				healthy.state.error = empty
				healthy.state.metadata = { error = false }
				local groups = collect({ { parts = { healthy } } })
				local rendered = activity.render(groups.healthy, false)
				assert.is_nil(rendered.lines[1]:find("failed", 1, true))
				assert.equals("OpenCodeToolGroup", header_highlight(rendered))
				assert.is_nil(rendered.children.healthy.start_line)
			end
		end)

		it("preserves hidden identities and reveals only independently expanded leaves", function()
			local groups = collect({ { parts = { call("first"), call("second") } } })
			local expansions = { second = true }
			local closed = activity.render(groups.first, false, expansions)
			for _, id in ipairs({ "first", "second" }) do
				assert.equals(id, closed.children[id].part_id)
				assert.equals("m1", closed.children[id].message_id)
				assert.equals("s", closed.children[id].session_id)
				assert.is_nil(closed.children[id].start_line)
			end
			assert.equals(2, #closed.lines)
			local opened = activity.render(groups.first, true, expansions)
			local body = table.concat(opened.lines, "\n")
			assert.is_nil(body:find("private-result-first", 1, true))
			if family.kind == "execute" then
				assert.is_truthy(body:find("↳ ✓ mcp.second", 1, true))
				assert.is_nil(body:find("↳ ✓ mcp.first", 1, true))
				assert.is_nil(body:find("private-result-second", 1, true))
			else
				assert.is_truthy(body:find("private-result-second", 1, true))
			end
			assert.is_true(opened.children.second.start_line > opened.children.first.end_line)
			assert.same({ second = true }, expansions)
			local tree = require("opencode.ui.chat.widget_tree")
			local positions = tree.positions(opened.children, 10, 1)
			assert.equals(opened.children.second.start_line + 10, positions.second.start_line)
			tree.collapse(opened.children, expansions)
			assert.same({}, expansions)
		end)
	end)
end
