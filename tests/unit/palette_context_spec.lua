describe("palette context guard", function()
	local palette_context = require("opencode.ui.palette.context")
	local palette = require("opencode.ui.palette")
	local app, views, pending = require("opencode.state"), require("opencode.ui.chat.state"), require("opencode.session.pending")
	local created

	local function view(id, bound)
		local value = views.new()
		value.session_id, value.session_bound = id, bound
		created[#created + 1] = value
		return { view = value, generation = value.generation, session_id = id }
	end
	before_each(function()
		created = {}
		app.reset(); pending.clear_all()
		app.upsert_session({ id = "a", directory = "/a" }, { touch = false })
		app.upsert_session({ id = "b", directory = "/b" }, { touch = false })
		app.set_session("a", "A", { runtime = false })
	end)
	after_each(function()
		for _, value in ipairs(created) do views.remove(value) end
		pending.clear_all(); app.reset()
	end)

	it("keeps palette.capture_context and palette.context_valid as adapters", function()
		assert.equals(palette_context.capture, palette.capture_context)
		assert.equals(palette_context.valid, palette.context_valid)
	end)

	it("checks only the pending token by default and scopes it to session_token", function()
		local current = palette_context.guard(view("a", true), { session_token = "a" })
		app.set_session("b", "B", { runtime = false })
		assert.is_true(current())
		pending.clear_session("a")
		assert.is_false(current())
		local global = palette_context.guard()
		pending.invalidate()
		assert.is_false(global())
	end)

	it("requires a session-bound view to stay valid but ignores views that follow focus", function()
		local bound = view("a", true)
		local follows = view("a", false)
		local bound_current = palette_context.guard(bound, { require_view = "session_bound" })
		local follows_current = palette_context.guard(follows, { require_view = "session_bound" })
		views.remove(bound.view); views.remove(follows.view)
		assert.is_false(bound_current())
		assert.is_true(follows_current())
		assert.is_false(follows_current(true), "require_selection checks every view")
		assert.is_false(palette_context.guard(follows, { require_view = "session_bound", require_selection = true })())
		assert.is_false(palette_context.guard(follows, { require_view = true })())
	end)

	it("compares the focused session and directories when asked", function()
		local context = { session_id = "a" }
		local focused = palette_context.guard(context, { global_session = true })
		local located, _, directory = palette_context.guard(context, { same_directory = true })
		assert.equals("/a", directory)
		app.upsert_session({ id = "a", directory = "/moved" }, { touch = false })
		assert.is_false(located())
		assert.is_true(focused())
		app.set_session("b", "B", { runtime = false })
		assert.is_false(focused())
		local _, _, fallback = palette_context.guard({ session_id = "missing" }, { same_directory = "cwd" })
		assert.equals(require("opencode.util.cwd").get(), fallback)
		local unset, _, none = palette_context.guard({ session_id = "missing" }, { same_directory = true })
		assert.is_nil(none)
		assert.is_true(unset(), "an unset directory must stay unset")
		app.upsert_session({ id = "missing", directory = "/now-set" }, { touch = false })
		assert.is_false(unset())
	end)

	it("adds the module check and closes menus from stale key handlers", function()
		local allowed = true
		local current = palette_context.guard(nil, { check = function() return allowed end })
		local calls, closed = 0, 0
		local keys = palette_context.guard_keys({ { handler = function() calls = calls + 1; return "ran" end } }, current)
		local ctx = { close = function() closed = closed + 1 end }
		assert.equals("ran", keys[1].handler(ctx, {}))
		allowed = false
		assert.is_nil(keys[1].handler(ctx, {}))
		assert.equals(1, calls); assert.equals(1, closed)
	end)
end)
