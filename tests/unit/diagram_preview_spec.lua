describe("safe browser diagram/math preview", function()
	local diagrams = require("opencode.ui.diagrams")
	local state, sync, pending = require("opencode.state"), require("opencode.sync"), require("opencode.session.pending")
	local menu = require("opencode.ui.menu")
	local original_open, original_menu, original_notify, paths, opened, notices, picker
	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all(); state.set_session("s", "Session")
		original_open, original_menu, original_notify = vim.ui.open, menu.open, vim.notify
		paths, opened, notices, picker = {}, {}, {}, nil
		vim.ui.open = function(path) opened[#opened + 1] = path; return {} end
		menu.open = function(opts) picker = opts end
		vim.notify = function(message) notices[#notices + 1] = message end
	end)
	after_each(function()
		vim.ui.open, menu.open, vim.notify = original_open, original_menu, original_notify
		for _, path in ipairs(paths) do vim.fn.delete(path) end
		state.reset(); sync.clear_all(); pending.clear_all()
	end)
	it("selects completed native fences from text and tool outputs, ignoring partial/ordinary code", function()
		sync.handle_message_updated({ id = "m", sessionID = "s", role = "assistant" })
		sync.handle_part_updated({ id = "p", messageID = "m", type = "text", text = "```mermaid\ngraph LR\n A-->B\n```\n```python\nprint(1)\n```\n```math\nx^2\n```\n```latex\nunclosed" })
		sync.handle_part_updated({ id = "t", messageID = "m", type = "tool", state = { content = { { type = "text", text = "~~~latex\n\\frac{1}{2}\n~~~" } } } })
		local items = diagrams.items("s")
		assert.equals(3, #items); assert.equals("mermaid", items[1].kind); assert.equals("graph LR\n A-->B", items[1].source)
		assert.equals("math", items[2].kind); assert.equals("\\frac{1}{2}", items[3].source)
		diagrams.show(); picker.on_select(picker.items[1]); paths[#paths + 1] = opened[1]
		assert.equals(1, #opened)
		sync.handle_part_updated({ id = "p", messageID = "m", type = "text", text = "changed" })
		picker.on_select(picker.items[1]); assert.equals(1, #opened); assert.matches("Diagram changed", notices[1])
		state.set_session("other", "Other"); picker.on_select(picker.items[3]); assert.equals(1, #opened)
	end)
	it("embeds source only as escaped data with restrictive rendering and pinned libraries", function()
		local html = assert(diagrams.html({ kind = "mermaid", source = '</script><script>alert("PRIVATE")</script>\nA-->B' }))
		assert.is_nil(html:find('</script><script>alert', 1, true))
		assert.is_truthy(html:find('\\u003c/script>', 1, true))
		assert.is_truthy(html:find("mermaid@12.1.0", 1, true)); assert.is_truthy(html:find("katex@0.19.0", 1, true))
		assert.is_truthy(html:find("securityLevel:'strict'", 1, true)); assert.is_truthy(html:find("trust:false", 1, true))
		assert.is_truthy(html:find("connect-src 'none'", 1, true)); assert.is_truthy(html:find("Preview unavailable:", 1, true))
		assert.is_nil(html:find("PAYLOAD", 1, true)); assert.is_nil(html:find("NONCE", 1, true))
	end)
	it("writes private temporary HTML and handles missing browser/content without leaving a file", function()
		local path = assert(diagrams.open({ kind = "math", source = "\\frac{1}{2}" })); paths[#paths + 1] = path
		assert.equals(384, bit.band(vim.uv.fs_stat(path).mode, 511)); assert.equals(path, opened[1])
		assert.is_truthy(table.concat(vim.fn.readfile(path), "\n"):find("\\\\frac{1}{2}", 1, true))
		for _, item in ipairs({ {}, { kind = "html", source = "<script>" }, { kind = "math", source = "" }, { kind = "math", source = string.rep("x", 50001) } }) do
			local result, err = diagrams.open(item); assert.is_nil(result); assert.is_string(err)
		end
		vim.ui.open = function(failed_path) opened[#opened + 1] = failed_path; return nil, "No browser" end
		local result, err = diagrams.open({ kind = "math", source = "x" })
		assert.is_nil(result); assert.equals("No browser", err); assert.is_nil(vim.uv.fs_stat(opened[2]))
	end)
end)
