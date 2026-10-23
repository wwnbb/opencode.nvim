-- Native daemon discovery is a registration file plus an authenticated health
-- check. Keep its private password out of status/UI and diagnostic messages.
local M = {}
local error = require("opencode.client.tcp_connection").make_error

function M.default_file(opts)
	local home = opts and opts.env and opts.env.XDG_STATE_HOME or vim.env.XDG_STATE_HOME
	if not home or home == "" then home = vim.fn.expand("~/.local/state") end
	return home .. "/opencode/service.json"
end

function M.read(opts)
	if opts.service_file and type(opts.service_file) ~= "string" then
		return nil, error("Invalid managed service registration path", { code = "invalid_endpoint", retryable = false })
	end
	local value = require("opencode.util.json_file").read(opts.service_file or M.default_file(opts))
	if type(value) ~= "table" or type(value.url) ~= "string" or type(value.pid) ~= "number"
		or value.pid < 1 or value.pid % 1 ~= 0 or value.pid > 9007199254740991
		or (value.version ~= nil and type(value.version) ~= "string")
		or (value.password ~= nil and type(value.password) ~= "string") then
		return nil, error("Managed OpenCode service registration is unavailable", { code = "service_unavailable", retryable = true })
	end
	local endpoint, err = require("opencode.client.endpoint").resolve({ url = value.url })
	if not endpoint then return nil, err end
	return value
end

function M.config(info, opts)
	return { url = info.url, auth = { username = "opencode", password = info.password }, tls = opts.tls or {} }
end

function M.validate(info, health)
	if type(health) ~= "table" or health.pid ~= info.pid or type(health.version) ~= "string"
		or (info.version and health.version ~= info.version) then
		return error("Managed service identity changed; rediscover the service", { code = "service_identity_changed", retryable = true })
	end
end

function M.same(left, right)
	return left ~= nil and right ~= nil and left.id == right.id and left.pid == right.pid and left.url == right.url
		and left.version == right.version and left.password == right.password
end

function M.local_host(info)
	local endpoint = require("opencode.client.endpoint").resolve({ url = info.url })
	return endpoint and (endpoint.host == "localhost" or endpoint.host == "127.0.0.1" or endpoint.host == "::1") or false
end

function M.can_manage(opts, info)
	-- Native CLI service commands use their own selected registration path. A
	-- custom lookup file can be read, but cannot identify that CLI's daemon.
	return opts.managed == true and info ~= nil and M.local_host(info)
		and (not opts.service_file or require("opencode.util.path").absolute(opts.service_file) == require("opencode.util.path").absolute(M.default_file(opts)))
end

---Run a native CLI command (service start/restart, upgrade) with the server environment.
---@param opts table Lifecycle server options
function M.native_cli(opts, args, callback)
	local server_env = require("opencode.server_env")
	local env = server_env.build(opts, nil)
	local command = server_env.resolve_command(opts.command, env)
	if not vim.system or vim.fn.executable(command) ~= 1 then
		vim.schedule(function() callback({ message = "Native OpenCode CLI is unavailable", code = "cli_unavailable", retryable = false }) end)
		return
	end
	local argv = { command }; vim.list_extend(argv, args)
	return vim.system(argv, { env = env, text = true, timeout = args[1] == "upgrade" and 120000 or math.max(10000, opts.startup_timeout) }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then callback({ message = "Native OpenCode command failed; installation or service management may be unsupported", code = "cli_failed" })
			else callback(nil) end
		end)
	end)
end

---Read, configure and verify the registered daemon for a lifecycle attempt,
---starting the native service once when allowed. Records attempt.registration
---and attempt.verified.
---@param attempt table Lifecycle attempt
---@param context { opts: fun(): table, current: fun(): boolean } Live options and staleness guard
---@param callback fun(err?: table, config?: table)
---@param allow_start boolean
function M.discover(attempt, context, callback, allow_start)
	local current = context.current
	local lookup
	local function start_then_lookup()
		return M.native_cli(context.opts(), { "service", "start" }, function(start_err)
			if not current() then return end
			if start_err then callback(start_err) else lookup(false) end
		end)
	end
	lookup = function(can_start)
		if not current() then return end
		local opts = context.opts()
		local info, err = M.read(opts)
		if not info then
			if can_start and opts.auto_start and (not opts.service_file or opts.service_file == M.default_file(opts)) then
				return start_then_lookup()
			end
			callback(err); return
		end
		local config = M.config(info, opts)
		require("opencode.client").configure_endpoint(config)
		require("opencode.state").set_server_info({ url = info.url, host = false, port = false })
		return require("opencode.client.http").health(function(health_err, health)
			if not current() then return end
			opts = context.opts()
			local failure = health_err or M.validate(info, health)
			if not failure and not M.same(info, M.read(opts)) then
				failure = { message = "Managed service registration changed during discovery", code = "service_identity_changed", retryable = true }
			end
			if failure then
				attempt.verified = false
				if can_start and opts.auto_start and M.can_manage(opts, info) and failure.retryable ~= false and failure.status ~= 401 then
					return start_then_lookup()
				end
				callback(failure); return
			end
			attempt.registration, attempt.verified = info, true
			callback(nil, config)
		end)
	end
	return lookup(allow_start)
end

---Service status for the palette: only a verified, unchanged local
---registration may be restarted or upgraded.
---@param attempt? table Current lifecycle attempt
---@param opts table Lifecycle server options
function M.status(attempt, opts)
	local info = attempt and attempt.registration
	local fresh = opts.managed and M.read(opts)
	local allowed = attempt and attempt.discovered and attempt.verified and M.same(info, fresh) and M.can_manage(opts, info) or false
	local endpoint = info and info.url or opts.url
	if endpoint and not require("opencode.client.endpoint").resolve({ url = endpoint }) then endpoint = "Invalid server URL" end
	return { discovered = attempt and attempt.discovered or false, can_manage = allowed,
		url = endpoint or false, pid = info and info.pid, version = info and info.version,
		service_file = opts.service_file or M.default_file(opts) }
end

return M
