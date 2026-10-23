-- opencode.nvim - Palette command context: capture, validity, and the freshness
-- guards that async palette callbacks check before touching their view or session.

local M = {}

local state = require("opencode.state")
local pending = require("opencode.session.pending")

---Freeze the invoking view, its generation, and its session.
---@param context table|nil
---@return table
function M.capture(context)
	local result = vim.tbl_extend("force", {}, context or {})
	local views = require("opencode.ui.chat.state")
	result.session_id = result.session_id or (result.view and views.session(result.view).id) or state.get_session().id
	if not result.view then
		local input = package.loaded["opencode.ui.input"]
		local view = input and input.owner_view and input.owner_view() or views.current()
		if view.visible and views.session(view).id == result.session_id then result.view = view end
	end
	if result.view and result.generation == nil then result.generation = result.view.generation end
	return result
end

---A captured view must keep its generation and session; without a view the focused session must match.
---@param context table
---@return boolean
function M.valid(context)
	if context.view then
		local views = require("opencode.ui.chat.state")
		return views.valid(context.view, context.generation) and views.session(context.view).id == context.session_id
	end
	return state.get_session().id == context.session_id
end

local function session_directory(session_id, cwd_fallback)
	local directory = state.get_session_directory(session_id)
	if cwd_fallback then return directory or require("opencode.util.cwd").get() end
	return directory
end

---@class opencode.PaletteGuardOptions
---@field session_token string|nil Session that scopes the pending token (nil: global generation only)
---@field token table|nil Existing pending token to check instead of creating one
---@field require_view boolean|"session_bound"|nil true: context must stay valid; "session_bound": only for a session-bound view
---@field require_selection boolean|nil Default for current(require_selection): require validity for any view
---@field global_session boolean|nil The focused session must still be context.session_id
---@field same_directory boolean|"cwd"|nil The session directory (or cwd fallback for "cwd") must not change
---@field check fun(): boolean|nil Module-specific extra condition

---Build the freshness check for callbacks started from a palette command.
---current(require_selection) overrides opts.require_selection for one check.
---@param context table|nil Captured context (nil only without view/session options)
---@param opts opencode.PaletteGuardOptions|nil
---@return fun(require_selection?: boolean): boolean current
---@return table token
---@return string|nil directory Directory captured for same_directory
function M.guard(context, opts)
	opts = opts or {}
	local token = opts.token or pending.token(opts.session_token)
	local session_id = context and context.session_id
	local cwd_fallback = opts.same_directory == "cwd"
	local directory = opts.same_directory and session_directory(session_id, cwd_fallback) or nil
	return function(require_selection)
		if not pending.is_current(token) then return false end
		if require_selection == nil then require_selection = opts.require_selection end
		if (opts.require_view == true or require_selection
			or (opts.require_view == "session_bound" and context.view and context.view.session_bound))
			and not M.valid(context) then return false end
		if opts.global_session and state.get_session().id ~= session_id then return false end
		if opts.same_directory and session_directory(session_id, cwd_fallback) ~= directory then return false end
		if opts.check and not opts.check() then return false end
		return true
	end, token, directory
end

---Close the menu instead of running a key handler once its guard is stale.
---@param keys table[] Menu key definitions; handlers are wrapped in place
---@param current fun(): boolean
---@return table[] keys
function M.guard_keys(keys, current)
	for _, shortcut in ipairs(keys) do
		local handler = shortcut.handler
		shortcut.handler = function(ctx, item)
			if not current() then ctx.close(); return end
			return handler(ctx, item)
		end
	end
	return keys
end

---Open a menu with the captured view's session focus and draft restored.
---@param context table
---@param initial_input any Value from session.focus.capture_input
---@param opts table Menu options
function M.show_menu(context, initial_input, opts)
	return require("opencode.session.focus").with_session_focus(context.view,
		function() return require("opencode.ui.menu").open(opts) end, initial_input)
end

return M
