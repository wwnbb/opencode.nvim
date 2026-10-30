-- An owned server must end with its editor, including when Neovim is killed or
-- crashes and no autocommand runs. A detached shell reads a pipe whose write end
-- only this editor holds; end of file means the editor is gone, so the shell
-- sends SIGTERM to the server. Stopping the watchdog never signals the server.
local M = {}

local uv = vim.uv or vim.loop

M.shell = "/bin/sh"

-- Ignore hangups and interrupts aimed at the editor's terminal: the watchdog
-- must outlive the editor long enough to observe end of file.
local SCRIPT = [[
trap '' HUP INT
while read -r _; do :; done
kill -TERM "$1" 2>/dev/null
]]

local function close(handle)
	if handle and not handle:is_closing() then handle:close() end
end

---Watch the editor on behalf of a server process.
---@param pid integer
---@return { pid: integer, stop: fun() }|nil watchdog nil where no POSIX shell is available
function M.start(pid)
	if not uv or type(pid) ~= "number" or pid < 1 or pid % 1 ~= 0 then return nil end
	if vim.fn.has("win32") == 1 or vim.fn.executable(M.shell) ~= 1 then return nil end

	local stdin = uv.new_pipe(false)
	if not stdin then return nil end
	local handle, watchdog_pid
	handle, watchdog_pid = uv.spawn(M.shell, {
		args = { "-c", SCRIPT, "opencode-nvim-watchdog", tostring(pid) },
		stdio = { stdin, nil, nil },
		detached = true,
	}, function()
		close(handle)
	end)
	if not handle then
		close(stdin)
		return nil
	end
	-- Neither handle may keep the editor's event loop alive.
	handle:unref()
	stdin:unref()

	local stopped = false
	return {
		pid = watchdog_pid,
		stop = function()
			if stopped then return end
			stopped = true
			-- SIGKILL first: closing stdin would make the shell signal the server.
			if not handle:is_closing() then pcall(handle.kill, handle, 9) end
			close(stdin)
		end,
	}
end

return M
