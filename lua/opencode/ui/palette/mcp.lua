-- opencode.nvim - MCP palette commands

local M = {}

local client = require("opencode.client")

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

local function opencode_log_dir()
	local xdg_data = os.getenv("XDG_DATA_HOME")
	if xdg_data and xdg_data ~= "" then
		return xdg_data .. "/opencode/log"
	end
	local home = os.getenv("HOME")
	if not home or home == "" then
		return nil
	end
	return home .. "/.local/share/opencode/log"
end

local function recent_mcp_log_lines(server_name, limit)
	limit = limit or 8
	local dir = opencode_log_dir()
	if not dir then
		return {}
	end

	local uv = vim.uv or vim.loop
	local handle = uv.fs_scandir(dir)
	if not handle then
		return {}
	end

	local files = {}
	while true do
		local name, kind = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if kind == "file" and name:match("%.log$") then
			local path = dir .. "/" .. name
			local stat = uv.fs_stat(path)
			table.insert(files, { path = path, mtime = stat and stat.mtime and stat.mtime.sec or 0 })
		end
	end
	table.sort(files, function(a, b)
		return a.mtime > b.mtime
	end)

	local matches = {}
	for i, file in ipairs(files) do
		if i > 6 then
			break
		end
		local fd = io.open(file.path, "r")
		if fd then
			for line in fd:lines() do
				local is_mcp_line = line:find("service=mcp", 1, true)
					and line:find("key=" .. tostring(server_name), 1, true)
				local is_useful = line:find("mcp stderr:", 1, true) or line:find("ERROR", 1, true)
				if is_mcp_line and is_useful then
					table.insert(matches, line)
					if #matches > limit then
						table.remove(matches, 1)
					end
				end
			end
			fd:close()
		end
	end

	return matches
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

	local log_lines = recent_mcp_log_lines(item.value, 8)
	if #log_lines > 0 then
		table.insert(lines, "")
		table.insert(lines, "Recent log:")
		for _, line in ipairs(log_lines) do
			append_wrapped(lines, line, content_width, "  ", "  ")
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
		keybind = "<leader>oS",
		action = function()
			client.get_mcp_status(function(err, status)
				if err then
					vim.schedule(function()
						vim.notify("Failed to get MCP status: " .. tostring(err.message or err), vim.log.levels.ERROR)
					end)
					return
				end
				vim.schedule(function()
					if not status or vim.tbl_isempty(status) then
						vim.notify("No MCP servers configured", vim.log.levels.INFO)
						return
					end

					local function format_status(server)
						local value = type(server) == "table" and server.status or nil
						if value == "connected" then
							return "connected", "●", "Connected", 3
						end
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
						local item = {
							value = name,
						}
						update_item(item, server)
						table.insert(items, item)
					end

					table.sort(items, function(a, b)
						return a.value < b.value
					end)

					local function refresh_item(item, render)
						client.get_mcp_status(function(refresh_err, refreshed)
							if refresh_err then
								vim.notify(
									"Failed to refresh MCP status: " .. tostring(refresh_err.message or refresh_err),
									vim.log.levels.ERROR
								)
								return
							end
							if refreshed then
								local sync = require("opencode.sync")
								sync.handle_mcp(refreshed)
								update_item(item, refreshed[item.value] or { status = "disabled" })
								if render then
									render()
								end
							end
						end)
					end

					local float = require("opencode.ui.float")
					float.create_searchable_menu(items, function(item)
						vim.notify(
							item.value .. ": " .. (item.description or item.status_text or item.status),
							vim.log.levels.INFO
						)
					end, {
						title = " MCP Servers ",
						width = 60,
						close_on_select = false,
						custom_keys = {
							{
								key = "i",
								text = "i:info",
								on_key = function(item, _render, close_menu)
									close_menu()
									vim.schedule(function()
										show_mcp_server_info(item)
									end)
									return true
								end,
							},
							{
								key = "t",
								text = "t:toggle",
								on_key = function(item, render)
									local was_connected = item.status == "connected"
									local toggle = was_connected and client.disconnect_mcp or client.connect_mcp
									toggle(item.value, function(toggle_err)
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
										refresh_item(item, render)
										vim.notify(
											item.value .. (was_connected and " disabled" or " enabled"),
											vim.log.levels.INFO
										)
									end)
									return true
								end,
							},
						},
						sort_fn = function(a, b)
							return a.value < b.value
						end,
					})
				end)
			end)
		end,
	})
	palette.register({
		id = "mcp.tools",
		title = "MCP Tools",
		description = "List available MCP tools",
		category = "mcp",
		action = function()
			client.get_mcp_status(function(err, status)
				if err then
					vim.schedule(function()
						vim.notify("Failed to get MCP status: " .. tostring(err.message or err), vim.log.levels.ERROR)
					end)
					return
				end
				vim.schedule(function()
					if not status then
						vim.notify("No MCP servers configured", vim.log.levels.INFO)
						return
					end

					-- Collect all tools from all servers
					local all_tools = {}
					for server_name, server in pairs(status) do
						if server.tools then
							for _, tool in ipairs(server.tools) do
								table.insert(all_tools, {
									name = tool.name,
									description = tool.description,
									server = server_name,
								})
							end
						end
					end

					if #all_tools == 0 then
						vim.notify("No MCP tools available", vim.log.levels.INFO)
						return
					end

					-- Show tools in a menu
					local items = {}
					for _, tool in ipairs(all_tools) do
						table.insert(items, {
							label = string.format("%s: %s", tool.server, tool.name),
							tool = tool,
						})
					end

					local float = require("opencode.ui.float")
					float.create_menu(items, function(item)
						vim.notify(
							string.format("Tool: %s - %s", item.tool.name, item.tool.description or "No description"),
							vim.log.levels.INFO
						)
					end, { title = " MCP Tools (" .. #all_tools .. ") " })
				end)
			end)
		end,
	})
	palette.register({
		id = "mcp.refresh",
		title = "Refresh MCP",
		description = "Refresh MCP server connections",
		category = "mcp",
		action = function()
			-- Note: This is a placeholder - actual refresh functionality
			-- depends on server API support
			vim.notify("Refresh MCP - not yet implemented in server API", vim.log.levels.WARN)
		end,
	})
end

return M
