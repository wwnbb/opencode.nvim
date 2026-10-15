describe("allowlisted support bundle", function()
	local bundle = require("opencode.ui.debug_bundle")
	local state, selectors = require("opencode.state"), require("opencode.selectors")
	local original_model, original_agent, original_system, original_server, original_notify, original_setreg
	before_each(function()
		state.reset(); state.set_session("ses_private", "PRIVATE TITLE")
		state.set_config({ server = { url = "https://user:SECRET@example.invalid", headers = { Authorization = "SECRET" } }, logs = "PRIVATE LOGS" })
		original_model, original_agent = selectors.current_model, selectors.current_agent
		original_system, original_server, original_notify, original_setreg = vim.system, state.get_server_info, vim.notify, vim.fn.setreg
		selectors.current_model = function() return { providerID = "anthropic", modelID = "claude/sonnet", apiKey = "SECRET" } end
		selectors.current_agent = function() return { name = "build", prompt = "PRIVATE PROMPT" } end
		state.get_server_info = function() return { version = "2.0.18", url = "https://user:SECRET@example.invalid", token = "SECRET" } end
		vim.system = function(args)
			assert.equals("git", args[1]); assert.equals("-C", args[2]); assert.is_string(args[3])
			assert.same({ "rev-parse", "--short", "HEAD" }, vim.list_slice(args, 4))
			return { wait = function() return { code = 0, stdout = "29f0e85\n" } end }
		end
		vim.notify = function() end
	end)
	after_each(function()
		selectors.current_model, selectors.current_agent = original_model, original_agent
		vim.system, state.get_server_info, vim.notify, vim.fn.setreg = original_system, original_server, original_notify, original_setreg
		state.reset()
	end)
	it("keeps versions and opaque identities while excluding arbitrary server/config/session fields", function()
		local result = bundle.collect()
		assert.equals("29f0e85", result.plugin.revision); assert.equals("2.0.18", result.server.version)
		assert.equals("ses_private", result.session.id); assert.equals("claude/sonnet", result.model.id)
		assert.is_number(result.neovim.major); assert.is_string(result.os.system)
		local json = vim.json.encode(result)
		assert.is_nil(json:find("SECRET", 1, true)); assert.is_nil(json:find("PRIVATE", 1, true))
		assert.is_nil(result.os.hostname); assert.is_nil(result.server.url)
		selectors.current_model = function() return { providerID = "https://user:SECRET@host", modelID = "bad\nPRIVATE" } end
		assert.same({ agent = "build" }, bundle.collect().model)
	end)
	it("offers actual read-only JSON review and copies only the frozen bundle", function()
		local copied = {}
		vim.fn.setreg = function(reg, text) copied[reg] = text end
		local popup = bundle.show()
		local callback = vim.fn.maparg("y", "n", false, true).callback
		assert.is_false(vim.bo[popup.bufnr].modifiable)
		callback(); assert.equals("ses_private", vim.json.decode(copied['"']).session.id)
		assert.equals(copied['"'], copied["+"])
		copied = {}; popup:close(); callback(); assert.same({}, copied)
	end)
	it("uses copy aliases and hides a displaced default close shortcut", function()
		state.set_config({ debug_bundle = { keymaps = { copy = { "q", "<F8>" } } } })
		local copied
		vim.fn.setreg = function(_, value) copied = value end
		local popup = bundle.show()
		local ok, err = xpcall(function()
			local lines = table.concat(vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false), "\n")
			assert.is_truthy(lines:find("q / <F8>: copy JSON", 1, true))
			assert.is_truthy(lines:find("<Esc>: close", 1, true))
			assert.equals("", vim.fn.maparg("y", "n"))
			vim.fn.maparg("<F8>", "n", false, true).callback()
			assert.equals("ses_private", vim.json.decode(copied).session.id)
		end, debug.traceback)
		popup:close()
		assert.is_true(ok, err)
	end)
end)
