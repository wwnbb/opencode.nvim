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

local function header_highlight(rendered)
	for _, hl in ipairs(rendered.highlights) do
		if hl.line == 0 then return hl.hl_group end
	end
end

describe("Thought, Explore, Execute and Web groups", function()
	local function read(id, status) return tool(id, "read", status) end
	before_each(function()
		sync.clear_all()
		require("opencode.state").set_config({ thinking = { enabled = true } })
	end)

	it("groups consecutive reasoning across steps and sums durations", function()
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
			tool("b", "grep", "completed", { pattern = "main" }), tool("c", "glob", "completed", { pattern = "*.rs" }), tool("d", "rg"),
		} } })
		assert.equals(groups.a, groups.c)
		assert.is_truthy(text(groups.a):find("→ Explored — 1 read, 3 searches", 1, true))
		assert.is_nil(text(groups.a):find("Cargo.toml", 1, true))
		assert.is_truthy(text(groups.a, true):find("↘ Explored — 1 read, 3 searches", 1, true))
		assert.is_truthy(text(groups.a, true):find("\n → Read Cargo.toml", 1, true))
		assert.is_truthy(text(groups.a, true):find('\n ● Grep "main"', 1, true))
		assert.is_nil(text(groups.a, true):find("hidden file output", 1, true))
	end)

	it("groups web searches and fetches across steps and counts each request kind", function()
		local first = tool("search", "websearch", "completed", { query = "Lua coroutine" })
		local fetch = tool("fetch", "webfetch", "completed", { url = "https://example.com/lua" })
		first.state.output, fetch.state.output = "private search result", "private page body"
		local groups = collect({
			{ parts = { first }, finish = "tool-calls" },
			{ parts = { fetch, tool("search2", "websearch"), tool("fetch2", "webfetch") } },
		})
		assert.equals(groups.search, groups.fetch)
		assert.equals(groups.search, groups.fetch2)
		assert.equals("activity:web:search", groups.search.id)
		assert.equals("→ Browsed — 2 searches, 2 fetches", vim.trim(text(groups.search)))
		local collapsed = activity.render(groups.search, false)
		assert.is_nil(collapsed.children.search.start_line)
		assert.is_nil(collapsed.children.fetch.start_line)
		local expanded = activity.render(groups.search, true, { fetch = true })
		local body = table.concat(expanded.lines, "\n")
		assert.is_truthy(body:find("Lua coroutine", 1, true))
		assert.is_truthy(body:find("https://example.com/lua", 1, true))
		assert.is_truthy(body:find("private page body", 1, true))
		assert.is_nil(body:find("private search result", 1, true))
	end)

	it("keeps web requests separate from local exploration, execution and permissions", function()
		local groups = collect({ { parts = {
			tool("first", "websearch"), tool("read", "read"), tool("after_read", "webfetch"),
			tool("execute", "execute"), tool("after_execute", "websearch"),
			tool("permission", "webfetch", "pending"), tool("after_permission", "webfetch"),
		} } }, function(_, part) return part.id == "permission" end)
		assert.is_nil(groups.permission)
		assert.equals("explore", groups.read.kind)
		assert.equals("execute", groups.execute.kind)
		for _, id in ipairs({ "first", "after_read", "after_execute", "after_permission" }) do
			assert.equals("web", groups[id].kind)
			assert.equals(id, groups[id].first_part_id)
		end
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
		local groups = collect({ { parts = { thought("t"), tool("pending", "rg", "pending"), tool("done", "read") } } },
			function(_, part) return part.id == "pending" end)
		assert.is_not_nil(groups.t)
		assert.is_nil(groups.pending)
		assert.equals("done", groups.done.first_part_id)
	end)

	it("shares grouping across steps and all visible boundaries", function()
		local groups = collect({
			{ parts = { read("a") }, finish = "tool-calls" },
			{ parts = { { type = "text", text = "  " }, read("b"),
				{ type = "text", text = "Progress" }, read("text"), tool("shell", "bash"),
				read("other"), read("permission", "pending"), read("after_permission") }, finish = "stop" },
			{ parts = { read("final") } }, { role = "user" }, { parts = { read("user") } },
		}, function(_, part) return part.id == "permission" end)
		assert.equals(groups.a, groups.b)
		assert.equals("activity:explore:a", groups.a.id)
		assert.is_nil(groups.permission)
		assert.is_nil(groups.shell)
		for _, id in ipairs({ "text", "other", "after_permission", "final", "user" }) do
			assert.equals(id, groups[id].first_part_id)
		end
	end)

	it("resolves current sync status instead of retaining the collected status", function()
		local original = read("live", "running")
		local groups = collect({ { parts = { original }, finish = "stop" } })
		assert.is_true(activity.is_working(groups.live))
		assert.is_truthy(text(groups.live):find("Exploring — ", 1, true))
		local updated = read("live", "completed")
		updated.messageID, updated.sessionID = "m1", "s"
		sync.handle_part_updated(updated)
		assert.is_false(activity.is_working(groups.live))
		assert.is_truthy(text(groups.live):find("Explored — ", 1, true))
	end)

	it("colors the group by the latest call while retaining earlier failures", function()
		local failed = read("failed", "error")
		for _, status in ipairs({ "completed", "running", "pending", "error" }) do
			local latest = read("latest", status)
			local groups = collect({ { parts = { failed } }, { parts = { latest } } })
			for _, expanded in ipairs({ false, true }) do
				local rendered = activity.render(groups.failed, expanded)
				assert.equals(status == "error" and "OpenCodeActivityError" or "OpenCodeToolGroup",
					header_highlight(rendered))
				assert.is_not_nil(rendered.children.failed.start_line)
				assert.is_truthy(rendered.lines[1]:find("failed", 1, true))
			end
		end
	end)

	it("follows explicit status before historical timestamps in the shared tool classifier", function()
		for _, case in ipairs({
			{ status = "pending", working = true }, { status = "running", working = true },
			{ status = "streaming", working = true }, { status = "completed", working = false },
			{ status = "error", working = false }, { status = "cancelled", working = false },
			{ status = "canceled", working = false }, { status = "interrupted", working = false },
			{ time = { completed = 20 }, working = false }, { time = { ["end"] = 20 }, working = false },
		}) do
			local part = tool("status", "read")
			part.state.status = case.status
			part.state.time = case.time or (case.working and { created = 1, completed = 2, start = 1, ["end"] = 2 } or nil)
			local groups = collect({ { parts = { part, { type = "text", text = "Progress" } }, finish = "stop" } })
			assert.is_true(groups.status.completed)
			assert.equals(case.working, activity.is_working(groups.status), vim.inspect(case))
			assert.is_truthy(text(groups.status):find(case.working and "Exploring" or "Explored", 1, true))
		end
	end)

	it("recognizes explicit, metadata and cancellation failures in the shared classifier", function()
		local policy = require("opencode.ui.chat.tool_group")
		for _, failure in ipairs({
			{ status = "error" }, { status = "completed", error = "tool failed" },
			{ status = "completed", metadata = { error = true } },
			{ status = "cancelled" }, { status = "canceled" }, { status = "interrupted" },
		}) do
			local part = tool("failed", "read")
			part.state = vim.tbl_deep_extend("force", part.state, failure)
			assert.is_true(policy.failed(part), vim.inspect(failure))
			assert.is_true(policy.latest_failed(part), vim.inspect(failure))
		end
	end)

	it("does not classify absent or empty error values as failures", function()
		local policy = require("opencode.ui.chat.tool_group")
		local part = tool("healthy", "read")
		assert.is_false(policy.failed(part))
		for _, empty in ipairs({ "", "  ", false, vim.NIL }) do
			part.state.error = empty
			part.state.metadata = { error = false }
			assert.is_false(policy.failed(part), vim.inspect(empty))
		end
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

-- All tool families must keep the same container behavior even though their
-- leaf widgets format different inputs and results.
for _, family in ipairs({
	{ kind = "explore", tool = "read", done = "Explored", active = "Exploring", count = "reads" },
	{ kind = "execute", tool = "execute", done = "Executed", active = "Executing", count = "calls" },
	{ kind = "web", tool = "websearch", done = "Browsed", active = "Browsing", count = "searches" },
	{ kind = "web", tool = "webfetch", done = "Browsed", active = "Browsing", count = "fetches" },
}) do
	describe(family.tool .. " shared tool group behavior", function()
		before_each(function()
			sync.clear_all()
			require("opencode.state").set_config({ thinking = { enabled = true } })
		end)

		local function call(id, status)
			local part = tool(id, family.tool, status, {
				path = id .. ".txt", code = "return 1", query = id, url = "https://example.com/" .. id,
			})
			part.state.output = "private-result-" .. id
			if family.kind == "execute" then
				part.state.metadata = { toolCalls = { { tool = "mcp." .. id, status = "completed" } } }
			end
			return part
		end

		it("renders active and failed headers while keeping failed leaves reachable", function()
			local running = collect({ { parts = { call("running", "running") } } }).running
			assert.is_true(activity.is_working(running))
			assert.is_truthy(text(running):find(family.active .. " — ", 1, true))
			assert.equals("OpenCodeToolGroup", header_highlight(activity.render(running, false)))

			local failed = call("failed", "error")
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
			assert.is_truthy(closed.lines[1]:find(family.done .. " — 2 " .. family.count, 1, true))
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
