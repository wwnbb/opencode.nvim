describe("persistent prompt stash", function()
	local state = require("opencode.state")
	local stash, input = require("opencode.stash"), require("opencode.ui.input")
	local directory, saved_notify
	before_each(function()
		state.reset()
		directory = vim.fn.tempname(); vim.fn.mkdir(directory, "p")
		state.set_config({ input = { stash_file = directory .. "/stash.json" } })
		input.set_pending_draft("", {}); input.set_mode("normal")
		saved_notify = vim.notify; vim.notify = function() end
	end)
	after_each(function()
		vim.notify = saved_notify
		input.set_pending_draft("", {}); input.set_mode("normal")
		state.reset(); vim.fn.delete(directory, "rf")
	end)
	it("restores multiple prompts and their native parts after reloading the owner", function()
		local image = { type = "file", mime = "image/png", url = "data:image/png;base64,Yg==", _marker = "[Image 1]", _mention = 9 }
		local old = assert(stash.push({ text = "old [Image 1]", parts = { image } }))
		assert(stash.push({ text = "new", parts = {}, mode = "shell" }))
		package.loaded["opencode.stash"] = nil; stash = require("opencode.stash")
		assert.equals(2, #stash.list()); assert.equals("shell", assert(stash.take()).mode)
		local restored = assert(stash.take(old.id))
		assert.equals("old [Image 1]", restored.text); assert.equals(image.url, restored.parts[1].url)
		assert.is_nil(restored.parts[1]._mention); assert.same({}, stash.list()); assert.equals(9, image._mention)
	end)
	it("preserves the draft and stash when saving fails or the file format is unsupported", function()
		local file = directory .. "/unrecognized.json"
		vim.fn.writefile({ '{"version":99,"precious":"keep"}' }, file)
		state.set_config({ input = { stash_file = file } })
		input.set_pending_draft("keep draft", {})
		require("opencode.ui.palette.stash").push()
		assert.equals("keep draft", input.get_pending_text())
		assert.equals(99, vim.json.decode(table.concat(vim.fn.readfile(file), "\n")).version)
		state.set_config({ input = { stash_file = directory .. "/stash.json" } })
		assert(stash.push({ text = "stashed", parts = {} }))
		local json_file = require("opencode.util.json_file")
		local saved = json_file.write; json_file.write = function() return false end
		local ok, err = stash.take()
		json_file.write = saved
		assert.is_nil(ok); assert.matches("preserved", err); assert.equals(1, #stash.list())
	end)
	it("merges a restored prompt with the current draft and renumbers colliding attachment markers", function()
		local part = { type = "file", mime = "image/png", url = "data:image/png;base64,Yg==", _marker = "[Image 1]",
			source = { text = { value = "[Image 1]", start = 0, ["end"] = 9 } } }
		input.set_pending_draft("first [Image 1]", { part })
		assert(stash.push({ text = "second [Image 1]", parts = { part } }))
		require("opencode.ui.palette.stash").pop()
		assert.equals("first [Image 1]\n\nsecond [Image 2]", input.get_pending_text())
		local parts = input.get_pending_parts()
		assert.equals(2, #parts); assert.equals("[Image 2]", parts[2]._marker)
		local request = assert(require("opencode.protocol.requests").prompt(input.get_pending_text(), { parts = parts }, "msg_1"))
		assert.equals(2, #request.files); assert.equals("[Image 2]", request.files[2].mention.text)
		assert.same({}, stash.list())
		assert(stash.push({ text = "rm example", parts = {}, mode = "shell" }))
		require("opencode.ui.palette.stash").pop()
		assert.equals(1, #stash.list()); assert.equals("normal", input.get_mode())
	end)
	it("keeps each file reference when several recalled markers collide", function()
		local function image(index)
			return { type = "file", mime = "image/png", url = "data:image/png;base64,Yg==", _marker = "[Image " .. index .. "]",
				source = { text = { value = "[Image " .. index .. "]", start = -1, ["end"] = -1 } } }
		end
		input.set_pending_draft("current [Image 1]", { image(1) })
		assert(stash.push({ text = "first [Image 1]; second [Image 2]", parts = { image(1), image(2) } }))
		require("opencode.ui.palette.stash").pop()
		assert.equals("current [Image 1]\n\nfirst [Image 3]; second [Image 2]", input.get_pending_text())
		local parts = input.get_pending_parts()
		assert.equals("[Image 3]", parts[2]._marker); assert.equals("[Image 2]", parts[3]._marker)
		local request = assert(require("opencode.protocol.requests").prompt(input.get_pending_text(), { parts = parts }, "msg_1"))
		assert.equals("[Image 3]", request.files[2].mention.text); assert.equals("[Image 2]", request.files[3].mention.text)
	end)
	it("rejects malformed entry parts before taking a draft and tolerates missing display fields", function()
		local file = directory .. "/entries.json"
		local scope = require("opencode.util.path").absolute(vim.fn.getcwd())
		assert(require("opencode.util.json_file").write(file, { version = 2, scopes = { [scope] = {
			{ id = "broken", text = "Keep this record", parts = { true } },
			{ id = "valid", text = "Draft", parts = {}, created = "invalid" },
		} } }))
		state.set_config({ input = { stash_file = file } })
		local original = table.concat(vim.fn.readfile(file), "\n")
		assert.is_nil(stash.take("broken")); assert.equals(original, table.concat(vim.fn.readfile(file), "\n"))
		assert.equals("normal", stash.list()[1].mode)
		local menu, old_open = require("opencode.ui.menu"), require("opencode.ui.menu").open
		local picker; menu.open = function(opts) picker = opts end
		local ok, failure = pcall(require("opencode.ui.palette.stash").show)
		menu.open = old_open
		assert.is_true(ok, failure); assert.matches("Unknown date", picker.items[1].description)
	end)
	it("persists prompt context without old session or request ownership", function()
		local context = { { type = "text", text = "frozen snapshot", _editor_context = { identity = "snapshot", path = "/source.lua" } } }
		input.set_pending_draft("retry", {}, { options = { context = context, session_id = "old-session", _token = { generation = 1 } } })
		require("opencode.ui.palette.stash").push()
		package.loaded["opencode.stash"] = nil; stash = require("opencode.stash")
		assert.same({ context = context }, stash.list()[1].options)
		require("opencode.ui.palette.stash").pop()
		assert.same({ context = context }, input.get_pending_options())
		local request = assert(require("opencode.protocol.requests").prompt(input.get_pending_text(), input.get_pending_options(), "msg_1"))
		assert.equals("retry\n\nfrozen snapshot", request.text)
	end)
	it("does not restore a stale popup into a different session", function()
		state.set_session("s", "S"); assert(stash.push({ text = "saved", parts = {} }))
		local menu, old_open = require("opencode.ui.menu"), require("opencode.ui.menu").open
		local picker; menu.open = function(opts) picker = opts end
		require("opencode.ui.palette.stash").show(); menu.open = old_open
		state.set_session("other", "Other"); picker.on_select(picker.items[1])
		assert.equals("", input.get_pending_text()); assert.equals(1, #stash.list())
	end)
end)
