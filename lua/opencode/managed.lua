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

return M
