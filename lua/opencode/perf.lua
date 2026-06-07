-- One-off performance probes for finding slow chat rendering paths.

local M = {}

local uv = vim.uv or vim.loop
local DEFAULT_THRESHOLD_MS = 16
local DEFAULT_LOG_NAME = "opencode.nvim-profile.log"

local function is_enabled()
	return vim.env.OPENCODE_NVIM_PROFILE ~= "0"
end

local function threshold_ms()
	local value = tonumber(vim.env.OPENCODE_NVIM_PROFILE_THRESHOLD_MS)
	if value == nil then
		return DEFAULT_THRESHOLD_MS
	end
	return math.max(0, value)
end

local function log_path()
	local configured = vim.env.OPENCODE_NVIM_PROFILE_LOG
	if configured and configured ~= "" then
		return configured
	end
	return vim.fn.stdpath("cache") .. "/" .. DEFAULT_LOG_NAME
end

local function encode_extra(extra)
	if type(extra) ~= "table" then
		return ""
	end
	local ok, encoded = pcall(vim.json.encode, extra)
	if ok and type(encoded) == "string" then
		return " " .. encoded
	end
	return " " .. vim.inspect(extra)
end

local function append_line(line)
	local path = log_path()
	vim.schedule(function()
		pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
		pcall(vim.fn.writefile, { line }, path, "a")
	end)
end

---@param name string
---@return fun(extra?: table): number elapsed_ms
function M.start(name)
	local started = uv.hrtime()
	local metric = tostring(name or "unknown")
	local closed = false

	return function(extra)
		if closed then
			return 0
		end
		closed = true

		local elapsed_ms = (uv.hrtime() - started) / 1000000
		if not is_enabled() or elapsed_ms < threshold_ms() then
			return elapsed_ms
		end

		append_line(
			string.format(
				"%s metric=%s elapsed_ms=%.3f%s",
				os.date("%Y-%m-%d %H:%M:%S"),
				metric,
				elapsed_ms,
				encode_extra(extra)
			)
		)
		return elapsed_ms
	end
end

return M
