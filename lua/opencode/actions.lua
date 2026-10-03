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

local function provider_state()
	return require("opencode.provider.state")
end

local function state()
	return require("opencode.state")
end

local function cleanup()
	return require("opencode.cleanup")
end

---@param event_type string
---@param data table
local function emit(event_type, data)
	local ok, events = pcall(require, "opencode.events")
	if ok and events and type(events.emit) == "function" then
		events.emit(event_type, data)
	end
end

local schedule_callback = require("opencode.util.schedule").schedule_callback

local function current_callback(token, callback)
	local pending = require("opencode.session.pending")
	return function(...)
		schedule_callback(type(callback) == "function" and function(...)
			if pending.is_current(token) then callback(...) end
		end, ...)
	end
end

local function update_input_info_bar()
	local ok, input = pcall(require, "opencode.ui.input")
	if ok and input.is_visible and input.is_visible() and type(input.update_info_bar) == "function" then
		input.update_info_bar()
	end
end

local function with_connection(callback, session_id)
	local pending = require("opencode.session.pending")
	local token = pending.token(session_id)
	return lifecycle().ensure_connected(function()
		if pending.is_current(token) then callback(token) end
	end)
end

local function connected_request(session_id, request, callback)
	return with_connection(function(token)
		request(current_callback(token, callback))
	end, session_id)
end

local function catalog_options(opts)
	local app = state()
	local options = vim.tbl_extend("keep", opts or {}, { directory = app.get_session_directory(app.get_session().id) or vim.fn.getcwd() })
	options.directory = require("opencode.util.path").absolute(options.directory)
	return options
end

local function load_catalog(method, domain, callback)
	local opts = catalog_options()
	return connected_request(nil, function(done) client()[method](done, opts) end, function(err, data)
		if data or err then sync().handle_location_catalog(opts.directory, domain, data, err) end
		if callback and catalog_options().directory == opts.directory then callback(err, data) end
	end)
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
	return connected_request(nil, function(done) done() end, callback)
end

function M.abort()
	return api().abort()
end

function M.ask_btw(question, session_id)
	return api().ask_btw(question, session_id)
end

function M.complete()
	return api().complete()
end

function M.accept_completion()
	return api().accept_completion()
end

function M.dismiss_completion()
	return api().dismiss_completion()
end

function M.completion_visible()
	return api().completion_visible()
end

function M.explain_selection()
	return api().explain_selection()
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

function M.remember_session(session, opts)
	local options = vim.tbl_extend("force", { touch = false, reason = "session_fork" }, opts or {})
	return sessions().remember(session, options)
end

function M.forget_session(session_id, opts)
	return sessions().forget(session_id, opts)
end

function M.refresh_session_activity(callback)
	local session_actions = sessions()
	return session_actions.refresh_status(current_callback(require("opencode.session.pending").token(), function()
		session_actions.recount_pending()
		if callback then callback() end
	end))
end

function M.list_sessions(opts, callback)
	return connected_request(nil, function(done) client().get_all_sessions(opts, done) end, callback)
end

function M.get_usage_stats(callback)
	return connected_request(nil, function(done) client().get_usage_stats(require("opencode.stats").query(), done) end, callback)
end

function M.fork_session(session_id, opts, callback)
	return connected_request(session_id, function(done) client().fork_session(session_id, opts or {}, done) end, callback)
end

function M.export_session(session_id, opts, callback)
	return connected_request(session_id, function(done) client().export_session(session_id, opts or {}, done) end, callback)
end

function M.delete_session(session_id, callback)
	return connected_request(session_id, function(done) client().delete_session(session_id, done) end, function(err, result)
		if not err then sessions().handle_deleted(session_id, { reason = "session_delete" }) end
		if callback then callback(err, result) end
	end)
end

function M.clear_session_data(session_id)
	if not session_id then
		return
	end
	local store = sync()
	if type(store.clear_session_tree) == "function" then
		store.clear_session_tree(session_id)
	else
		store.clear_session(session_id)
	end
	local ok, chat = pcall(require, "opencode.ui.chat")
	if ok and type(chat.clear_session_view) == "function" then
		chat.clear_session_view(session_id)
	end
end

function M.load_session_messages(session_id, opts, callback)
	if type(opts) == "function" then callback, opts = opts, nil end
	local request_opts = vim.tbl_extend("force", { limit = 100 }, opts or {})
	local complete = request_opts.all == true
	request_opts.all = nil
	local pending = require("opencode.session.pending")
	local token = pending.token(session_id)
	local publish = current_callback(token, callback)
	return with_connection(function()
		if not pending.is_current(token) then return end
		local store = sync()
		local snapshot = store.capture_session_snapshot(session_id)
		local function done(err, response, meta)
			if not pending.is_current(token) then return end
			if not err then
				pending.reconcile_history(session_id, response)
				store.handle_session_messages(session_id, response, { reconcile = complete, complete = complete, snapshot = snapshot })
				require("opencode.session").set_message_cache(session_id, store.get_messages(session_id), { reason = "load_messages" })
				require("opencode.session").refresh_status()
				require("opencode.events").emit("sync_changed", { kind = "message", session_id = session_id })
			end
			publish(err, response, meta)
		end
		if complete then client().get_all_messages(session_id, done) else client().get_messages(session_id, request_opts, done) end
	end)
end

function M.get_session_children(session_id, callback)
	return connected_request(session_id, function(done) client().get_session_children(session_id, done) end, callback)
end

function M.get_session(session_id, callback)
	return connected_request(session_id, function(done) client().get_session(session_id, done) end, callback)
end

---@param parent_session_id string
---@param message_id string
---@param part_id string
---@param child_session_id string
---@return boolean changed
function M.record_task_child_session(parent_session_id, message_id, part_id, child_session_id)
	local store = sync()
	if type(store.record_task_child_session) ~= "function" then
		return false
	end
	local changed = store.record_task_child_session(parent_session_id, message_id, part_id, child_session_id)
	if changed then
		emit("sync_changed", {
			kind = "part",
			action = "updated",
			session_id = parent_session_id,
			message_id = message_id,
			part_id = part_id,
		})
	end
	return changed
end

function M.send(message, opts)
	return api().send(message, opts)
end

function M.list_pending_inputs(session_id, callback)
	return connected_request(session_id, function(done) client().get_inbox(session_id, done) end, callback)
end

function M.cancel_pending_input(session_id, message_id, callback)
	return with_connection(function()
		require("opencode.send").cancel_input(session_id, message_id, callback)
	end, session_id)
end

function M.cancel_submitting_input(session_id, message_id, callback)
	return with_connection(function()
		require("opencode.send").cancel_submitting_input(session_id, message_id, callback)
	end, session_id)
end

function M.edit_pending_input(session_id, message_id, callback)
	return with_connection(function()
		require("opencode.send").edit_input(session_id, message_id, callback)
	end, session_id)
end

function M.steer_pending_input(session_id, message_id, callback)
	return with_connection(function()
		require("opencode.send").steer_input(session_id, message_id, callback)
	end, session_id)
end

function M.queue_pending_input(session_id, message_id, callback)
	return with_connection(function()
		require("opencode.send").queue_input(session_id, message_id, callback)
	end, session_id)
end

function M.list_agents(callback)
	return load_catalog("list_agents", "agents", callback)
end

function M.select_agent(agent_name)
	local_state().agent.set(agent_name)
	update_input_info_bar()
end

function M.get_config_providers(callback)
	return load_catalog("get_config_providers", "providers", callback)
end

function M.list_skills(callback, opts)
	opts = vim.deepcopy(catalog_options(opts))
	local token = require("opencode.session.pending").token()
	return client().list_skills(current_callback(token, function(err, skills)
		sync().handle_location_catalog(opts.directory, "skills", skills, err)
		if callback then callback(err, skills) end
	end), opts)
end

-- Add catalog skills to the current input draft. The server loads their
-- instructions when the user sends that draft as a native prompt attachment.
function M.stage_skills(selected, opts)
	if type(selected) ~= "table" then return false end
	opts = vim.deepcopy(opts or {})
	opts.session_id = opts.session_id or state().get_session().id
	if not opts.session_id then
		vim.notify("Select a session before adding skills", vim.log.levels.WARN)
		return false
	end
	opts.directory = opts.directory or state().get_session_directory(opts.session_id) or vim.fn.getcwd()
	local input = require("opencode.ui.input")
	local draft_token = input.draft_token()
	local token = require("opencode.session.pending").token(opts.session_id)
	local function add_resolved(err, skills)
		if not require("opencode.session.pending").is_current(token) then return end
		if state().get_session().id ~= opts.session_id then
			vim.notify("Skill selection belongs to another session", vim.log.levels.WARN)
			return
		end
		if input.draft_token() ~= draft_token then
			vim.notify("The draft changed before skills could be added; select them again", vim.log.levels.WARN)
			return
		end
		if err then
			vim.notify("Could not list skills: " .. tostring(err.message or err), vim.log.levels.ERROR)
			return
		end
		local parts, seen = {}, {}
		skills = type(skills) == "table" and skills or {}
		for _, wanted in ipairs(selected) do
			local found
			for _, skill in ipairs(skills) do
				if (type(wanted) == "table" and wanted.id == skill.id)
					or (type(wanted) == "string" and (wanted == skill.id or wanted == skill.name)) then found = skill; break end
			end
			if not found or type(found.id) ~= "string" or found.id == "" then
				vim.notify("Skill is unavailable: " .. tostring(type(wanted) == "table" and wanted.name or wanted), vim.log.levels.WARN)
				return
			end
			if not seen[found.id] then
				seen[found.id] = true
				parts[#parts + 1] = { type = "skill", id = found.id, name = found.name }
			end
		end
		if #parts == 0 then return end
		local added, stage_error = input.stage_skills(parts, opts.session_id)
		if not added then
			vim.notify("Could not add skills to draft: " .. tostring(stage_error), vim.log.levels.WARN)
			return
		end
		M.focus_input()
	end
	-- The picker already supplied catalog records. Re-fetching after selection
	-- creates a gap in which the user can send the prompt without its skills.
	local catalog_records = #selected > 0
	for _, wanted in ipairs(selected) do
		if type(wanted) ~= "table" or type(wanted.id) ~= "string" then catalog_records = false; break end
	end
	if catalog_records then
		add_resolved(nil, selected)
	else
		M.list_skills(add_resolved, opts)
	end
	return true
end

function M.execute_command(session_id, command, args, opts, callback)
	local token = require("opencode.session.pending").token(session_id)
	return require("opencode.send").command(session_id, command, args, opts or {}, current_callback(token, callback))
end

function M.list_providers(callback)
	return connected_request(nil, function(done) client().list_providers(done) end, callback)
end

function M.list_integrations(callback, opts)
	return connected_request(nil, function(done) client().list_integrations(done, opts) end, callback)
end

function M.connect_integration_key(integration_id, key, answer, opts, callback)
	return require("opencode.provider.auth").connect_key(integration_id, key, answer, opts, callback)
end
function M.start_integration_attempt(integration_id, method, answer, opts, listener)
	return require("opencode.provider.auth").start(integration_id, method, answer, opts, listener)
end
function M.complete_integration_attempt(id, code)
	return require("opencode.provider.auth").complete(id, code)
end
function M.cancel_integration_attempt(id)
	return require("opencode.provider.auth").cancel(id)
end
function M.change_credential(operation, integration_id, credential_id, body, opts, callback)
	return require("opencode.provider.auth").credential(operation, integration_id, credential_id, body, opts, callback)
end

-- Explicit server-wide reload; authentication never calls this operation.
function M.reload_locations(callback)
	local token = require("opencode.session.pending").token()
	return client().dispose(current_callback(token, function(err, result)
		if not err then
			cleanup().clear_transient({ reset_state = false, clear_chat = true })
			require("opencode.events").emit("connected", {})
		end
		if callback then callback(err, result) end
	end))
end
M.dispose_server = M.reload_locations

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

function M.forget_provider(provider_id)
	M.remove_provider_models(provider_id)
	provider_state().mark(provider_id)
end

function M.remember_provider(provider_id)
	provider_state().remember(provider_id)
end

function M.clear_pending_disconnects()
	provider_state().clear_all()
end

function M.compact_session(session_id, opts, callback)
	return connected_request(session_id, function(done) client().summarize_session(session_id, opts or {}, done) end, function(err, result)
		if not err then require("opencode.events").emit("v2_reconcile", { session_id = session_id }) end
		if callback then callback(err, result) end
	end)
end

function M.get_server_status(callback)
	local token = require("opencode.session.pending").token()
	return client().get_status(current_callback(token, callback), catalog_options())
end

function M.get_mcp_status(callback, opts)
	opts = catalog_options(opts)
	local token = require("opencode.session.pending").token()
	return client().get_mcp_status(current_callback(token, function(err, status)
		if not err and status then sync().handle_location_catalog(opts.directory, "mcp", status) end
		if callback then callback(err, status) end
	end), opts)
end

function M.toggle_mcp(name, connected, callback, opts)
	local c = client()
	local fn = connected and c.disconnect_mcp or c.connect_mcp
	local token = require("opencode.session.pending").token()
	return fn(name, current_callback(token, callback), catalog_options(opts))
end

function M.reply_review(review_id, callback)
	return require("opencode.review").reply(review_id, callback)
end

function M.respond_permission(permission_id, reply, opts, callback)
	opts = vim.tbl_extend("force", {}, opts or {})
	local owner = require("opencode.permission.state")
	local item = owner.get_permission(permission_id)
	local review = require("opencode.edit.state").get_edit(permission_id)
	if review and review.transport == "review_rpc" then
		if callback then callback({ message = "Use reply_review for file review decisions" }) end
		return false
	end
	opts.session_id = opts.session_id or (item and item.session_id)
	opts.directory = opts.directory or require("opencode.state").get_session_directory(opts.session_id)
	if not item or not owner.begin_submission(permission_id) then return false end
	local token = require("opencode.session.pending").token(opts.session_id)
	return client().respond_permission(permission_id, reply, opts, current_callback(token, function(err, result)
		local current = owner.get_permission(permission_id)
		if current ~= item or current.status ~= "pending" then return end
		if err then
			owner.restore_submission(permission_id, err)
			require("opencode.events").emit("interaction_reconcile", { session_id = opts.session_id })
		end
		if callback then callback(err, result) end
	end))
end

---@param request_id string
---@param answers table
---@param opts_or_callback? table|function
---@param callback? function
function M.reply_to_question(request_id, answers, opts_or_callback, callback)
	local opts = opts_or_callback
	if type(opts_or_callback) == "function" then
		callback = opts_or_callback
		opts = nil
	end
	opts = vim.tbl_extend("force", opts or {}, {})
	if type(opts.directory) ~= "string" or opts.directory == "" then
		local qstate = require("opencode.question.state").get_question(request_id)
		if qstate then
			opts.directory = require("opencode.state").get_session_directory(qstate.session_id)
		end
	end
	local qstate = require("opencode.question.state").get_question(request_id)
	opts.session_id = qstate and qstate.session_id or opts.session_id
	local token = require("opencode.session.pending").token(opts.session_id)
	return client().reply_to_question(request_id, answers, opts, current_callback(token, function(err, result)
		if err then require("opencode.events").emit("interaction_reconcile", { session_id = opts.session_id }) end
		if callback then callback(err, result) end
	end))
end

---@param session_id string|nil
---@param request_id string
---@param opts_or_callback? table|function
---@param callback? function
function M.reject_question(session_id, request_id, opts_or_callback, callback)
	local opts = opts_or_callback
	if type(opts_or_callback) == "function" then
		callback = opts_or_callback
		opts = nil
	end
	opts = vim.tbl_extend("force", {}, opts or {})
	local item = require("opencode.question.state").get_question(request_id)
	local owner_session_id = item and item.session_id or session_id
	opts.directory = opts.directory or require("opencode.state").get_session_directory(owner_session_id)
	local token = require("opencode.session.pending").token(owner_session_id)
	return client().reject_question(owner_session_id, request_id, opts, current_callback(token, function(err, result)
		if err then require("opencode.events").emit("interaction_reconcile", { session_id = owner_session_id }) end
		if callback then callback(err, result) end
	end))
end

function M.refresh_form(id)
	local item = require("opencode.question.state").get_question(id)
	if item then require("opencode.events").emit("interaction_reconcile", { session_id = item.session_id }) end
end

function M.get_diff(session_id, opts, callback)
	local token = require("opencode.session.pending").token(session_id)
	return client().get_diff(session_id, opts or {}, current_callback(token, callback))
end

local function reverted(session_id, callback, operation)
	local token = require("opencode.session.pending").token(session_id)
	return current_callback(token, function(err, result)
		if not err then
			if operation == "stage" and type(result) == "table" and result.messageID then
				sessions().remember({ id = session_id, revert = result }, { touch = false })
			elseif operation == "clear" or operation == "commit" then
				sessions().remember({ id = session_id, revert = vim.NIL }, { touch = false })
			end
			require("opencode.events").emit("v2_reconcile", { session_id = session_id, complete = true })
		end
		if callback then callback(err, result) end
	end)
end
function M.revert_message(session_id, message_id, opts, callback)
	return client().revert_message(session_id, message_id, opts or {}, reverted(session_id, callback, "stage"))
end
function M.clear_revert(session_id, callback)
	return client().clear_revert(session_id, reverted(session_id, callback, "clear"))
end
function M.commit_revert(session_id, callback)
	return client().commit_revert(session_id, reverted(session_id, callback, "commit"))
end

-- Revert staging requires an idle agent loop. Interrupting may return before
-- the loop has stopped, so wait for the server before staging the boundary.
function M.undo_message(session_id, message_id, callback)
	local pending = require("opencode.session.pending")
	local token = pending.token(session_id)
	local fail = current_callback(token, callback)
	client().abort_session(session_id, function(err)
		if not pending.is_current(token) then return end
		if err then fail(err); return end
		client().wait_session(session_id, function(wait_err)
			if not pending.is_current(token) then return end
			if wait_err then fail(wait_err); return end
			M.revert_message(session_id, message_id, {}, callback)
		end)
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
