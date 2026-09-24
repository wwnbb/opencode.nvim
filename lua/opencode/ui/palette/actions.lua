-- opencode.nvim - Action palette commands

local M = {}

local opencode_actions = require("opencode.actions")
local changes = require("opencode.artifact.changes")
local selectors = require("opencode.selectors")
local state = require("opencode.state")

local hl_ns = vim.api.nvim_create_namespace("opencode_palette")

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
		action = function()
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
		action = function()
			opencode_actions.clear()
		end,
	})
	palette.register({
		id = "action.danger_mode.enable",
		title = "Enable Danger Mode",
		description = "Auto-approve permission requests until disabled",
		category = "actions",
		action = function()
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
		action = function()
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
		action = function()
			opencode_actions.paste_clipboard()
		end,
	})
	palette.register({
		id = "action.compact",
		title = "Compact Session",
		description = "Compact session messages",
		category = "actions",
		action = function()
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
		action = function()
			local pending = changes.get_pending()
			if #pending == 0 then
				vim.notify("No pending changes to revert", vim.log.levels.INFO)
				return
			end

			local safe_choice = "Revert safely (keep later edits)"
			local force_choice = "Force overwrite changed files..."
			local force_confirm = "Yes, overwrite or delete current files"
			vim.ui.select({ safe_choice, force_choice, "Cancel" }, {
				prompt = "Revert " .. #pending .. " pending changes?",
			}, function(choice)
				if choice == safe_choice then
					revert_pending_changes(pending, false)
				elseif choice == force_choice then
					vim.ui.select({ force_confirm, "Cancel" }, {
						prompt = "Are you sure? This discards saved edits made after review in up to " .. #pending .. " files.",
					}, function(confirmation)
						if confirmation == force_confirm then
							revert_pending_changes(pending, true)
						end
					end)
				end
			end)
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
		action = function()
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

					-- Create floating window
					local float = require("opencode.ui.float")
					local width = 45
					local height = math.min(#lines + 2, 25)

					local popup, bufnr = float.create_centered_popup({
						width = width,
						height = height,
						title = "Status",
						border = "rounded",
					})

					popup:mount()

					vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

					for _, hl in ipairs(highlights) do
						local lt = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, hl.line, false)[1] or ""
						vim.api.nvim_buf_set_extmark(
							bufnr,
							hl_ns,
							hl.line - 1,
							0,
							{ end_col = #lt, hl_group = hl.group }
						)
					end

					vim.bo[bufnr].modifiable = false
					vim.bo[bufnr].buftype = "nofile"

					local close_fn = function()
						popup:unmount()
					end
					float.setup_close_keymaps(bufnr, close_fn)
				end)
			end)
		end,
		suggested = true,
	})
end

return M
