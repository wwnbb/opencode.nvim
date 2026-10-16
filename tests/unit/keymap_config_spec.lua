local keymaps = require("opencode.util.keymap")
local config = require("opencode.config")
local state = require("opencode.state")

describe("configurable action mappings", function()
	local buf, saved, leader
	local function mapping(mode, lhs)
		return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, mode, false, true) end)
	end
	before_each(function()
		saved, leader = state.get_config(), vim.g.mapleader
		state.set_config(config.merge({}))
		buf = vim.api.nvim_create_buf(false, true)
	end)
	after_each(function()
		vim.api.nvim_buf_delete(buf, { force = true })
		state.set_config(saved)
		vim.g.mapleader = leader
	end)

	it("replaces default alias lists and supports false and empty lists", function()
		local merged = config.merge({ input = { keymaps = { cancel = { "<F12>" } } },
			menu = { keymaps = { close = false, next_insert = {} } } })
		state.set_config(merged)
		assert.same({ "<F12>" }, keymaps.get("input").cancel)
		assert.same({}, keymaps.keys(keymaps.get("menu").close))
		assert.same({}, keymaps.keys(keymaps.get("menu").next_insert))
	end)

	it("validates action value types and every list member", function()
		for _, value in ipairs({ true, 3, { "q", false }, { "q", "" }, { n = "q" } }) do
			local ok, err = pcall(config.merge, { chat = { keymaps = { close = value } } })
			assert.is_false(ok)
			assert.matches("chat.keymaps.close", err, 1, true)
		end
	end)

	it("detects overlapping completion trigger, prompt, and acceptance aliases", function()
		for _, case in ipairs({
			{ { trigger = { "<C-l>", "<C-i>" }, accept = "<Tab>" }, "trigger and accept" },
			{ { trigger = "<C-l>", prompt = { "<F6>", "<C-L>" } }, "trigger and prompt" },
			{ { prompt = { "<F6>", "<C-i>" }, accept = "<Tab>" }, "prompt and accept" },
		}) do
			local ok, err = pcall(config.merge, { completion = { keymaps = case[1] } })
			assert.is_false(ok)
			assert.matches(case[2] .. " keys must differ", err, 1, true)
		end
	end)

	it("defaults the completion prompt to Ctrl+Shift+L and permits disabling it", function()
		assert.equals("<C-S-l>", config.merge({}).completion.keymaps.prompt)
		assert.is_false(config.merge({ completion = { keymaps = { prompt = false } } }).completion.keymaps.prompt)
		assert.is_false(pcall(config.merge, { completion = { keymaps = { prompt = "" } } }))
	end)

	it("rejects two explicit same-mode actions before changing any mapping", function()
		state.set_config(config.merge({ chat = { keymaps = { close = "N", new_session = "N" } } }))
		local previous = function() end
		vim.keymap.set("n", "N", previous, { buffer = buf })
		local map, apply = keymaps.mapper("chat", buf)
		map("n", "close", function() end)
		map("n", "new_session", function() end)
		local ok, err = pcall(apply)
		assert.is_false(ok)
		assert.matches("conflicting keymaps chat.close and chat.new_session", err, 1, true)
		assert.equals(previous, mapping("n", "N").callback)
	end)

	it("allows same keys in separate modes and labels their actual bindings", function()
		state.set_config(config.merge({ input = { keymaps = { send = "x", cancel = "x" } } }))
		local sent, cancelled = false, false
		local map, apply = keymaps.mapper("input", buf)
		map("i", "send", function() sent = true end)
		map("n", "cancel", function() cancelled = true end)
		apply()
		mapping("i", "x").callback(); mapping("n", "x").callback()
		assert.is_true(sent); assert.is_true(cancelled)
		assert.equals("x", keymaps.label("input", "send"))
		assert.equals("x", keymaps.label("input", "cancel"))
	end)

	it("updates effective hints after configuration changes", function()
		state.set_config(config.merge({ chat = { keymaps = { close = "N" } } }))
		local map, apply = keymaps.mapper("chat", buf)
		map("n", "close", function() end); map("n", "new_session", function() end)
		apply()
		assert.equals("(disabled)", keymaps.label("chat", "new_session"))
		state.set_config(config.merge({}))
		assert.equals("N", keymaps.label("chat", "new_session"))
	end)

	it("inherits common menu overrides and permits a scoped replacement", function()
		state.set_config(config.merge({ menu = { keymaps = { next = "<F8>", close = false } },
			model_menu = { keymaps = { next = "<F9>" } } }))
		assert.equals("<F8>", keymaps.get("session_menu").next)
		assert.equals("<F9>", keymaps.get("model_menu").next)
		assert.is_false(keymaps.get("model_menu").close)
	end)

	it("deduplicates leader and terminal-equivalent aliases and restores string mappings", function()
		vim.g.mapleader = " "
		assert.same({ "<Tab>", "<leader>x" }, keymaps.keys({ "<Tab>", "<C-i>", "<leader>x", "<Space>x" }))
		vim.keymap.set("n", "<leader>x", "gq", { buffer = buf })
		local installed = keymaps.install("n", buf, "<leader>x", "gg")
		assert.equals("gg", mapping("n", "<leader>x").rhs)
		keymaps.restore(installed)
		assert.equals("gq", mapping("n", "<leader>x").rhs)
	end)
	it("replaces owned bindings on reused buffers and restores existing user maps", function()
		local user = function() end
		vim.keymap.set("n", "q", user, { buffer = buf })
		local function configure(value)
			local map, apply = keymaps.mapper("chat", buf, { close = value })
			map("n", "close", function() end)
			apply()
		end
		configure("q")
		assert.is_not.equal(user, mapping("n", "q").callback)
		configure("<F12>")
		assert.equals(user, mapping("n", "q").callback)
		assert.is_function(mapping("n", "<F12>").callback)
		configure(false)
		assert.same({}, mapping("n", "<F12>"))
		assert.equals(user, mapping("n", "q").callback)
	end)

	it("preserves a user's replacement with the same command and different options", function()
		vim.keymap.set("n", "z", "gq", { buffer = buf })
		local installed = keymaps.install("n", buf, "z", "gg", { silent = true })
		vim.keymap.set("n", "z", "gg", { buffer = buf, remap = true, desc = "User navigation" })
		keymaps.restore(installed)
		assert.equals("gg", mapping("n", "z").rhs)
		assert.equals(0, mapping("n", "z").noremap)
		assert.equals("User navigation", mapping("n", "z").desc)
	end)

end)
