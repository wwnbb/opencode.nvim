-- The runtime harness supplies the isolated server, model and test skill.
-- Never discover a personal CLI, profile, credential or installed skill here.
describe("opencode real server smoke", function()
	it("renders a native skill after starting a new chat session", function()
		if not vim.env.OPENCODE_V2_SERVER_URL or not vim.env.OPENCODE_TEST_HOME
			or not vim.env.OPENCODE_V2_MODEL or not vim.env.OPENCODE_V2_OUTPUT then
			print("Live UI check skipped: run tests/runtime/capture_v2.py --nvim-ui with an explicit model.")
			return
		end
		dofile("tests/runtime/v2_ui.lua")
	end)
end)
