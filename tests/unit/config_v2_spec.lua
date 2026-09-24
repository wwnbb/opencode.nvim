local config = require("opencode.config")

describe("strict v2 setup options", function()
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
end)
