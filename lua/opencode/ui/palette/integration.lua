local M = {}
local actions = require("opencode.actions")
local function notify(message, err)
	vim.notify(message, err and vim.log.levels.WARN or vim.log.levels.INFO)
end
local function location()
	local state = require("opencode.state")
	return { directory = state.get_session_directory(state.get_session().id) or vim.fn.getcwd() }
end
local function menu(items, title, callback)
	if #items == 0 then notify("No " .. title:lower() .. " available"); return end
	require("opencode.ui.menu").open({ items = items, title = " " .. title .. " ", width = 64, searchable = true, on_select = callback })
end

local function attempt(integration, method, answer, opts)
	local float = require("opencode.ui.float")
	local popup, bufnr = float.create_centered_popup({ title = " " .. integration.name .. " ", width = 76, height = 14 })
	popup:mount()
	local id, snapshot, closed
	local function close()
		if closed then return end
		closed = true
		if id then actions.cancel_integration_attempt(id) end
		popup:unmount()
	end
	local function render(value)
		snapshot, id = value, value.id
		if closed then return end
		local lines = { "Authorization: " .. value.status, "" }
		if value.instructions then vim.list_extend(lines, vim.split(value.instructions, "\n", { plain = true })) end
		if value.url then lines[#lines + 1] = value.url end
		if value.error then lines[#lines + 1] = value.error end
		lines[#lines + 1] = ""
		lines[#lines + 1] = "o: open authorization URL   c: enter code   Esc: close / cancel"
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = false
		if value.status == "complete" then notify("Connected to " .. integration.name); close() end
	end
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Starting authorization…", "Esc: cancel" })
	local mapopts = { buffer = bufnr, silent = true }
	vim.keymap.set("n", "<Esc>", close, mapopts)
	vim.keymap.set("n", "q", close, mapopts)
	vim.keymap.set("n", "o", function()
		if snapshot and snapshot.url and snapshot.status ~= "expired" then vim.ui.open(snapshot.url) end
	end, mapopts)
	vim.keymap.set("n", "c", function()
		if not snapshot or snapshot.status ~= "awaiting_user" or snapshot.mode ~= "code" then return end
		float.create_input_popup({ title = " Authorization code ", prompt = "Authorization code:", password = true,
			on_submit = function(code) if not closed then actions.complete_integration_attempt(id, code) end end })
	end, mapopts)
	vim.api.nvim_create_autocmd("BufWipeout", { buffer = bufnr, once = true, callback = close })
	id = actions.start_integration_attempt(integration.id, method, answer, opts, render)
end

local function connect(integration, method, opts)
	if method.type == "env" then
		notify("Configure " .. table.concat(method.names or {}, ", ") .. " in the OpenCode server environment, then restart that server")
		return
	end
	local function submit(answer)
		if answer == nil then return end
		if method.type == "key" then
			require("opencode.ui.float").create_input_popup({ title = " API key ", prompt = "API key for " .. integration.name .. ":", password = true,
				on_submit = function(key)
					actions.connect_integration_key(integration.id, key, answer, opts, function(err, result)
						if err then notify("Could not confirm connection to " .. integration.name, true)
						elseif not result or not vim.iter(result.connections or {}):any(function(c) return c.type == "credential" end) then notify("No connection was returned by the server", true)
						else notify("Connected to " .. integration.name) end
					end)
				end })
		elseif method.type == "oauth" or method.type == "command" then attempt(integration, method, answer, opts)
		else notify("Unsupported integration method: " .. tostring(method.type), true) end
	end
	if method.form and #method.form > 0 then
		require("opencode.ui.form").open(method.form, { title = integration.name .. " setup" }, submit)
	else submit(vim.empty_dict()) end
end

function M.connect(integration_id, opts)
	opts = vim.deepcopy(opts or location())
	actions.list_integrations(function(err, integrations)
		if err then notify("Could not list integrations", true); return end
		local items = {}
		for _, entry in ipairs(integrations) do
			if not integration_id or entry.id == integration_id then
				items[#items + 1] = { label = entry.name, value = entry.id, integration = entry,
					description = tostring(#(entry.connections or {})) .. " connection(s)" }
			end
		end
		local function select(item)
			local methods = {}
			for _, method in ipairs(item.integration.methods or {}) do
				methods[#methods + 1] = { label = method.label or method.type, method = method }
			end
			menu(methods, "Connection methods", function(choice) connect(item.integration, choice.method, opts) end)
		end
		if integration_id and #items == 1 then select(items[1]) else menu(items, "Integrations", select) end
	end, opts)
end

function M.connections()
	local opts = location()
	actions.list_integrations(function(err, integrations)
		if err then notify("Could not list connections", true); return end
		local items = {}
		for _, entry in ipairs(integrations) do
			for _, connection in ipairs(entry.connections or {}) do
				items[#items + 1] = { label = entry.name .. " · " .. (connection.label or connection.name),
					integration = entry, connection = connection, description = connection.type }
			end
		end
		menu(items, "Connections", function(item)
			local connection = item.connection
			if connection.type == "env" then
				notify("This connection comes from " .. connection.name .. ". Update the server environment to disconnect it.")
				return
			end
			menu({ { label = "Activate", value = "activate" }, { label = "Rename", value = "update" }, { label = "Disconnect", value = "remove" } },
				"Manage " .. connection.label, function(choice)
					local function apply(body)
						actions.change_credential(choice.value, item.integration.id, connection.id, body, opts, function(change_err, result)
							if change_err then notify("Could not confirm account change", true); return end
							if choice.value == "remove" then
								for _, remaining in ipairs(result.connections or {}) do
									if remaining.type == "credential" and remaining.id == connection.id then notify("Account is still present on the server", true); return end
								end
							end
							if choice.value ~= "remove" then
								local found = vim.iter(result.connections or {}):any(function(c)
									return c.type == "credential" and c.id == connection.id and (choice.value ~= "update" or c.label == body.label)
								end)
								if not found then notify("Account change was not confirmed by the server", true); return end
							end
							notify(choice.value == "remove" and "Account disconnected" or "Account updated")
						end)
					end
					if choice.value == "update" then
						require("opencode.ui.float").create_input_popup({ title = " Account label ", default = connection.label,
							on_submit = function(label) if label ~= "" then apply({ label = label }) end end })
					elseif choice.value == "remove" then
						vim.ui.select({ "Disconnect", "Cancel" }, { prompt = "Disconnect account " .. connection.label .. "?" }, function(value)
							if value == "Disconnect" then apply(nil) end
						end)
					else apply(nil) end
				end)
		end)
	end, opts)
end

function M.register(palette)
	palette.register({ id = "provider.connect", title = "Connect Provider", description = "Connect through an integration", category = "model", action = function() M.connect() end })
	palette.register({ id = "provider.disconnect", title = "Manage Connections", description = "Activate, rename or disconnect an account", category = "model", action = M.connections })
end
return M
