local M = {}
local registry = require("opencode.command_registry")

-- opts: { name, aliases, description, category, handler, enabled?, on_select? }
function M.register(opts)
	if not opts.name or not opts.handler then
		error("Slash command must have name and handler")
	end
	return registry.register({
		id = "slash." .. opts.name,
		title = "/" .. opts.name,
		description = opts.description or "",
		category = opts.category or "general",
		palette = false,
		slash = { name = opts.name, aliases = opts.aliases or {} },
		run = function(context)
			return opts.handler(context.args or "", context.parsed)
		end,
		enabled = opts.enabled,
		on_select = opts.on_select,
		enter_with_args = opts.enter_with_args,
		with_parts = opts.with_parts,
	})
end

function M.unregister(name)
	local record = registry.get_slash(name)
	if not record or record.slash.name ~= name then
		return false
	end
	if record.palette == false then
		return registry.unregister(record.id)
	end
	-- A shared command may still be available in the palette after its
	-- slash entry point is removed.
	local replacement = {}
	for key, value in pairs(record) do
		if key ~= "slash" and key ~= "_serial" then
			replacement[key] = value
		end
	end
	registry.register(replacement)
	return true
end

-- Returns: { command, args, raw } or nil if not a slash command
function M.parse(text)
	if not text then
		return nil
	end

	local cmd_name, args_str = text:match("^/(%S+)%s*([%s%S]*)$")
	if not cmd_name then
		return nil
	end
	
	return {
		command = cmd_name,
		args = args_str,
		raw = text,
	}
end

-- Returns: true if handled, false otherwise
function M.execute(parsed, context)
	if not parsed or not parsed.command then
		return false
	end
	local record = registry.get_slash(parsed.command)
	if not record then
		vim.notify("Unknown command: /" .. parsed.command, vim.log.levels.WARN)
		return false
	end
	local command_context = {
		source = "slash",
		args = parsed.args or "",
		parsed = parsed,
	}
	for key, value in pairs(context or {}) do
		command_context[key] = value
	end
	if not registry.enabled(record, command_context) then
		vim.notify("Command not available: /" .. parsed.command, vim.log.levels.WARN)
		return false
	end
	return registry.run(record.id, command_context)
end

function M.get_commands()
	return registry.list_slash()
end

function M.is_slash_command(text)
	return M.parse(text) ~= nil
end

local function last_undo_message(messages, record)
	local boundary = type(record and record.revert) == "table" and record.revert.messageID or nil
	local last_user_msg
	-- A staged revert keeps its tail for /redo; only earlier turns can be undone.
	for _, message in ipairs(messages) do
		if boundary and message.id == boundary then break end
		if message.role == "user" then last_user_msg = message end
	end
	return last_user_msg
end

function M.register_defaults()
	-- Palette definitions provide the shared slash and palette commands.
	require("opencode.ui.palette").register_defaults()
	local actions = require("opencode.actions")
	local state = require("opencode.state")

	registry.register({
		id = "session.stats",
		title = "Usage Statistics",
		description = "Usage statistics",
		category = "session",
		palette = false,
		slash = { name = "stats" },
		run = function(_context)
			actions.get_usage_stats(function(err, data)
				if err then
					vim.notify("Could not load usage statistics: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end
				local view, stats_error = require("opencode.stats").from_api(data)
				if not view then
					vim.notify("Could not show usage statistics: " .. stats_error, vim.log.levels.ERROR)
					return
				end
				require("opencode.ui.stats").show(view)
			end)
		end,
	})
	registry.register({
		id = "slash.help",
		title = "Slash Command Help",
		description = "Show available commands",
		category = "system",
		palette = false,
		slash = { name = "help" },
		run = function(_context)
			local lines = { "Available Commands:", "" }
			local current_category = nil
			
			for _, cmd in ipairs(M.get_commands()) do
				if cmd.category ~= current_category then
					current_category = cmd.category
					table.insert(lines, "")
					table.insert(lines, current_category:upper() .. ":")
				end
				
				local aliases = ""
				if cmd.aliases and #cmd.aliases > 0 then
					aliases = " (" .. table.concat(cmd.aliases, ", ") .. ")"
				end
				
				table.insert(lines, string.format("  /%-15s %s%s", cmd.name, cmd.description, aliases))
			end
			
			local float = require("opencode.ui.float")
			local popup, bufnr = float.create_centered_popup({
				width = 60,
				height = math.min(#lines + 2, 25),
				title = " Slash Commands ",
			})
			
			popup:mount()
			popup:render(lines)
			
			float.setup_close_keymaps(bufnr, function()
				popup:close()
			end)
		end,
	})
	
	registry.register({
		id = "session.undo",
		title = "Undo Last Message",
		description = "Undo last message and changes",
		category = "session",
		palette = false,
		slash = { name = "undo" },
		run = function(_context)
			local session_id = state.get_session().id
			if not session_id then
				vim.notify("No active session", vim.log.levels.WARN)
				return
			end
			
			local sync = require("opencode.sync")
			local messages = sync.get_messages(session_id)
			
			if #messages == 0 then
				vim.notify("No messages to undo", vim.log.levels.INFO)
				return
			end
			
			local last_user_msg = last_undo_message(messages, state.get_session_record(session_id))
			
			if not last_user_msg then
				vim.notify("No user message to undo", vim.log.levels.WARN)
				return
			end
			
			local draft = require("opencode.protocol.messages").draft(last_user_msg)
			local function finished(err, staged)
				vim.schedule(function()
					if err then
						vim.notify("Failed to undo: " .. tostring(err.message or err), vim.log.levels.ERROR)
						return
					end
					if state.get_session().id == session_id then
						require("opencode.ui.input").set_pending_draft(draft.text, draft.parts)
					end
					vim.notify(staged and "Undo staged. Use /redo to restore the turn."
						or "Pending input cancelled and restored to the composer.", vim.log.levels.INFO)
				end)
			end
			local pending_record = require("opencode.session.pending").get(session_id, last_user_msg.id)
			if pending_record and pending_record.status == "submitting" then
				actions.cancel_submitting_input(session_id, last_user_msg.id, function(err)
					if type(err) == "table" and err.code == "already_delivered" then
						actions.undo_message(session_id, last_user_msg.id, function(stage_err) finished(stage_err, true) end)
					else finished(err, false) end
				end)
			elseif require("opencode.selectors").pending_input(session_id, last_user_msg.id) then
				actions.cancel_pending_input(session_id, last_user_msg.id, function(err) finished(err, false) end)
			elseif last_user_msg.provisional and pending_record then
				actions.cancel_submitting_input(session_id, last_user_msg.id, function(err) finished(err, false) end)
			else
				actions.undo_message(session_id, last_user_msg.id, function(err) finished(err, true) end)
			end
		end,
		enabled = function()
			local sync = require("opencode.sync")
			local session_id = state.get_session().id
			if not session_id then return false end
			return last_undo_message(sync.get_messages(session_id), state.get_session_record(session_id)) ~= nil
		end,
	})
	
	registry.register({ id = "session.redo", title = "Redo Staged Undo", description = "Clear staged undo and restore the turn", category = "session",
		palette = false, slash = { name = "redo" },
		run = function(_context)
			local sid = state.get_session().id
			if not sid then return end
			actions.clear_revert(sid, function(err)
				vim.notify(err and ("Could not restore turn: " .. err.message) or "Staged undo cleared", err and vim.log.levels.ERROR or vim.log.levels.INFO)
			end)
		end,
		enabled = function()
			local sid = state.get_session().id
			local record = sid and state.get_session_record(sid)
			return type(record and record.revert) == "table" and type(record.revert.messageID) == "string"
		end })
end

return M
