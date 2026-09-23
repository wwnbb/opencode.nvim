local M = {}

local function call(module_name, fn_name, ...)
	local ok, mod = pcall(require, module_name)
	if not ok or type(mod[fn_name]) ~= "function" then
		return nil
	end
	return mod[fn_name](...)
end

---@param session_id string
function M.clear_session(session_id)
	call("opencode.permission.state", "clear_session", session_id)
	call("opencode.question.state", "clear_session", session_id)
	call("opencode.edit.state", "clear_session", session_id)
	call("opencode.session.lock", "clear", session_id)
	call("opencode.session.selection", "clear_session", session_id)
	call("opencode.session.pending", "clear_session", session_id)
	local ok, local_state = pcall(require, "opencode.local")
	if ok then local_state.message_agent.clear_session(session_id) end
end

---@param opts? { reset_state?: boolean, clear_chat?: boolean }
function M.clear_transient(opts)
	opts = opts or {}

	call("opencode.sync", "clear_all")
	call("opencode.events.handlers.v2", "clear")
	call("opencode.permission.state", "clear_all")
	call("opencode.question.state", "clear_all")
	call("opencode.edit.state", "clear_all")
	call("opencode.artifact.changes", "clear")
	call("opencode.state", "clear_all_pending_changes")
	call("opencode.session.lock", "clear_all")
	call("opencode.session.selection", "clear_all")
	call("opencode.session.pending", opts.reset_state and "clear_all" or "invalidate")
	call("opencode.permission.danger", "clear")
	call("opencode.provider.state", "clear_attempts")

	if opts.clear_chat ~= false then
		call("opencode.ui.chat", "clear")
	end

	if opts.reset_state == true then
		call("opencode.state", "reset")
	end

	call("opencode.events", "clear_history")
end

function M.reset_all()
	M.clear_transient({
		reset_state = true,
		clear_chat = true,
	})
end

return M
