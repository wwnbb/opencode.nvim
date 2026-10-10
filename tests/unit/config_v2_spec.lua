local config = require("opencode.config")

describe("strict v2 setup options", function()
	local saved_defaults
	before_each(function() saved_defaults = vim.deepcopy(config.defaults) end)
	after_each(function() config.defaults = saved_defaults end)

	for _, case in ipairs({
		{ name = "omitted options" },
		{ name = "empty options", opts = {} },
		{ name = "custom options", opts = { server = { env = { TEST = "original" } },
			changes = { file_patterns_to_confirm = { "custom" } } } },
	}) do
		it("isolates the merged configuration from " .. case.name .. " and defaults", function()
			local opts, before = vim.deepcopy(case.opts), vim.deepcopy(case.opts)
			local merged = config.merge(opts)
			merged.server.auth.username = "changed"
			merged.server.env.TEST = "changed"
			merged.changes.file_patterns_to_confirm[1] = "changed"
			merged.completion.context.before_lines = 0
			assert.same(saved_defaults, config.defaults)
			assert.same(before, opts)
			local again = config.merge(before)
			assert.equals(saved_defaults.server.auth.username, again.server.auth.username)
			assert.equals(before and before.changes and "custom" or saved_defaults.changes.file_patterns_to_confirm[1],
				again.changes.file_patterns_to_confirm[1])
		end)
	end

	it("rejects removed options before setup changes application state", function()
		local removed = {
			{ session = { parallel = { use_prompt_async = false } } },
			{ chat = { message_display = {} } },
			{ thinking = { max_height = 10 } },
			{ thinking = { truncate = false } },
			{ thinking = { icon = "*" } },
			{ markdown = { enable_code_highlight = false } },
			{ server = { lazy = false } },
			{ diff = {} },
		}
		local defaults = vim.deepcopy(config.defaults)
		for _, opts in ipairs(removed) do
			local ok, err = pcall(config.merge, opts)
			assert.is_false(ok)
			assert.matches("unsupported setup option", err)
			assert.same(defaults, config.defaults)
		end
		local app_state = require("opencode.state")
		local before = app_state.get_config()
		local ok, err = pcall(require("opencode").setup, { chat = { message_display = {} } })
		assert.is_false(ok)
		assert.matches("chat.message_display", err)
		assert.same(before, app_state.get_config())
	end)

	it("accepts current v2 syntax and parallel settings", function()
		local merged = config.merge({ syntax = { assistant_markdown = false }, session = { parallel = { enabled = false } } })
		assert.is_false(merged.syntax.assistant_markdown)
		assert.is_false(merged.session.parallel.enabled)
	end)

	it("disables both editor feature deadlines by default and preserves explicit timeouts", function()
		for _, kind in ipairs({ "completion", "explanation" }) do
			assert.equals(0, config.merge()[kind].timeout_ms)
			assert.equals(0, config.merge({ [kind] = { timeout_ms = 0 } })[kind].timeout_ms)
			assert.equals(1234, config.merge({ [kind] = { timeout_ms = 1234 } })[kind].timeout_ms)
		end
	end)

	it("validates both editor features without changing defaults or user options", function()
		local defaults = vim.deepcopy(config.defaults)
		for _, kind in ipairs({ "completion", "explanation" }) do
			for _, case in ipairs({
				{ { enabled = "yes" }, "enabled" },
				{ { timeout_ms = -1 }, "timeout_ms" },
				{ { timeout_ms = math.huge }, "timeout_ms" },
				{ { context = false }, "context" },
				{ { context = { max_bytes = 1023 } }, "context.max_bytes" },
				{ { context = { before_lines = -1 } }, "context.before_lines" },
				{ { context = { related_lines = 1.5 } }, "context.related_lines" },
				{ { keymaps = false }, "keymaps" },
				{ { keymaps = { trigger = "" } }, "keymaps.trigger" },
			}) do
				local opts = { [kind] = case[1] }
				local before = vim.deepcopy(opts)
				local ok, err = pcall(config.merge, opts)
				assert.is_false(ok)
				assert.matches(kind .. "." .. case[2], err, 1, true)
				assert.same(before, opts)
				assert.same(defaults, config.defaults)
			end
			assert.is_false(config.merge({ [kind] = { keymaps = { trigger = false } } })[kind].keymaps.trigger)
		end
		assert.is_false(pcall(config.merge, { completion = { max_lines = 0 } }))
		assert.is_false(pcall(config.merge, { completion = { keymaps = { accept = "" } } }))
	end)
end)
