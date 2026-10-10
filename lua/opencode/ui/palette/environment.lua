local M = {}
local state = require("opencode.state")
local actions = require("opencode.actions")
local menu = require("opencode.ui.menu")
local pending = require("opencode.session.pending")

function M.show()
	local session_id = state.get_session().id
	if not session_id then vim.notify("Select a session before setting its environment", vim.log.levels.WARN); return end
	local record = state.get_session_record(session_id) or {}
	if record.location and record.location.workspaceID then
		vim.notify("Session environment applies only to local shell commands; this session uses a workspace", vim.log.levels.WARN); return
	end
	local token = pending.token(session_id)
	local function current() return state.get_session().id == session_id and pending.is_current(token) end
	local function replace(variables)
		if not current() then return end
		menu.open({ title = " Replace session environment ", width = 82, sort = false,
			message = "Replaces every variable, including PATH. The server cannot read or restore inherited values.",
			items = { "Replace complete environment", "Cancel" }, on_select = function(choice)
				if choice ~= "Replace complete environment" or not current() then return end
				actions.set_session_environment(session_id, variables, function(err)
					if not current() then return end
					local unsupported = err and (err.status == 404 or err.status == 405 or err.status == 501)
					vim.notify(err and (unsupported and "This server does not support session environment" or err.status == 503 and "Session environment is temporarily unavailable on this server" or "Session environment change was not confirmed")
						or "Session environment replaced", err and vim.log.levels.WARN or vim.log.levels.INFO)
				end)
			end })
	end
	menu.open({ title = " Session environment ", width = 80, sort = false,
		message = "Write-only native setting. No saved variables are exposed by the server.", items = {
			{ value = "replace", label = "Replace with a JSON object", description = "All names and values must be strings" },
			{ value = "import", label = "Import a JSON file", description = "Local file containing the complete variable map" },
			{ value = "empty", label = "Replace with an empty environment", description = "Does not restore the host's inherited environment" },
		}, on_select = function(item)
			if not current() then return end
			if item.value == "empty" then replace(vim.empty_dict()); return end
			require("opencode.ui.float").create_input_popup({
				title = item.value == "import" and " Import environment JSON " or " Replace environment JSON ",
				prompt = item.value == "import" and "Local file:" or "JSON variables:", password = item.value == "replace",
				width = 76, on_submit = function(value)
					if not current() then return end
					local variables
					if item.value == "import" then variables = require("opencode.util.json_file").read(vim.fn.expand(value))
					else local ok, parsed = pcall(vim.json.decode, value); if ok then variables = parsed end end
					if type(variables) ~= "table" or vim.islist(variables) then
						vim.notify("Enter a JSON object with string names and values", vim.log.levels.WARN); return
					end
					for key, entry in pairs(variables) do
						if type(key) ~= "string" or type(entry) ~= "string" or key == "" or key:find("[=%z]") or entry:find("%z") then
							vim.notify("Environment names and values must be valid strings", vim.log.levels.WARN); return
						end
					end
					replace(variables)
				end,
			})
		end })
end

function M.register(palette)
	palette.register({ id = "session.environment", title = "Session Environment", category = "session",
		description = "Replace the complete environment used by local shell commands", slash = { name = "environment" },
		run = M.show, on_select = function(context) return context.run() end })
end

return M
