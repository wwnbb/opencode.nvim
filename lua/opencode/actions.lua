-- opencode.nvim - Internal action boundary.
-- UI modules and command declarations call this module instead of reaching
-- directly through the public API or lower-level client/session modules.

local M = {}

local function api()
	return require("opencode")
end

local function lifecycle()
	return require("opencode.lifecycle")
end

local function client()
	return require("opencode.client")
end

local function sync()
	return require("opencode.sync")
end

local function sessions()
	return require("opencode.session")
end

local function local_state()
	return require("opencode.local")
end

local function schedule_callback(callback, ...)
	if type(callback) ~= "function" then
		return
	end
	local args = { ... }
	vim.schedule(function()
		local unpack_fn = table.unpack or unpack
		callback(unpack_fn(args))
	end)
end

local function update_input_info_bar()
	local ok, input = pcall(require, "opencode.ui.input")
	if ok and input.is_visible and input.is_visible() and type(input.update_info_bar) == "function" then
		input.update_info_bar()
	end
end

local function with_connection(callback)
	return lifecycle().ensure_connected(callback)
end

function M.open()
	return api().open()
end

function M.toggle()
	return api().toggle()
end

function M.close()
	return api().close()
end

function M.focus()
	return api().focus()
end

function M.focus_input()
	return api().focus_input()
end

function M.open_input_at_end(opts)
	return api().open_input_at_end(opts)
end

function M.start()
	return api().start()
end

function M.stop()
	return api().stop()
end

function M.restart()
	return api().restart()
end

function M.disconnect()
	return api().disconnect()
end

function M.reconnect(callback)
	return with_connection(function()
		schedule_callback(callback)
	end)
end

function M.abort()
	return api().abort()
end

function M.set_danger_mode(enabled, opts)
	return api().set_danger_mode(enabled, opts)
end

function M.enable_danger_mode(opts)
	return api().enable_danger_mode(opts)
end

function M.disable_danger_mode(opts)
	return api().disable_danger_mode(opts)
end

function M.toggle_danger_mode(opts)
	return api().toggle_danger_mode(opts)
end

function M.is_danger_mode_enabled()
	return api().is_danger_mode_enabled()
end

function M.clear(opts)
	return api().clear(opts)
end

function M.new_session(opts)
	return api().new_session(opts)
end

function M.close_session(opts)
	return api().close_session(opts)
end

function M.switch_session(session, opts)
	return sessions().switch_to(session, opts)
end

function M.set_active_session(session_id, name, opts)
	return sessions().set_active(session_id, name, opts)
end

function M.forget_session(session_id, opts)
	return sessions().forget(session_id, opts)
end

function M.refresh_session_activity(callback)
	local session_actions = sessions()
	return session_actions.refresh_status(function()
		session_actions.recount_pending()
		schedule_callback(callback)
	end)
end

function M.list_sessions(opts, callback)
	return with_connection(function()
		client().list_sessions(opts, function(err, result)
			schedule_callback(callback, err, result)
		end)
	end)
end

function M.fork_session(session_id, opts, callback)
	return with_connection(function()
		client().fork_session(session_id, opts or {}, function(err, result)
			schedule_callback(callback, err, result)
		end)
	end)
end

function M.delete_session(session_id, callback)
	return with_connection(function()
		client().delete_session(session_id, function(err, result)
			schedule_callback(callback, err, result)
		end)
	end)
end

function M.clear_session_data(session_id)
	if not session_id then
		return
	end
	sync().clear_session(session_id)
	local ok, chat = pcall(require, "opencode.ui.chat")
	if ok and type(chat.clear_session_view) == "function" then
		chat.clear_session_view(session_id)
	end
end

function M.load_session_messages(session_id, opts, callback)
	return with_connection(function()
		client().get_messages(session_id, opts or {}, function(err, response)
			if not err and response and type(response) == "table" then
				local store = sync()
				if type(store.handle_session_messages) == "function" then
					store.handle_session_messages(session_id, response)
				else
					for _, msg_with_parts in ipairs(response) do
						local info = msg_with_parts.info
						if info then
							info.sessionID = session_id
							store.handle_message_updated(info)
						end
						for _, part in ipairs(msg_with_parts.parts or {}) do
							store.handle_part_updated(part)
						end
					end
				end
			end
			schedule_callback(callback, err, response)
		end)
	end)
end

function M.get_session_children(session_id, callback)
	return with_connection(function()
		client().get_session_children(session_id, function(err, children)
			schedule_callback(callback, err, children)
		end)
	end)
end

function M.send(message, opts)
	return api().send(message, opts)
end

function M.list_agents(callback)
	return with_connection(function()
		client().list_agents(function(err, agents)
			if not err and agents then
				sync().handle_agents(agents)
			end
			schedule_callback(callback, err, agents)
		end)
	end)
end

function M.select_agent(agent_name)
	local_state().agent.set(agent_name)
	update_input_info_bar()
end

function M.get_config_providers(callback)
	return with_connection(function()
		client().get_config_providers(function(err, response)
			if not err and response then
				local store = sync()
				store.handle_providers(response.providers or {})
				if response.default then
					store.handle_provider_defaults(response.default)
				end
			end
			schedule_callback(callback, err, response)
		end)
	end)
end

function M.list_skills(callback)
	return client().list_skills(function(err, skills)
		if not err then
			sync().handle_skills(type(skills) == "table" and skills or {})
		end
		schedule_callback(callback, err, skills)
	end)
end

function M.execute_command(session_id, command, args, opts, callback)
	return client().execute_command(session_id, command, args, opts or {}, function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.list_providers(callback)
	return with_connection(function()
		client().list_providers(function(err, response)
			schedule_callback(callback, err, response)
		end)
	end)
end

function M.get_provider_auth(callback)
	return client().get_provider_auth(function(err, auth_methods)
		schedule_callback(callback, err, auth_methods)
	end)
end

function M.set_provider_auth(provider_id, auth, callback)
	return client().set_provider_auth(provider_id, auth, function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.remove_provider_auth(provider_id, callback)
	return client().remove_provider_auth(provider_id, function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.oauth_authorize(provider_id, method_index, callback)
	return client().oauth_authorize(provider_id, method_index, function(err, authorization)
		schedule_callback(callback, err, authorization)
	end)
end

function M.oauth_callback(provider_id, method_index, code, callback)
	return client().oauth_callback(provider_id, method_index, code, function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.dispose_server(callback)
	return client().dispose(function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.select_model(model, opts)
	local_state().model.set(model, opts or {})
	update_input_info_bar()
end

function M.toggle_model_favorite(model)
	return local_state().model.toggle_favorite(model)
end

function M.model_favorites()
	return local_state().model.favorite()
end

function M.remove_provider_models(provider_id)
	return local_state().model.remove_provider_models(provider_id)
end

function M.compact_session(session_id, opts, callback)
	return with_connection(function()
		local c = client()
		c.summarize_session(session_id, opts or {}, function(err, result)
			if err and type(err) == "table" and err.status == 404 then
				c.execute_command(session_id, "compact", {}, {}, function(fallback_err, fallback_result)
					schedule_callback(callback, fallback_err, fallback_result)
				end)
				return
			end
			schedule_callback(callback, err, result)
		end)
	end)
end

function M.get_server_status(callback)
	return client().get_status(function(err, status)
		schedule_callback(callback, err, status)
	end)
end

function M.get_mcp_status(callback)
	return client().get_mcp_status(function(err, status)
		if not err and status then
			sync().handle_mcp(status)
		end
		schedule_callback(callback, err, status)
	end)
end

function M.toggle_mcp(name, connected, callback)
	local c = client()
	local fn = connected and c.disconnect_mcp or c.connect_mcp
	return fn(name, function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.respond_permission(permission_id, reply, opts, callback)
	return client().respond_permission(permission_id, reply, opts or {}, function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.reply_to_question(session_id, request_id, answers, callback)
	return client().reply_to_question(session_id, request_id, answers, function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.reject_question(session_id, request_id, callback)
	return client().reject_question(session_id, request_id, function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.get_diff(session_id, opts, callback)
	return client().get_diff(session_id, opts or {}, function(err, diff)
		schedule_callback(callback, err, diff)
	end)
end

function M.revert_message(session_id, message_id, opts, callback)
	return client().revert_message(session_id, message_id, opts or {}, function(err, result)
		schedule_callback(callback, err, result)
	end)
end

function M.paste_clipboard()
	return api().paste_clipboard()
end

function M.command_palette()
	return api().command_palette()
end

function M.active_sessions()
	return api().active_sessions()
end

function M.toggle_logs()
	return require("opencode.ui.log_viewer").toggle()
end

function M.open_logs()
	return require("opencode.ui.log_viewer").open()
end

function M.close_logs()
	return require("opencode.ui.log_viewer").close()
end

function M.add_current_line_to_input(opts)
	return api().add_current_line_to_input(opts)
end

function M.add_current_line(opts)
	return api().add_current_line(opts)
end

function M.add_current_line_and_open_input(opts)
	return api().add_current_line_and_open_input(opts)
end

function M.add_visual_selection_to_input(opts)
	return api().add_visual_selection_to_input(opts)
end

function M.add_visual_selection(opts)
	return api().add_visual_selection(opts)
end

function M.add_visual_selection_and_open_input(opts)
	return api().add_visual_selection_and_open_input(opts)
end

function M.trigger_palette(id)
	return require("opencode.ui.palette").trigger(id)
end

return M
