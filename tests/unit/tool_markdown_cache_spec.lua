local app = require("opencode.state")
local render = require("opencode.ui.chat.render")
local render_context = require("opencode.ui.chat.render_context")
local render_state = require("opencode.ui.chat.render_state")
local tool_renderer = require("opencode.ui.chat.tool_renderer")
local view = require("opencode.ui.chat.state").state

describe("tool Markdown render cache", function()
	local old_config, old_columns, old_view, original_parser, original_content, bufnr, winid
	local view_fields = { "winid", "tools", "expanded_tools", "render_cache", "last_render_highlight_signature" }
	before_each(function()
		old_config, old_columns, old_view = app.get_config(), vim.o.columns, {}
		original_parser, original_content = vim.treesitter.get_string_parser, render.render_content
		for _, field in ipairs(view_fields) do old_view[field] = view[field] end
		app.set_config(vim.deepcopy(require("opencode.config").defaults))
		vim.o.columns = 120
		bufnr = vim.api.nvim_create_buf(false, true)
		winid = vim.api.nvim_open_win(bufnr, false, { relative = "editor", row = 0, col = 0, width = 80, height = 10 })
		view.winid, view.tools, view.expanded_tools = winid, {}, {}
		render_state.clear_render_cache()
	end)

	after_each(function()
		vim.treesitter.get_string_parser, render.render_content = original_parser, original_content
		for _, field in ipairs(view_fields) do view[field] = old_view[field] end
		vim.api.nvim_win_close(winid, true)
		vim.api.nvim_buf_delete(bufnr, { force = true })
		vim.o.columns = old_columns
		app.set_config(old_config)
	end)

	for _, name in ipairs({ "skill", "webfetch", "websearch" }) do
		it("retries " .. name .. " Markdown when its parser becomes available, then caches the formatted result", function()
			local part = {
				id = "markdown-cache-" .. name, messageID = "markdown-cache-message", sessionID = "markdown-cache-session",
				type = "tool", tool = name,
				state = { status = "completed", input = {
					name = "markdown-cache-skill", url = "https://example.com/cache", format = "markdown", query = "cache",
				}, metadata = { description = "Independent description" }, output = "# Instructions\n\n**FORMATTED_MARKER**" },
			}
			view.expanded_tools[part.id] = true
			local calls = 0
			render.render_content = function(...)
				calls = calls + 1
				return original_content(...)
			end
			local function render_part()
				local ctx = render_context.new({ current_session = { id = part.sessionID } })
				tool_renderer.render_tool_part(ctx, part, 1, { [part.id] = 1 })
				return table.concat(ctx.raw_lines, "\n"), view.tools[part.id].highlights
			end

			vim.treesitter.get_string_parser = function() error("Optional parser is not available yet") end
			local unavailable = render_part()
			assert.is_truthy(unavailable:find("**FORMATTED_MARKER**", 1, true))
			assert.equals(1, calls)

			-- A parser can be installed after the completed tool was displayed.
			-- Its message/part revisions and expansion state have not changed.
			vim.treesitter.get_string_parser = original_parser
			local formatted, highlights = render_part()
			assert.is_nil(formatted:find("**FORMATTED_MARKER**", 1, true))
			assert.is_truthy(formatted:find("FORMATTED_MARKER", 1, true))
			assert.equals(2, calls)
			local emphasized = false
			for _, span in ipairs(highlights) do
				if span.hl_group:find("Strong", 1, true) then emphasized = true end
			end
			assert.is_true(emphasized)

			local cached, cached_highlights = render_part()
			assert.equals(formatted, cached)
			assert.same(highlights, cached_highlights)
			assert.equals(2, calls)
		end)
	end
end)
