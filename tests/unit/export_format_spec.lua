describe("native session export formatters", function()
	local export = require("opencode.export")

	local function transcript()
		return {
			info = { id = "session-1", title = "Example session", time = { created = 1735689600000, updated = 1735689660000 } },
			messages = {
				{ id = "u1", type = "user", text = "Find the report" },
				{ id = "a1", type = "assistant", content = {
					{ type = "reasoning", text = "Look in the project" },
					{ type = "tool", name = "read", state = {
						status = "completed", input = { path = "report.txt", lines = 10 },
						content = { { type = "text", text = "Found it" }, { type = "file", name = "report.txt", uri = "file:///report.txt" } },
					} },
					{ type = "text", text = "The report is ready." },
				} },
				{ id = "s1", type = "shell", command = "pwd", output = { output = "/tmp/project" } },
			},
		}
	end

	it("includes ordered turns, reasoning, tool input/output, and shell in Markdown", function()
		local source = transcript()
		local original = vim.deepcopy(source)
		local markdown = export.markdown(source, { thinking = true, tools = true })
		assert.is_true(markdown:find("# Example session\n\n**Session ID:** session-1", 1, true) ~= nil)
		local user = assert(markdown:find("## User\n\nFind the report", 1, true))
		local reasoning = assert(markdown:find("_Thinking:_\n\nLook in the project", 1, true))
		local tool = assert(markdown:find("**Tool: read**", 1, true))
		local answer = assert(markdown:find("The report is ready.", 1, true))
		local shell = assert(markdown:find("## Shell\n\n```\n$ pwd\n/tmp/project\n```", 1, true))
		assert.is_true(user < reasoning and reasoning < tool and tool < answer and answer < shell)
		assert.is_true(markdown:find('"path": "report.txt"', 1, true) ~= nil)
		assert.is_true(markdown:find("Found it\nreport.txt", 1, true) ~= nil)
		assert.same(original, source)
	end)

	it("honors thinking and tools switches without hiding shell turns", function()
		local source = transcript()
		source.messages[2].content = {
			{ type = "reasoning", text = "private plan" },
			{ type = "tool", name = "shell", state = { status = "error", input = "pwd", error = { message = "failed" } } },
		}
		local hidden = export.markdown(source, { thinking = false, tools = false })
		assert.is_nil(hidden:find("## Assistant", 1, true))
		assert.is_nil(hidden:find("private plan", 1, true))
		assert.is_nil(hidden:find("**Tool:", 1, true))
		assert.is_true(hidden:find("## Shell", 1, true) ~= nil)
		local shown = export.markdown(source, { thinking = true, tools = true })
		assert.is_true(shown:find("_Thinking:_\n\nprivate plan", 1, true) ~= nil)
		assert.is_true(shown:find("**Tool: shell**\n\n**Input:**\n```json\npwd\n```\n\nfailed", 1, true) ~= nil)
	end)

	it("keeps nested fences in tool input and shell text inside their exported blocks", function()
		local input = "```lua\nreturn '猫'\n```\n````"
		local command = "cat README.md\n``````"
		local output = "````markdown\n# Example\n````\n```"
		local source = {
			info = { id = "nested-fences" },
			messages = {
				{ type = "assistant", content = {
					{ type = "tool", name = "shell", state = { input = input, status = "completed", content = {} } },
				} },
				{ type = "shell", command = command, output = { output = output } },
			},
		}
		local original = vim.deepcopy(source)
		local blocks = require("opencode.ui.code_blocks").parse(export.markdown(source))
		assert.equals(2, #blocks)
		assert.is_true(blocks[1].closed)
		assert.equals("json", blocks[1].info)
		assert.same(vim.split(input, "\n", { plain = true }), blocks[1].lines)
		assert.is_true(blocks[2].closed)
		assert.equals("", blocks[2].info)
		assert.same(vim.split("$ " .. command .. "\n" .. output, "\n", { plain = true }), blocks[2].lines)
		assert.same(original, source)
	end)

	it("pretty prints the exact server payload, including server redactions", function()
		local source = transcript()
		source.info.metadata = { token = "[redacted:session-metadata:session-1]" }
		source.messages[1].text = "[redacted:text:u1]"
		local json = export.json(source)
		assert.equals("\n", json:sub(-1))
		assert.is_true(json:find('\n  "', 1, true) ~= nil)
		assert.same(source, vim.json.decode(json))
		assert.is_nil(json:find("Find the report", 1, true))
		assert.is_true(json:find("[redacted:text:u1]", 1, true) ~= nil)
	end)

	it("preserves an intentionally empty session title", function()
		local source = transcript()
		source.info.title = ""
		assert.is_true(export.markdown(source, { thinking = true }):find("# \n\n**Session ID:** session-1", 1, true) ~= nil)
	end)
end)
