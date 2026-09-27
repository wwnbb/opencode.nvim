local memo = require("opencode.util.memo")
local render_state = require("opencode.ui.chat.render_state")
local contexts = require("opencode.ui.chat.render_context")
local syntax = require("opencode.ui.syntax")
local state = require("opencode.ui.chat.state").state
local MiB = 1024 * 1024

describe("render and task-summary shared memo budget", function()
	local saved, generation, captures
	local function owner(kind, session, message, part)
		return render_state.render_cache_key(kind, session, message, part)
	end
	local function code(session)
		return render_state.code_highlighter(render_state.render_cache_key(session, "message", "part"))
	end
	local function context()
		return contexts.new({ current_session = { id = "session" } })
	end

	before_each(function()
		saved = { state = {}, generation = syntax.get_cache_generation,
			signature = syntax.cache_signature, highlight = syntax.highlight_text }
		for key, value in pairs(state) do saved.state[key] = value end
		generation, captures = 1, 0
		syntax.get_cache_generation = function() return generation end
		syntax.cache_signature = function() return "code-settings" end
		syntax.highlight_text = function()
			captures = captures + 1
			return {}, "ok"
		end
		memo.clear_all()
		render_state.clear_render_cache()
		render_state.clear_task_summary_cache()
		render_state.clear_code_cache()
	end)

	after_each(function()
		syntax.get_cache_generation, syntax.cache_signature, syntax.highlight_text =
			saved.generation, saved.signature, saved.highlight
		memo.clear_all()
		render_state.clear_code_cache()
		for key in pairs(state) do state[key] = nil end
		for key, value in pairs(saved.state) do state[key] = value end
	end)

	it("replaces revisions of one render owner and retires a mismatched signature", function()
		local id = owner("content", "session", "message", "part")
		for revision = 1, 40 do
			local key = render_state.render_cache_key(id, revision, 80)
			local value = { revision = revision, text = "complete body" }
			assert.equals(value, render_state.render_cache_put(key, value, id))
			assert.equals(value, render_state.render_cache_get(key, id))
			assert.equals(1, render_state.render_cache_stats().entries)
		end
		assert.equals(1, #render_state.ensure_render_cache().order)
		assert.is_nil(render_state.render_cache_get("different dependencies", id))
		assert.equals(0, render_state.render_cache_stats().entries)
	end)

	it("preserves the 1000 render and 100 task-summary entry limits", function()
		for index = 1, 1001 do render_state.render_cache_put("render-" .. index, { index }) end
		assert.equals(1000, render_state.render_cache_stats().entries)
		assert.is_nil(render_state.render_cache_get("render-1"))
		assert.same({ 1001 }, render_state.render_cache_get("render-1001"))
		for index = 1, 101 do render_state.task_summary_cache_put("child-" .. index, 1, { index }, "prompt") end
		assert.equals(100, render_state.task_summary_cache_stats().entries)
		local _, _, found = render_state.task_summary_cache_get("child-1", 1)
		assert.is_false(found)
		local summary, prompt, last_found = render_state.task_summary_cache_get("child-101", 1)
		assert.same({ 101 }, summary)
		assert.equals("prompt", prompt)
		assert.is_true(last_found)
	end)

	it("replaces task-summary revisions and treats successful empty data as present", function()
		for revision = 1, 20 do render_state.task_summary_cache_put("child", revision, {}, nil) end
		assert.equals(1, render_state.task_summary_cache_stats().entries)
		local summary, prompt, found = render_state.task_summary_cache_get("child", 20)
		assert.same({}, summary)
		assert.is_nil(prompt)
		assert.is_true(found)
		local _, _, stale = render_state.task_summary_cache_get("child", 19)
		assert.is_false(stale)
		assert.equals(0, render_state.task_summary_cache_stats().entries)
	end)

	it("shares 16 MiB across render, task summaries and other memo pools", function()
		render_state.render_cache_put("large-render", { text = string.rep("r", 7 * MiB) })
		render_state.task_summary_cache_put("large-child", 1, { text = string.rep("t", 6 * MiB) }, nil)
		local pressure = memo.new("render_budget_pressure", { max_entries = 1000 })
		pressure:put("other", 1, string.rep("p", 4 * MiB))
		assert.is_true(memo.stats().bytes <= 16 * MiB)
		assert.is_nil(render_state.render_cache_get("large-render"))
		local summary, _, found = render_state.task_summary_cache_get("large-child", 1)
		assert.is_true(found)
		assert.equals(6 * MiB, #summary.text)
		assert.equals(4 * MiB, #pressure:get("other", 1))
	end)

	it("returns oversized complete results without retaining their older revision", function()
		local id = owner("content", "session", "message")
		render_state.render_cache_put("small", { "old" }, id)
		local oversized = { text = string.rep("x", 16 * MiB + 1) }
		assert.equals(oversized, render_state.render_cache_put("huge", oversized, id))
		assert.equals(16 * MiB + 1, #oversized.text)
		assert.equals(0, render_state.render_cache_stats().entries)
		assert.is_nil(render_state.render_cache_get("small", id))
		assert.is_nil(render_state.render_cache_get("huge", id))
		render_state.task_summary_cache_put("child", 1, { "old" }, nil)
		render_state.task_summary_cache_put("child", 2, oversized, nil)
		assert.equals(0, render_state.task_summary_cache_stats().entries)
	end)

	it("does not keep evicted values alive through compatibility state tables", function()
		local value = { text = "only pool owns this value" }
		local weak = setmetatable({ value }, { __mode = "v" })
		render_state.render_cache_put("evict", value)
		value = nil
		assert.same({}, state.render_cache.blocks)
		assert.same({}, state.render_cache.order)
		memo.clear_all()
		collectgarbage("collect")
		collectgarbage("collect")
		assert.is_nil(weak[1])
		assert.same({ blocks = {}, order = {} }, render_state.ensure_render_cache())
	end)

	it("supports old key-only callers and resets on replacing or restoring state sentinels", function()
		local value = { "legacy" }
		render_state.render_cache_put("legacy-key", value)
		assert.equals(value, render_state.render_cache_get("legacy-key"))
		local snapshot = render_state.ensure_render_cache()
		assert.equals(value, snapshot.blocks["legacy-key"])
		snapshot.blocks["legacy-key"] = nil
		assert.equals(value, render_state.render_cache_get("legacy-key"))
		local original = state.render_cache
		state.render_cache = { blocks = {}, order = {} }
		assert.is_nil(render_state.render_cache_get("legacy-key"))
		render_state.render_cache_put("replacement", { "new" })
		state.render_cache = original
		assert.is_nil(render_state.render_cache_get("replacement"))
		local original_task = state.task_summary_cache
		render_state.task_summary_cache_put("child", 1, {}, "old")
		state.task_summary_cache = { entries = {}, order = {} }
		local _, _, replaced = render_state.task_summary_cache_get("child", 1)
		assert.is_false(replaced)
		render_state.task_summary_cache_put("child", 2, {}, "new")
		state.task_summary_cache = original_task
		local _, _, restored = render_state.task_summary_cache_get("child", 2)
		assert.is_false(restored)
	end)

	it("retires prior results before dependency changes, retry, running results or errors", function()
		for _, method in ipairs({ "cached_nui_lines", "cached_render_result" }) do
			local id = owner(method, "session", "message")
			local builds = 0
			local function build()
				builds = builds + 1
				return { "body", lines = { "body" } }
			end
			local ctx = context()
			ctx[method](ctx, "stable", build, id)
			ctx[method](ctx, "stable", build, id)
			assert.equals(1, builds)
			generation = generation + 1
			ctx = context()
			ctx[method](ctx, "stable", function() return { _opencode_syntax_retry = true } end, id)
			assert.is_nil(render_state.render_cache_get("stable", id))
			ctx[method](ctx, "stable", build, id)
			ctx[method](ctx, nil, build, id)
			assert.is_nil(render_state.render_cache_get("stable", id))
			ctx[method](ctx, "stable", build, id)
			local ok = pcall(ctx[method], ctx, "next-revision", function() error("build failed") end, id)
			assert.is_false(ok)
			assert.is_nil(render_state.render_cache_get("stable", id))
		end
		local ctx = context()
		local id = owner("header", "session", "message")
		assert.equals("one", ctx:cached_nui_line("one", function() return "one" end, id))
		assert.equals("two", ctx:cached_nui_line("two", function() return "two" end, id))
		assert.equals(1, render_state.render_cache_stats().entries)
	end)

	it("clears only exact session owners, child summaries and code entries", function()
		local first = owner("content", "session", "message", "part")
		local second = owner("header", "session-long", "message")
		render_state.render_cache_put("first", {}, first)
		render_state.render_cache_put("second", {}, second)
		render_state.task_summary_cache_put("session", 1, {}, nil)
		render_state.task_summary_cache_put("session-long", 1, {}, nil)
		local first_code, second_code = code("session"), code("session-long")
		first_code("return 1", "lua", {}, { open_line = 1 })
		second_code("return 2", "lua", {}, { open_line = 1 })
		assert.equals(2, captures)
		render_state.clear_session("session")
		assert.is_nil(render_state.render_cache_get("first", first))
		assert.is_not_nil(render_state.render_cache_get("second", second))
		local _, _, removed = render_state.task_summary_cache_get("session", 1)
		local _, _, kept = render_state.task_summary_cache_get("session-long", 1)
		assert.is_false(removed)
		assert.is_true(kept)
		assert.equals(1, render_state.code_cache_stats().entries)
		second_code("return 2", "lua", {}, { open_line = 1 })
		assert.equals(2, captures)
		first_code("return 1", "lua", {}, { open_line = 1 })
		assert.equals(3, captures)
	end)

	it("always clears summaries on surface reset and preserves render only when requested", function()
		local other = memo.new("render_reset_other", { max_entries = 10 })
		other:put("owner", 1, {})
		render_state.render_cache_put("render", {})
		render_state.task_summary_cache_put("child", 1, {}, nil)
		code("session")("return 1", "lua", {}, { open_line = 1 })
		render_state.reset_chat_surface({ preserve_render_cache = true })
		assert.is_not_nil(render_state.render_cache_get("render"))
		assert.is_not_nil(other:get("owner", 1))
		assert.equals(0, render_state.task_summary_cache_stats().entries)
		assert.equals(1, render_state.code_cache_stats().entries)
		render_state.reset_chat_surface()
		assert.is_nil(render_state.render_cache_get("render"))
		assert.equals(0, memo.stats().entries)
		assert.equals(0, render_state.code_cache_stats().entries)
	end)

	it("retains the independent 128-entry, 8 MiB code cache", function()
		render_state.render_cache_put("render", { "body" })
		local before = memo.stats().bytes
		local highlight = code("session")
		for index = 1, 129 do highlight("return " .. index, "lua", {}, { open_line = index }) end
		local stats = render_state.code_cache_stats()
		assert.equals(128, stats.entries)
		assert.equals(128, stats.max_entries)
		assert.equals(8 * MiB, stats.max_bytes)
		assert.is_true(stats.bytes <= stats.max_bytes)
		assert.equals(before, memo.stats().bytes)
	end)
end)
