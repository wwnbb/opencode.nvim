local M = {}

local function call(module_name, fn_name, ...)
	local ok, mod = pcall(require, module_name)
	if not ok or type(mod[fn_name]) ~= "function" then
		return nil
	end
	return mod[fn_name](...)
end

---@param opts? { reset_state?: boolean, clear_chat?: boolean }
function M.clear_transient(opts)
	opts = opts or {}

	call("opencode.sync", "clear_all")
	call("opencode.permission.state", "clear_all")
	call("opencode.question.state", "clear_all")
	call("opencode.edit.state", "clear_all")
	call("opencode.permission.danger", "clear")

	if opts.clear_chat ~= false then
		call("opencode.ui.chat", "clear")
	end

	if opts.reset_state == true then
		call("opencode.state", "reset")
	end
end

function M.reset_all()
	M.clear_transient({
		reset_state = true,
		clear_chat = true,
	})
end

return M
