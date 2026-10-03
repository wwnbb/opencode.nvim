describe("stable agent identity", function()
	local state, sync = require("opencode.state"), require("opencode.sync")
	local choices = require("opencode.session.selection")
	local saved_local, local_state, bufnr, highlights
	before_each(function()
		saved_local = package.loaded["opencode.local"]
		package.loaded["opencode.local"] = nil
		local_state = require("opencode.local")
		state.reset(); sync.clear_all(); choices.clear_all()
		sync.handle_agents({ { id = "a", name = "b", color = "#ff0000" }, { id = "b", name = "Second", color = "#0000ff" } })
		highlights = {}
		for _, name in ipairs({ "OpenCodeInputBorderAgent", "OpenCodeAgent_a", "OpenCodeAgent_b", "OpenCodeAgent_Same", "OpenCodeAgent_a_b", "OpenCodeAgent____", "OpenCodeAgent_ff0000", "OpenCodeAgent_0000ff" }) do
			highlights[name] = vim.api.nvim_get_hl(0, { name = name, create = false })
		end
	end)
	after_each(function()
		if bufnr then vim.api.nvim_buf_delete(bufnr, { force = true }); bufnr = nil end
		for name, value in pairs(highlights) do vim.api.nvim_set_hl(0, name, value) end
		state.reset(); sync.clear_all(); choices.clear_all()
		package.loaded["opencode.local"] = saved_local
	end)

	it("prefers a stable ID over another agent's display name in local and native selections", function()
		local_state.agent.set("b")
		assert.equals("b", local_state.agent.current().id)
		state.upsert_session({ id = "s", agent = "b" }); state.set_session("s", "Session")
		assert.equals("b", local_state.agent.current().id)
		local_state.agent.set("Second") -- Retain name-based compatibility when no ID matches.
		assert.equals("b", choices.current("s").agent)
	end)

	it("enters the available agent list at the correct end after catalog removal or hiding", function()
		for _, missing in ipairs({ {}, { id = "gone", hidden = true }, { id = "gone", mode = "subagent" } }) do
			for _, direction in ipairs({ 1, -1 }) do
				state.reset(); choices.clear_all()
				local agents = { { id = "a", name = "First" }, { id = "b", name = "Second" } }
				if missing.id then agents[#agents + 1] = missing end
				sync.handle_agents(agents)
				state.upsert_session({ id = "s", agent = "gone" }); state.set_session("s", "Session")
				assert.is_true(local_state.agent.current().unavailable)
				local_state.agent.move(direction, { silent = true })
				assert.equals(direction == 1 and "a" or "b", choices.current("s").agent)
			end
		end
	end)

	it("wraps agent cycling and applies the configured model through the shared selection flow", function()
		sync.handle_providers({ { id = "p", models = { configured = {} } } })
		sync.handle_agents({ { id = "a", name = "First" }, { id = "b", name = "Second", model = { providerID = "p", modelID = "configured" } } })
		state.upsert_session({ id = "s", agent = "a" }); state.set_session("s", "Session")
		local calls = {}
		local_state.on(function(key) calls[#calls + 1] = key end)
		local_state.agent.move(-1, { silent = true })
		assert.equals("b", choices.current("s").agent)
		assert.equals("configured", choices.current("s").model.modelID)
		assert.same({ "agent", "model" }, calls)
		local_state.agent.move(1, { silent = true })
		assert.equals("a", choices.current("s").agent)
	end)

	it("uses the same stable identity for agent colors", function()
		local group = local_state.agent.color("b")
		assert.equals(0x0000ff, vim.api.nvim_get_hl(0, { name = group, link = false }).fg)
		assert.equals("DiagnosticInfo", local_state.agent.color("unknown"))
	end)

	it("keeps punctuation and Unicode IDs from overwriting another agent's color", function()
		for _, ids in ipairs({ { "a-b", "a_b" }, { "界", "福" } }) do
			sync.handle_agents({
				{ id = ids[1], name = "Red", color = "#ff0000" },
				{ id = ids[2], name = "Blue", color = "#0000ff" },
				{ id = "shared", name = "Same color", color = "#FF0000" },
			})
			local red = local_state.agent.color(ids[1])
			local blue = local_state.agent.color(ids[2])
			assert.is_not.equals(red, blue)
			assert.equals(0xff0000, vim.api.nvim_get_hl(0, { name = red, link = false }).fg)
			assert.equals(0x0000ff, vim.api.nvim_get_hl(0, { name = blue, link = false }).fg)
			assert.equals(red, local_state.agent.color("shared"))
		end
	end)

	it("renders the selected agent's info and border colors when names are identical", function()
		sync.handle_agents({ { id = "a", name = "Same", color = "#ff0000" }, { id = "b", name = "Same", color = "#0000ff" } })
		local_state.agent.set("b")
		bufnr = vim.api.nvim_create_buf(false, true)
		require("opencode.ui.input.info_bar").update({ visible = true, info_bufnr = bufnr })
		local marks = vim.api.nvim_buf_get_extmarks(bufnr, vim.api.nvim_create_namespace("opencode_input_info"), 0, -1, { details = true })
		assert.equals(0x0000ff, vim.api.nvim_get_hl(0, { name = marks[1][4].hl_group, link = false }).fg)
		assert.equals(0x0000ff, vim.api.nvim_get_hl(0, { name = "OpenCodeInputBorderAgent", link = false }).fg)
		assert.matches("^Same ", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
	end)
end)
