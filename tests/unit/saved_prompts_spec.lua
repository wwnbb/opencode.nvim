describe("saved prompts library", function()
	local state = require("opencode.state")
	local saved, input = require("opencode.saved_prompts"), require("opencode.ui.input")
	local palette = require("opencode.ui.palette.saved_prompts")
	local directory, saved_notify, saved_schedule, notices
	before_each(function()
		state.reset()
		directory = vim.fn.tempname(); vim.fn.mkdir(directory, "p")
		state.set_config({ input = { saved_prompts_file = directory .. "/saved.json", stash_file = directory .. "/stash.json" } })
		input.set_pending_draft("", {}); input.set_mode("normal")
		notices = {}
		saved_notify = vim.notify; vim.notify = function(msg) notices[#notices + 1] = msg end
		saved_schedule = vim.schedule; vim.schedule = function(fn) fn() end
	end)
	after_each(function()
		vim.notify, vim.schedule = saved_notify, saved_schedule
		input.set_pending_draft("", {}); input.set_mode("normal")
		state.reset(); vim.fn.delete(directory, "rf")
	end)

	it("saves the draft without clearing it and keeps it after reloading", function()
		input.set_pending_draft("review @this", {})
		assert(palette.save())
		assert.equals("review @this", input.get_pending_text())
		package.loaded["opencode.saved_prompts"] = nil; saved = require("opencode.saved_prompts")
		assert.equals(1, #saved.list()); assert.equals("review @this", saved.list()[1].text)
	end)

	it("inserts a saved prompt into the draft and keeps it in the library", function()
		local entry = assert(saved.push({ text = "explain the bug", parts = {} }))
		input.set_pending_draft("first", {})
		assert.is_true(palette.insert(entry.id))
		assert.equals("first\n\nexplain the bug", input.get_pending_text())
		assert.is_true(palette.insert(entry.id))
		assert.equals("first\n\nexplain the bug\n\nexplain the bug", input.get_pending_text())
		assert.equals(1, #saved.list())
	end)

	it("is global across directories, unlike the stash", function()
		assert(saved.push({ text = "global prompt", parts = {} }))
		assert(require("opencode.stash").push({ text = "local stash", parts = {} }))
		local cwd = require("opencode.util.cwd")
		local original = cwd.get; cwd.get = function() return directory end
		local ok, err = pcall(function()
			assert.equals(1, #saved.list())
			assert.same({}, require("opencode.stash").list())
		end)
		cwd.get = original
		assert.is_true(ok, err)
	end)

	it("refuses an empty draft", function()
		assert.is_nil(palette.save())
		assert.same({}, saved.list())
		assert.equals("The prompt is empty", notices[1])
	end)

	it("lists prompts in a menu that inserts on select and deletes with a key", function()
		local older = assert(saved.push({ text = "older", parts = {} }))
		assert(saved.push({ text = "newer\nline", parts = {} }))
		local menu, old_open = require("opencode.ui.menu"), require("opencode.ui.menu").open
		local picker; menu.open = function(opts) picker = opts end
		palette.show(); menu.open = old_open
		assert.equals("newer line", picker.items[1].label); assert.equals("saved_prompts_menu", picker.keymap_scope)
		local remaining, closed
		local ctx = { set_items = function(items) remaining = items end, close = function() closed = true end }
		picker.keys[1].handler(ctx, picker.items[1])
		assert.equals(1, #remaining); assert.is_nil(closed); assert.equals("older", remaining[1].label)
		picker.on_select(remaining[1])
		assert.equals("older", input.get_pending_text()); assert.same({ older }, saved.list())
		menu.open = function(opts) picker = opts end
		palette.show(); menu.open = old_open
		picker.keys[1].handler(ctx, picker.items[1])
		assert.is_true(closed); assert.same({}, saved.list())
	end)

	it("does not insert from a stale menu into a different session", function()
		state.set_session("s", "S"); assert(saved.push({ text = "saved", parts = {} }))
		local menu, old_open = require("opencode.ui.menu"), require("opencode.ui.menu").open
		local picker; menu.open = function(opts) picker = opts end
		palette.show(); menu.open = old_open
		state.set_session("other", "Other"); picker.on_select(picker.items[1])
		assert.equals("", input.get_pending_text()); assert.equals(1, #saved.list())
	end)
end)
