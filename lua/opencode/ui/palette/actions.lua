-- opencode.nvim - Action palette commands

local M = {}

local opencode_actions = require("opencode.actions")
local changes = require("opencode.artifact.changes")
local state = require("opencode.state")

require("opencode.ui.highlights").register("opencode.ui.status", function()
	vim.api.nvim_set_hl(0, "OpenCodeStatusNormal", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeStatusTitle", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeStatusFooter", { link = "FloatBorder", default = true })
end)

local function show_status_popup(lines, highlights, ctx)
	local Popup = require("opencode.ui.popup")
	local float_context = require("opencode.ui.float_context")
	local border_width, border_height = Popup.outer_insets()
	local groups = {}
	local longest = 0
	for _, line in ipairs(lines) do
		longest = math.max(longest, vim.fn.strdisplaywidth(line))
	end
	for _, mark in ipairs(highlights) do
		groups[mark.line] = mark.group
	end

	local function wrap_body(width)
		local body_lines, body_marks = {}, {}
		local text_width = math.max(1, width - 8)
		for index, line in ipairs(lines) do
			local parts = {}
			if line == "" then
				parts[1] = ""
			elseif vim.fn.strdisplaywidth(line) <= text_width then
				parts[1] = line
			else
				local part, part_width = "", 0
				for char_index = 0, vim.fn.strchars(line) - 1 do
					local char = vim.fn.strcharpart(line, char_index, 1)
					local char_width = vim.fn.strdisplaywidth(char)
					if part_width > 0 and part_width + char_width > text_width then
						parts[#parts + 1] = part
						part, part_width = "", 0
					end
					part = part .. char
					part_width = part_width + char_width
				end
				if part ~= "" then parts[#parts + 1] = part end
			end
			for _, part in ipairs(parts) do
				local text = part == "" and "" or "    " .. part
				body_lines[#body_lines + 1] = text
				if groups[index] then
					body_marks[#body_marks + 1] = {
						line = #body_lines - 1, col = 4, end_col = #text, hl_group = groups[index],
					}
				end
			end
		end
		return body_lines, body_marks
	end

	local function dimensions()
		local available_width = vim.o.columns
		local available_height = vim.o.lines - vim.o.cmdheight
		local ok, chat = pcall(require, "opencode.ui.chat")
		if ok and chat.is_visible and chat.is_visible() then
			local chat_win = chat.get_winid and chat.get_winid()
			if chat_win and vim.api.nvim_win_is_valid(chat_win) then
				available_width = math.min(available_width, vim.api.nvim_win_get_width(chat_win))
				available_height = math.min(available_height, vim.api.nvim_win_get_height(chat_win))
			end
			local bounds = chat.get_float_dims and chat.get_float_dims()
			if bounds and bounds.width and bounds.height then
				available_width = math.min(available_width, bounds.width - 2)
				available_height = math.min(available_height, bounds.height - 2)
			end
		end
		local width = math.max(1, math.min(math.max(45, longest + 8), 88, available_width - 4))
		local body_lines = wrap_body(width)
		local height = math.max(7, math.min(#body_lines + 6, math.floor(available_height * 0.78)))
		local relative, row, col, zindex = float_context.resolve_centered_placement(
			width + border_width, height + border_height
		)
		return width, height, relative, row, col, zindex or 80
	end

	local width, height, relative, row, col, zindex = dimensions()
	local win_options = {
		winhighlight = "Normal:OpenCodeStatusNormal,NormalNC:OpenCodeStatusNormal,EndOfBuffer:OpenCodeStatusNormal",
		winblend = 0,
		wrap = false,
		cursorline = false,
		scrolloff = 0,
		fillchars = "eob: ",
	}
	local popup, scroll_offset, max_scroll = nil, 0, 0
	local function draw()
		local actual_width = vim.api.nvim_win_get_width(popup.winid)
		local actual_height = vim.api.nvim_win_get_height(popup.winid)
		local body_lines, body_marks = wrap_body(actual_width)
		local visible_count = math.max(0, actual_height - 6)
		max_scroll = math.max(0, #body_lines - visible_count)
		scroll_offset = math.max(0, math.min(scroll_offset, max_scroll))
		local header = "    Status"
		local close_hint = "esc    "
		header = header .. string.rep(" ", math.max(1, actual_width - #header - #close_hint)) .. close_hint
		local view, marks = {}, {}
		for index = 1, actual_height do view[index] = "" end
		local header_row = math.min(2, actual_height)
		view[header_row] = header
		marks[#marks + 1] = { line = header_row - 1, col = 4, end_col = 10, hl_group = "OpenCodeStatusTitle" }
		for index = 1, visible_count do
			view[index + 3] = body_lines[scroll_offset + index] or ""
		end
		for _, mark in ipairs(body_marks) do
			local row = mark.line - scroll_offset + 3
			if row >= 3 and row < 3 + visible_count then
				marks[#marks + 1] = {
					line = row, col = mark.col, end_col = mark.end_col, hl_group = mark.hl_group,
				}
			end
		end
		local footer_row = math.max(1, actual_height - 1)
		view[footer_row] = "    j/k:scroll  q/esc:close"
		marks[#marks + 1] = {
			line = footer_row - 1, col = 4, end_col = #view[footer_row], hl_group = "OpenCodeStatusFooter",
		}
		popup:render(view, marks)
		vim.api.nvim_win_set_cursor(popup.winid, { math.min(4, actual_height), 0 })
	end
	local function relayout()
		local next_width, next_height, next_relative, next_row, next_col = dimensions()
		-- Without a visible chat, the placement helper may pick the focused
		-- Status window itself after mount. Keep the original anchor on resize.
		if type(next_relative) == "table" and next_relative.winid == popup.winid then
			next_relative = relative
			local container_width, container_height = vim.o.columns, vim.o.lines - vim.o.cmdheight
			if type(relative) == "table" and vim.api.nvim_win_is_valid(relative.winid) then
				container_width = vim.api.nvim_win_get_width(relative.winid)
				container_height = vim.api.nvim_win_get_height(relative.winid)
			end
			next_row = math.max(0, math.floor((container_height - next_height - border_height) / 2))
			next_col = math.max(0, math.floor((container_width - next_width - border_width) / 2))
		end
		popup:resize({
			relative = next_relative,
			position = { row = next_row, col = next_col },
			size = { width = next_width, height = next_height },
		})
		draw()
	end
	popup = Popup.new({
		content = {
			relative = relative,
			position = { row = row, col = col },
			size = { width = width, height = height },
			border = "none", enter = true, focusable = true, zindex = zindex,
			buf_options = { filetype = "opencode_status", modifiable = false },
			win_options = win_options,
		},
		focus_restore = "chat",
		on_resize = relayout,
		on_close = function()
			if ctx and type(ctx.resume_input) == "function" then vim.schedule(ctx.resume_input) end
		end,
	})
	popup:mount()
	draw()
	local function scroll(amount)
		local next_offset = math.max(0, math.min(scroll_offset + amount, max_scroll))
		if next_offset ~= scroll_offset then
			scroll_offset = next_offset
			draw()
		end
	end
	local function page_size()
		return math.max(1, vim.api.nvim_win_get_height(popup.winid) - 7)
	end
	for _, key in ipairs({ "j", "<Down>", "<ScrollWheelDown>" }) do
		vim.keymap.set("n", key, function() scroll(1) end, { buffer = popup.bufnr, noremap = true, silent = true })
	end
	for _, key in ipairs({ "k", "<Up>", "<ScrollWheelUp>" }) do
		vim.keymap.set("n", key, function() scroll(-1) end, { buffer = popup.bufnr, noremap = true, silent = true })
	end
	for _, key in ipairs({ "<C-d>", "<PageDown>", "<C-f>" }) do
		vim.keymap.set("n", key, function() scroll(page_size()) end, { buffer = popup.bufnr, noremap = true, silent = true })
	end
	for _, key in ipairs({ "<C-u>", "<PageUp>", "<C-b>" }) do
		vim.keymap.set("n", key, function() scroll(-page_size()) end, { buffer = popup.bufnr, noremap = true, silent = true })
	end
	vim.keymap.set("n", "G", function() scroll(math.huge) end,
		{ buffer = popup.bufnr, noremap = true, silent = true })
	vim.keymap.set("n", "gg", function() scroll(-math.huge) end,
		{ buffer = popup.bufnr, noremap = true, silent = true })
	local close = function() popup:close() end
	for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
		vim.keymap.set("n", key, close, { buffer = popup.bufnr, noremap = true, silent = true })
	end
	return popup
end

local function revert_pending_changes(pending, force)
	local edits = require("opencode.edit.state")
	local reverted = 0
	local conflicts = {}
	local issues = {}
	local refreshed = {}

	-- Undo newer proposals first when several reviews touch the same file.
	for index = #pending, 1, -1 do
		local change = pending[index]
		local ok, err, reason, permission_id = edits.revert_change(change.id, { force = force })
		if ok then
			reverted = reverted + 1
			if permission_id then refreshed[permission_id] = true end
		elseif reason == "conflict" then
			table.insert(conflicts, err or change.filepath)
		else
			table.insert(issues, "Could not revert " .. change.filepath .. ": " .. tostring(err or "unknown error"))
		end
	end

	local ok_chat, chat_edits = pcall(require, "opencode.ui.chat.edits")
	for permission_id in pairs(refreshed) do
		local estate = edits.get_edit(permission_id)
		local rpc = estate and estate.transport == "review_rpc"
		local ok, result = false, chat_edits
		if ok_chat then
			ok, result = pcall(rpc and chat_edits.refresh_edit or chat_edits.rerender_edit, permission_id)
		end
		if not ok or (rpc and not result) then
			local label = rpc and "Review reply not sent for " or "Review UI could not refresh for "
			table.insert(issues, label .. permission_id .. ": " .. (not ok and tostring(result) or "retry from review widget"))
		end
	end

	local summary = string.format("Reverted %d of %d pending changes", reverted, #pending)
	if #conflicts > 0 then
		summary = summary .. "\nPreserved files changed since review:\n" .. table.concat(conflicts, "\n")
	end
	if #issues > 0 then summary = summary .. "\n" .. table.concat(issues, "\n") end
	local level = #issues > 0 and vim.log.levels.ERROR
		or (#conflicts > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
	vim.notify(summary, level)
end

function M.register(palette)
	palette.register({
		id = "action.abort",
		title = "Abort Request",
		description = "Stop the current AI request",
		category = "actions",
		keybind = "<leader>ox",
		run = function()
			opencode_actions.abort()
		end,
		enabled = function()
			return state.is_streaming() or state.is_thinking()
		end,
		suggested = true,
	})
	palette.register({
		id = "action.clear",
		title = "Clear Chat",
		description = "Clear the current chat without switching sessions",
		category = "actions",
		keybind = "<leader>oc",
		slash = { name = "clear" },
		run = function()
			opencode_actions.clear()
		end,
	})
	palette.register({
		id = "action.danger_mode.enable",
		title = "Enable Danger Mode",
		description = "Auto-approve permission requests until disabled",
		category = "actions",
		run = function()
			opencode_actions.enable_danger_mode()
		end,
		enabled = function()
			return not state.is_danger_mode_enabled()
		end,
	})
	palette.register({
		id = "action.danger_mode.disable",
		title = "Disable Danger Mode",
		description = "Stop auto-approving permission requests",
		category = "actions",
		run = function()
			opencode_actions.disable_danger_mode()
		end,
		enabled = function()
			return state.is_danger_mode_enabled()
		end,
	})
	palette.register({
		id = "action.paste_clipboard",
		title = "Paste Clipboard",
		description = "Paste text or attach a screenshot to the OpenCode input",
		category = "actions",
		keybind = "<C-v>",
		run = function()
			opencode_actions.paste_clipboard()
		end,
	})
	palette.register({
		id = "action.compact",
		title = "Compact Session",
		description = "Compact session messages",
		category = "actions",
		slash = { name = "compact", aliases = { "summarize" } },
		run = function()
			local session = state.get_session()
			if not session.id then
				vim.notify("No active session to compact", vim.log.levels.WARN)
				return
			end

				opencode_actions.compact_session(session.id, {}, function(err)
					if err then
						vim.notify("Failed to compact session: " .. tostring(err.message or err), vim.log.levels.ERROR)
						return
					end
					vim.notify("Session compaction started", vim.log.levels.INFO)
				end)
			end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "action.revert",
		title = "Revert Changes",
		description = "Revert pending changes safely or force overwrite current files",
		category = "actions",
		run = function()
			local pending = changes.get_pending()
			if #pending == 0 then
				vim.notify("No pending changes to revert", vim.log.levels.INFO)
				return
			end

			local safe_choice = "Revert safely (keep later edits)"
			local force_choice = "Force overwrite changed files..."
			local force_confirm = "Yes, overwrite or delete current files"
			local prompt = "Revert " .. #pending .. " pending changes?"
			require("opencode.ui.menu").open({
				items = { safe_choice, force_choice, "Cancel" },
				title = "Revert Changes",
				message = prompt,
				width = vim.fn.strdisplaywidth(prompt) + 12,
				sort = false,
				on_select = function(choice)
					if choice == safe_choice then
						revert_pending_changes(pending, false)
					elseif choice == force_choice then
						local force_prompt = "Are you sure? This discards saved edits made after review in up to " .. #pending .. " files."
						require("opencode.ui.menu").open({
							items = { force_confirm, "Cancel" },
							title = "Force Revert",
							message = force_prompt,
							width = vim.fn.strdisplaywidth(force_prompt) + 12,
							sort = false,
							on_select = function(confirmation)
								if confirmation == force_confirm then
									revert_pending_changes(pending, true)
								end
							end,
						})
					end
				end,
			})
		end,
		enabled = function()
			return #changes.get_pending() > 0
		end,
	})
	palette.register({
		id = "action.status",
		title = "Show Status",
		description = "Show current session and connection status",
		category = "actions",
		slash = { name = "status" },
		on_select = function(ctx) return ctx.run() end,
		run = function(ctx)
			-- Fetch full status from server (combines multiple endpoints)
				opencode_actions.get_server_status(function(err, server_status)
				vim.schedule(function()
					local lines = {}
					local highlights = {}

					-- Helper to add a line with optional highlight
					local function add_line(text, hl_group)
						table.insert(lines, text)
						if hl_group then
							table.insert(highlights, { line = #lines, group = hl_group })
						end
					end

					-- Helper to add a section header
					local function add_section(title, count)
						if #lines > 0 then
							add_line("")
						end
						local header = count and string.format("%d %s", count, title) or title
						add_line(header, "Title")
					end

					-- Version
					if server_status and server_status.version then
						add_line("OpenCode v" .. server_status.version, "Type")
					elseif not err then
						add_line("OpenCode", "Type")
					else
						add_line("OpenCode (disconnected)", "ErrorMsg")
					end

					-- MCP Servers: Record<string, {status: "connected"|"disabled"|"failed"|...}>
					if server_status and server_status.mcp then
						local mcp_list = {}
						for name, info in pairs(server_status.mcp) do
							table.insert(mcp_list, { name = name, info = info })
						end
						table.sort(mcp_list, function(a, b)
							return a.name < b.name
						end)

						if #mcp_list > 0 then
							add_section("MCP Servers", #mcp_list)
							for _, mcp in ipairs(mcp_list) do
								local status_text = type(mcp.info) == "table" and mcp.info.status or "unknown"
								-- Capitalize first letter
								local display_status = status_text:sub(1, 1):upper() .. status_text:sub(2)
								local status_hl = status_text == "connected" and "DiagnosticOk" or "DiagnosticWarn"
								add_line("• " .. mcp.name .. " " .. display_status, status_hl)
							end
						end
					end

					if server_status and server_status.plugins and #server_status.plugins > 0 then
						add_section("Plugins", #server_status.plugins)
						for _, plugin in ipairs(server_status.plugins) do
							local source, status = plugin.source or {}, plugin.state or {}
							local name = plugin.id or source.target or source.path or source.type or "unknown"
							local version = source.version and (" @" .. source.version) or ""
							add_line("• " .. name .. version .. " — " .. (status.status or "unknown"))
							if status.error then add_line("  " .. status.error, "DiagnosticError") end
						end
					end
					for domain, message in pairs(server_status and server_status.errors or {}) do
						add_line(domain .. ": " .. message, "DiagnosticWarn")
					end

					-- If server didn't return any data, show local state
					if err or not server_status or (not server_status.version and not server_status.mcp) then
						local summary = state.get_status_summary()
						if #lines == 0 or (err and #lines <= 1) then
							add_line("")
						end

						local conn_icon = summary.connected and "●" or "○"
						local conn_status = summary.connected and "connected" or summary.connection_state
						local conn_hl = summary.connected and "DiagnosticOk" or "DiagnosticError"
						add_line("Connection: " .. conn_icon .. " " .. conn_status, conn_hl)

						if err then
							add_line("")
							add_line("(Could not fetch full status from server)", "Comment")
						end
					end

					show_status_popup(lines, highlights, ctx)
				end)
			end)
		end,
		suggested = true,
	})
end

return M
