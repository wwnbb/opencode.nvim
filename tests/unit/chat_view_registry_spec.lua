describe("chat view registry liveness", function()
	local cs = require("opencode.ui.chat.state")
	local adapter = require("opencode.session.views")
	local created

	before_each(function() created = {} end)
	after_each(function()
		for _, view in ipairs(created) do cs.remove(view) end
	end)

	local function new_view(fields)
		local view = cs.new()
		created[#created + 1] = view
		for key, value in pairs(fields or {}) do view[key] = value end
		return view
	end

	it("creates views hidden, so visibility is never nil", function()
		assert.is_false(new_view().visible)
	end)

	it("treats only visible or suspended registered views as live", function()
		local visible, suspended, hidden = new_view({ visible = true }), new_view({ suspended = true }), new_view()
		local unset = new_view({ visible = nil })
		assert.is_true(cs.is_live(visible))
		assert.is_true(cs.is_live(suspended))
		assert.is_false(cs.is_live(hidden))
		assert.is_false(cs.is_live(unset))
		cs.remove(visible)
		assert.is_false(cs.is_live(visible))
		local live = adapter.live()
		assert.is_true(vim.tbl_contains(live, suspended))
		assert.is_false(vim.tbl_contains(live, visible) or vim.tbl_contains(live, hidden) or vim.tbl_contains(live, unset))
	end)

	it("resolves a view's root session from the bottom of its navigation stack", function()
		local view = new_view({ session_id = "child", session_stack = { { id = "root" }, { id = "middle" } } })
		assert.equals("root", adapter.root_session_id(view))
		view.session_stack = {}
		assert.equals("child", cs.root_session_id(view))
	end)
end)
