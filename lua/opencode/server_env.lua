-- Server process environment and command resolution. No lifecycle state:
-- callers pass the server options (env, config_dir, use_shell_env, command).
local M = {}

local shell_env_cache = nil
local SHELL_ENV_TIMEOUT = 10000

-- NUL-separated output (env -0) keeps multi-line values intact; without NULs
-- fall back to one assignment per line.
function M.parse_env_output(output)
	local env = {}
	if type(output) ~= "string" or output == "" then
		return env
	end

	if output:find("\0", 1, true) then
		local first = true
		for record in output:gmatch("([^%z]*)%z") do
			local key, value = record:match("^([%w_]+)=(.*)$")
			-- Interactive shell startup may print before the first record.
			if not key and first then key, value = record:match("^.-\n([%w_]+)=(.*)$") end
			if key then env[key] = value end
			first = false
		end
		return env
	end

	for line in output:gmatch("[^\r\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")
		if key then
			env[key] = value
		end
	end

	return env
end

-- Login-shell environment, read once until reset_shell_env().
function M.load_shell_env(opts)
	if opts.use_shell_env == false then
		return {}
	end
	if shell_env_cache then
		return shell_env_cache
	end

	local shell = os.getenv("SHELL") or vim.o.shell or "/bin/sh"
	local shell_name = vim.fn.fnamemodify(shell, ":t")
	local flag = (shell_name == "bash" or shell_name == "zsh") and "-lic" or "-lc"
	local timeout = SHELL_ENV_TIMEOUT
	-- A slow or interactive rc file must not freeze the editor; :wait() kills
	-- the shell at the deadline and reports exit code 124.
	local ok, result = pcall(function()
		return vim.system({ shell, flag, "env -0 || env" }, { stdin = false }):wait(timeout)
	end)
	if not ok or not result or result.code ~= 0 then
		local reason = not ok and tostring(result)
			or (result and result.code == 124 and ("timed out after " .. timeout .. "ms"))
			or ("exit code " .. tostring(result and result.code))
		pcall(function() require("opencode.logger").warn("Login shell environment unavailable: " .. reason, { shell = shell }) end)
		shell_env_cache = {}
		return shell_env_cache
	end

	shell_env_cache = M.parse_env_output(result.stdout)
	return shell_env_cache
end

function M.reset_shell_env()
	shell_env_cache = nil
end

function M.prepend_path(path, dir)
	if type(dir) ~= "string" or dir == "" then
		return path or ""
	end

	local parts = {}
	local seen = {}
	local function add(part)
		if part and part ~= "" and not seen[part] then
			seen[part] = true
			table.insert(parts, part)
		end
	end

	add(dir)
	for part in tostring(path or ""):gmatch("[^:]+") do
		add(part)
	end

	return table.concat(parts, ":")
end

local function env_value(env, key)
	local value = env[key]
	if value == nil or value == vim.NIL then
		return nil
	end
	return tostring(value)
end

function M.promote_toolchain_bins(env)
	local path = env_value(env, "PATH") or os.getenv("PATH") or ""
	local volta_home = env_value(env, "VOLTA_HOME")
	local bun_install = env_value(env, "BUN_INSTALL")
	local nvm_bin = env_value(env, "NVM_BIN")

	if volta_home and volta_home ~= "" then
		path = M.prepend_path(path, volta_home .. "/bin")
	end
	if bun_install and bun_install ~= "" then
		path = M.prepend_path(path, bun_install .. "/bin")
	end
	if nvm_bin and nvm_bin ~= "" then
		path = M.prepend_path(path, nvm_bin)
	end

	env.PATH = path
end

---@param opts table Server options: env, config_dir, use_shell_env
---@param auth? table { username, password }
function M.build(opts, auth)
	local env = vim.tbl_extend(
		"force",
		vim.fn.environ(),
		M.load_shell_env(opts),
		type(opts.env) == "table" and opts.env or {},
		{
			OPENCODE_SERVER_USERNAME = auth and auth.username,
			OPENCODE_SERVER_PASSWORD = auth and auth.password,
			OPENCODE_CONFIG_DIR = opts.config_dir,
		}
	)

	for key, value in pairs(env) do
		if value == vim.NIL then
			env[key] = nil
		end
	end

	M.promote_toolchain_bins(env)

	for key, value in pairs(env) do
		env[key] = tostring(value)
	end

	return env
end

function M.resolve_command(command, env)
	command = command or "opencode"
	if command:find("/", 1, true) then
		return command
	end

	local path = env and env.PATH or os.getenv("PATH") or ""
	for dir in path:gmatch("[^:]+") do
		local candidate = dir .. "/" .. command
		if vim.fn.executable(candidate) == 1 then
			return candidate
		end
	end

	local exepath = vim.fn.exepath(command)
	if exepath and exepath ~= "" then
		return exepath
	end

	return command
end

-- Verified with CLI 2.0.11: "server listening on http://127.0.0.1:57168"
function M.parse_server_url(line)
	if not line then
		return nil
	end

	local url = line:match("listening on (http://[^%s]+)")
	if url then
		local host, port = url:match("^http://%[([^%]]+)%]:(%d+)$")
		if not host then
			host, port = url:match("^http://([^:/]+):(%d+)$")
		end
		-- CLI 2.0.11 on macOS prints its IPv6 localhost address without URL
		-- brackets (http://::1:PORT). Parse only this CLI output convention;
		-- keep the internal URL valid for subsequent consumers.
		if not host then
			local ipv6, native_port = url:match("^http://([%x:]+):(%d+)$")
			if ipv6 and ipv6:find(":", 1, true) then
				host, port = ipv6, native_port
				url = "http://[" .. host .. "]:" .. port
			end
		end
		if host and port then
			return {
				url = url,
				host = host,
				port = tonumber(port),
			}
		end
	end

	return nil
end

return M
