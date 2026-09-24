-- opencode.nvim - MCP palette commands

local M = {}

local actions = require("opencode.actions")
local function location_options()
	local state = require("opencode.state")
	return { directory = state.get_session_directory(state.get_session().id) or vim.fn.getcwd() }
end

local function mcp_value_to_text(value)
	if value == nil or value == vim.NIL then
		return nil
	end
	local value_type = type(value)
	if value_type == "string" then
		return value
	end
	if value_type == "number" or value_type == "boolean" then
		return tostring(value)
	end
	return vim.inspect(value)
end

local function split_line_at_width(line, max_width)
	if vim.fn.strdisplaywidth(line) <= max_width then
		return line, ""
	end

	local char_count = vim.fn.strchars(line)
	local low = 1
	local high = char_count
	local best = 1
	while low <= high do
		local mid = math.floor((low + high) / 2)
		local candidate = vim.fn.strcharpart(line, 0, mid)
		if vim.fn.strdisplaywidth(candidate) <= max_width then
			best = mid
			low = mid + 1
		else
			high = mid - 1
		end
	end

	if best < char_count then
		local min_break = math.max(1, math.floor(best * 0.5))
		for i = best, min_break, -1 do
			local ch = vim.fn.strcharpart(line, i - 1, 1)
			if ch:match("%s") then
				best = i
				break
			end
		end
	end

	local head = vim.fn.strcharpart(line, 0, best):gsub("%s+$", "")
	local tail = vim.fn.strcharpart(line, best):gsub("^%s+", "")
	if head == "" then
		head = vim.fn.strcharpart(line, 0, 1)
		tail = vim.fn.strcharpart(line, 1)
	end
	return head, tail
end

local function append_wrapped(lines, text, width, indent, continuation_indent)
	indent = indent or ""
	continuation_indent = continuation_indent or indent
	text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")

	for _, raw_line in ipairs(vim.split(text, "\n", { plain = true })) do
		if raw_line == "" then
			table.insert(lines, indent)
		else
			local remaining = raw_line
			local line_indent = indent
			while remaining ~= "" do
				local max_width = math.max(10, width - vim.fn.strdisplaywidth(line_indent))
				local chunk, rest = split_line_at_width(remaining, max_width)
				table.insert(lines, line_indent .. chunk)
				remaining = rest
				line_indent = continuation_indent
			end
		end
	end
end

local function show_mcp_server_info(item)
	local float = require("opencode.ui.float")
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }
	local width = math.max(20, math.min(90, ui.width - 8))
	local content_width = math.max(20, width - 2)
	local server = type(item.server) == "table" and item.server or {}
	local lines = {
		"Name: " .. tostring(item.value),
		"Status: " .. tostring(item.status_text or item.status or "unknown"),
	}

	local error_text = mcp_value_to_text(server.error or server.message or item.description)
	if error_text and vim.trim(error_text) ~= "" then
		table.insert(lines, "")
		table.insert(lines, "Message:")
		append_wrapped(lines, error_text, content_width, "  ", "  ")
	else
		table.insert(lines, "")
		table.insert(lines, "No detailed message was reported for this server.")
	end

	local detail_keys = {}
	for key, _ in pairs(server) do
		if key ~= "error" and key ~= "message" then
			table.insert(detail_keys, key)
		end
	end
	table.sort(detail_keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	if #detail_keys > 0 then
		table.insert(lines, "")
		table.insert(lines, "Details:")
		for _, key in ipairs(detail_keys) do
			local label = "  " .. tostring(key) .. ": "
			append_wrapped(lines, label .. (mcp_value_to_text(server[key]) or ""), content_width, "", "    ")
		end
	end


	local max_height = math.max(4, ui.height - 6)
	local height = math.min(math.max(8, #lines + 2), max_height)
	local popup, bufnr = float.create_centered_popup({
		title = " MCP Server Info ",
		width = width,
		height = height,
		zindex = 90,
	})
	local close_fn = function()
		pcall(function()
			popup:unmount()
		end)
	end

	popup:mount()
	vim.bo[bufnr].modifiable = true
	vim.bo[bufnr].filetype = "opencode_float"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
		vim.wo[popup.winid].wrap = false
		vim.wo[popup.winid].cursorline = false
		vim.api.nvim_win_set_cursor(popup.winid, { 1, 0 })
	end
	float.setup_close_keymaps(bufnr, close_fn)
	vim.keymap.set("n", "<C-c>", close_fn, { buffer = bufnr, noremap = true, silent = true })
end

function M.register(palette)
	palette.register({
		id = "mcp.status",
		title = "MCP Servers",
		description = "List and toggle MCP servers",
		category = "mcp",
		action = function()
			local opts = location_options()
			actions.get_mcp_status(function(err, status)
				if err then
					vim.notify("Failed to get MCP status: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end
				if not status or vim.tbl_isempty(status) then
					vim.notify("No MCP servers configured", vim.log.levels.INFO)
					return
				end

				local function format_status(server)
					local value = type(server) == "table" and server.status or nil
					if value == "connected" then
						return "connected", "●", "Connected", 3
					end
					if value == "pending" then return "pending", "…", "Connecting", 2 end
					if value == "disabled" then
						return "disabled", "○", "Disabled", 2
					end
					if value == "failed" then
						return "failed", "×", "Failed", 1
					end
					if value == "needs_auth" then
						return "needs_auth", "!", "Needs auth", 1
					end
					if value == "needs_client_registration" then
						return "needs_client_registration", "!", "Needs client ID", 1
					end
					return value or "unknown", "?", "Unknown", 0
				end

				local function describe_server(server)
					if type(server) ~= "table" then
						return nil
					end
					if server.status == "failed" and server.error then
						return tostring(server.error)
					end
					if server.status == "needs_client_registration" and server.error then
						return tostring(server.error)
					end
					local _, _, text = format_status(server)
					return text
				end

				local function update_item(item, server)
					local status_value, icon, status_text, priority = format_status(server)
					item.server = server
					item.status = status_value
					item.label = string.format("%s %s", icon, item.value)
					item.description = describe_server(server)
					item.priority = priority
					item.status_text = status_text
				end

				local items = {}
				for name, server in pairs(status) do
					local item = { value = name }
					update_item(item, server)
					table.insert(items, item)
				end

				table.sort(items, function(a, b)
					return a.value < b.value
				end)

				local function refresh_item(item, ctx)
					actions.get_mcp_status(function(refresh_err, refreshed)
						if refresh_err then
							vim.notify(
								"Failed to refresh MCP status: " .. tostring(refresh_err.message or refresh_err),
								vim.log.levels.ERROR
							)
							return
						end
						if refreshed then
							update_item(item, refreshed[item.value] or { status = "unknown" })
							ctx.refresh()
							vim.notify(item.value .. ": " .. item.status_text, vim.log.levels.INFO)
						end
					end, opts)
				end

				local menu = require("opencode.ui.menu")
				menu.open({
					items = items,
					title = " MCP Servers ",
					width = 60,
					searchable = true,
					close_on_select = false,
					sort = function(a, b)
						return a.value < b.value
					end,
					on_select = function(item)
						vim.notify(
							item.value .. ": " .. (item.description or item.status_text or item.status),
							vim.log.levels.INFO
						)
					end,
					keys = {
						{
							key = "i",
							label = "i:info",
							handler = function(ctx, item)
								ctx.close()
								vim.schedule(function()
									show_mcp_server_info(item)
								end)
							end,
						},
						{
							key = "t",
							label = "t:toggle",
							handler = function(ctx, item)
								if item.pending or item.status == "pending" then return end
								item.pending = true
								local was_connected = item.status == "connected"
								actions.toggle_mcp(item.value, was_connected, function(toggle_err)
									item.pending = false
									if toggle_err then
										vim.notify(
											"Failed to toggle MCP server "
												.. item.value
												.. ": "
												.. tostring(toggle_err.message or toggle_err),
											vim.log.levels.ERROR
										)
										return
									end
									refresh_item(item, ctx)

								end, opts)
							end,
						},
						{ key = "a", label = "a:auth", handler = function(ctx, item)
							local integration_id = item.server and item.server.integrationID
							if not integration_id then vim.notify("This MCP server has no linked integration", vim.log.levels.INFO); return end
							ctx.close()
							require("opencode.ui.palette.integration").connect(integration_id, opts)
						end },
						{ key = "r", label = "r:refresh", handler = function(ctx, item) refresh_item(item, ctx) end },

					},
				})
			end, opts)
		end,
	})
	palette.register({ id = "mcp.tools", title = "MCP Tools", description = "MCP tool catalog availability", category = "mcp",
		action = function()
			vim.notify("OpenCode 2.0.11 does not expose an MCP tool catalog. MCP Servers shows connection status.", vim.log.levels.INFO)
		end })
end
return M
