describe("v2 attachment mention positions", function()
	local requests = require("opencode.protocol.v2.requests")
	it("converts verified Neovim byte positions to native TUI display cells", function()
		local prefix = "猫🙂é\n"
		local body = assert(requests.prompt(prefix .. "@build", { parts = {
			{ type = "agent", name = "build", source = { start = #prefix, ["end"] = #prefix + 6, value = "@build" } },
		} }, "id"))
		assert.same({ start = 6, ["end"] = 12, text = "@build" }, body.agents[1].mention)
	end)
	it("finds a moved clipboard marker but omits an ambiguous or removed range", function()
		local part = { type = "file", url = "data:image/png;base64,AA==", source = { text = { start = 0, ["end"] = 9, value = "[Image 1]" } } }
		local function make(text) return assert(requests.prompt(text, { parts = { part } }, "id")).files[1] end
		assert.equals(4, make("abc [Image 1]").mention.start)
		assert.is_nil(make("abc [Image 1] [Image 1]").mention)
		assert.is_nil(make("removed").mention)
		assert.equals(part.url, make("removed").uri)
	end)
end)
