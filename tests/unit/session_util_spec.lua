local session = require("opencode.util.session")

describe("session display titles", function()
	it("collapses generated root and child timestamps", function()
		assert.equals("New session", session.displayTitle("New session - 2026-07-30T18:45:03.662Z"))
		assert.equals("Child session", session.displayTitle("Child session - 1970-01-01T00:00:00.000Z"))
	end)

	it("preserves ordinary titles and incomplete placeholder matches", function()
		for _, title in ipairs({
			"Fix parser", "New session - custom",
			"New session - 2026-07-30T18:45:03Z",
			"prefix New session - 2026-07-30T18:45:03.662Z",
		}) do
			assert.equals(title, session.displayTitle(title))
		end
	end)

	it("returns nil for absent, empty and non-string titles", function()
		for _, title in ipairs({ "", 42, vim.NIL }) do
			assert.is_nil(session.displayTitle(title))
		end
	end)
end)
