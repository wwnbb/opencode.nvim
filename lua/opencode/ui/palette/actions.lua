-- opencode.nvim - Action palette commands

local M = {}

local opencode_actions = require("opencode.actions")
local changes = require("opencode.artifact.changes")
local client = require("opencode.client")
local lifecycle = require("opencode.lifecycle")
local state = require("opencode.state")

local hl_ns = vim.api.nvim_create_namespace("opencode_palette")
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

			local compact_opts = {}
			local local_ok, lc = pcall(require, "opencode.local")
			if local_ok and lc and lc.model and type(lc.model.current) == "function" then
				local current_model = lc.model.current()
				if current_model and current_model.providerID and current_model.modelID then
					compact_opts.providerID = current_model.providerID
					compact_opts.modelID = current_model.modelID
				end
			end

			if not compact_opts.providerID or not compact_opts.modelID then
				local state_model = state.get_model()
				if state_model and state_model.provider and state_model.id then
					compact_opts.providerID = state_model.provider
					compact_opts.modelID = state_model.id
				end
			end

			if not compact_opts.providerID or not compact_opts.modelID then
				vim.notify("No model selected for compaction", vim.log.levels.WARN)
				return
			end

			lifecycle.ensure_connected(function()
				client.summarize_session(session.id, compact_opts, function(err)
					if err then
						if type(err) == "table" and err.status == 404 then
							client.execute_command(session.id, "compact", {}, {}, function(fallback_err)
								vim.schedule(function()
									if fallback_err then
										vim.notify(
											"Failed to compact session: "
												.. tostring(fallback_err.message or fallback_err),
											vim.log.levels.ERROR
										)
										return
									end
									vim.notify("Session compaction started", vim.log.levels.INFO)
								end)
							end)
							return
						end
						vim.schedule(function()
							vim.notify(
								"Failed to compact session: " .. tostring(err.message or err),
								vim.log.levels.ERROR
							)
						end)
						return
					end
					vim.schedule(function()
						vim.notify("Session compaction started", vim.log.levels.INFO)
					end)
				end)
			end)
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "action.revert",
		title = "Revert Changes",
		description = "Revert all pending changes",
		category = "actions",
		action = function()
			local pending = changes.get_pending()
			if #pending == 0 then
				vim.notify("No pending changes to revert", vim.log.levels.INFO)
				return
			end

			vim.ui.select({ "Yes", "No" }, {
				prompt = "Revert all " .. #pending .. " pending changes?",
			}, function(choice)
				if choice == "Yes" then
					for _, change in ipairs(pending) do
						changes.reject(change.id)
					end
					vim.notify("Reverted all changes", vim.log.levels.INFO)
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
			client.get_status(function(err, server_status)
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

					-- LSP Servers: [{id, name, root, status}]
					if server_status and server_status.lsp and #server_status.lsp > 0 then
						add_section("LSP Servers", #server_status.lsp)
						for _, lsp in ipairs(server_status.lsp) do
							local name = lsp.name or lsp.id or "unknown"
							local status_hl = lsp.status == "connected" and "DiagnosticOk" or "DiagnosticWarn"
							add_line("• " .. name, status_hl)
						end
					end

					-- Formatters: [{name, extensions, enabled}]
					if server_status and server_status.formatters then
						-- Filter to only enabled formatters
						local enabled_formatters = {}
						for _, fmt in ipairs(server_status.formatters) do
							if fmt.enabled ~= false then
								table.insert(enabled_formatters, fmt)
							end
						end

						if #enabled_formatters > 0 then
							add_section("Formatters", #enabled_formatters)
							for _, fmt in ipairs(enabled_formatters) do
								add_line("• " .. (fmt.name or "unknown"))
							end
						end
					end

					-- Plugins: ["name@version", "file:///path/to/plugin", ...]
					if server_status and server_status.plugins and #server_status.plugins > 0 then
						add_section("Plugins", #server_status.plugins)
						for _, plugin_str in ipairs(server_status.plugins) do
							local name, version
							if plugin_str:match("^file://") then
								-- Extract name from file path
								name = plugin_str:match("([^/]+)$") or plugin_str
								version = nil
							elseif plugin_str:find("@") then
								-- Split name@version
								name, version = plugin_str:match("^(.+)@(.+)$")
							else
								name = plugin_str
								version = "latest"
							end
							local display = version and (name .. " @" .. version) or name
							add_line("• " .. display)
						end
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
