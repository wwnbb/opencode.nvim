-- Adapt native OpenCode session statistics for the /stats view.
local M = {}

local function iana_zone(value)
	if type(value) ~= "string" then return nil end
	value = value:gsub("^:", ""):gsub("%s+$", "")
	if value == "UTC" or value:match("^[%w_%-+]+/[%w_/%-+]+$") then return value end
	return nil
end

local function local_timezone()
	local configured = iana_zone(vim.env.TZ)
	if configured then return configured end
	local uv = vim.uv or vim.loop
	local path = uv and uv.fs_readlink and uv.fs_readlink("/etc/localtime")
	local zone = type(path) == "string" and path:match("/zoneinfo/(.+)$") or nil
	if zone then
		zone = zone:gsub("^posix/", ""):gsub("^right/", "")
		local valid = iana_zone(zone)
		if valid then return valid end
	end
	local ok, lines = pcall(vim.fn.readfile, "/etc/timezone")
	if ok and type(lines) == "table" then return iana_zone(lines[1]) end
	return nil
end

local function utc_year_start(year)
	local local_start = os.time({ year = year, month = 1, day = 1, hour = 0, min = 0, sec = 0 })
	local utc_fields = os.date("!*t", local_start)
	utc_fields.isdst = nil
	return local_start + (local_start - os.time(utc_fields))
end

-- Match the TUI's current-year scope and avoid fetching unused tool breakdowns.
function M.query(now)
	now = now or os.time()
	local year = os.date("*t", now).year
	local zone = local_timezone()
	local from = zone and os.time({ year = year, month = 1, day = 1, hour = 0, min = 0, sec = 0 })
		or utc_year_start(year)
	local query = {
		from = from * 1000,
		tools = "none",
		timezone = zone or "UTC",
	}
	return query
end

local function nonnegative(value)
	local number = tonumber(value)
	if not number or number ~= number then return 0 end
	return math.max(0, number)
end

local function date_from_ms(value)
	local ms = tonumber(value)
	if not ms then return nil end
	local format = local_timezone() and "%Y-%m-%d" or "!%Y-%m-%d"
	local ok, date = pcall(os.date, format, math.floor(ms / 1000))
	return ok and date or nil
end

---@param data table Native SessionStats.Info response.
---@return table|nil view
---@return string|nil error
function M.from_api(data)
	if type(data) ~= "table" or type(data.tokens) ~= "table" or type(data.activity) ~= "table"
		or type(data.range) ~= "table" then
		return nil, "Invalid usage statistics response"
	end

	local tokens = data.tokens
	local cache = type(tokens.cache) == "table" and tokens.cache or {}
	local total = tokens.total and nonnegative(tokens.total) or (
		nonnegative(tokens.input) + nonnegative(tokens.output) + nonnegative(tokens.reasoning)
		+ nonnegative(cache.read) + nonnegative(cache.write)
	)
	local daily = {}
	for _, activity in ipairs(data.activity) do
		if type(activity) == "table" and type(activity.date) == "string"
			and activity.date:match("^%d%d%d%d%-%d%d%-%d%d$") then
			daily[activity.date] = (daily[activity.date] or 0) + nonnegative(activity.steps)
		end
	end

	return {
		total_tokens = total,
		sessions = nonnegative(data.sessions),
		active_days = nonnegative(data.activeDays),
		best_streak = nonnegative(data.streak),
		daily = daily,
		start_date = date_from_ms(data.range.from),
		end_date = date_from_ms(data.range.to),
	}
end

return M
