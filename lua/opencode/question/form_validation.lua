-- Local validation for the native Form answer fields.
local M = {}

local unicode_spaces = {}
for _, codepoint in ipairs({
	0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
	0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
}) do unicode_spaces[#unicode_spaces + 1] = vim.fn.nr2char(codepoint) end

local function has_whitespace(value)
	if value:find("%s") then return true end
	for _, space in ipairs(unicode_spaces) do
		if value:find(space, 1, true) then return true end
	end
	return false
end

local function valid_date(value)
	local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not year then return false end
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	if month < 1 or month > 12 then return false end
	local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if month == 2 and year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then days[2] = 29 end
	return day >= 1 and day <= days[month]
end

local function valid_date_time(value)
	local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if year and tonumber(month) >= 1 and tonumber(month) <= 12 and tonumber(day) >= 1 and tonumber(day) <= 31 then
		return true
	end
	if value:match("^%d%d%d%d$") then return true end
	year, month = value:match("^(%d%d%d%d)%-(%d%d)$")
	if year and tonumber(month) >= 1 and tonumber(month) <= 12 then return true end
	local _, iso_month, iso_day, time = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](.+)$")
	if not time or tonumber(iso_month) < 1 or tonumber(iso_month) > 12 or tonumber(iso_day) < 1 or tonumber(iso_day) > 31 then
		return false
	end
	local hour, minute, rest = time:match("^(%d%d):(%d%d)(.*)$")
	if not hour then return false end
	hour, minute = tonumber(hour), tonumber(minute)
	if hour > 24 or minute > 59 then return false end
	local second, fraction
	if rest:sub(1, 1) == ":" then
		second, rest = rest:match("^:(%d%d)(.*)$")
		if not second then return false end
		second = tonumber(second)
		if second > 59 then return false end
	end
	if rest:sub(1, 1) == "." then
		fraction, rest = rest:match("^%.(%d+)(.*)$")
		if not fraction then return false end
	end
	if hour == 24 and (minute ~= 0 or (second or 0) ~= 0 or (fraction and tonumber(fraction) ~= 0)) then return false end
	if rest == "" or rest == "Z" or rest == "z" then return true end
	local sign, zone_hour, zone_minute = rest:match("^([+-])(%d%d):(%d%d)$")
	if not sign then sign, zone_hour, zone_minute = rest:match("^([+-])(%d%d)(%d%d)$") end
	return sign ~= nil and tonumber(zone_hour) <= 23 and tonumber(zone_minute) <= 59
end

local function valid_uri(value)
	if has_whitespace(value) then return false end
	local scheme, rest = value:match("^([%a][%w+%.%-]*):(.*)$")
	if not scheme then return false end
	if scheme:lower() == "http" or scheme:lower() == "https" then
		local authority = rest:match("^//([^/%?#]+)")
		if not authority then return false end
		if authority:sub(-1) == "@" then return false end
		local host_port = authority:match("^.*@(.+)$") or authority
		local host, port
		if host_port:sub(1, 1) == "[" then
			host, port = host_port:match("^(%[[%x:%.]+%]):?(%d*)$")
			if not host or not host:find(":", 1, true) then return false end
		else
			host, port = host_port:match("^([^:]+):?(%d*)$")
			if not host then return false end
		end
		if port ~= "" and tonumber(port) > 65535 then return false end
		if host:find("%%") then
			local decoded = host:gsub("%%[%x][%x]", "")
			if decoded:find("%%") then return false end
		end
		return host ~= "" and not host:find("@", 1, true)
	end
	return true
end

local function matches_pattern(pattern, value)
	-- Translate the JavaScript constructs that differ from Vim's very-magic
	-- notation. Preserve noncapturing groups and zero-width assertions.
	local translated, groups = {}, {}
	local i, in_class = 1, false
	while i <= #pattern do
		local char = pattern:sub(i, i)
		local next_char = pattern:sub(i + 1, i + 1)
		if char == "\\" then
			-- Vim does not implement these JavaScript escapes. Let the server's
			-- native validator decide rather than rejecting a valid answer here.
			if (next_char == "p" or next_char == "P" or next_char == "u") and pattern:sub(i + 2, i + 2) == "{" then
				return true
			end
			if next_char == "k" and pattern:sub(i + 2, i + 2) == "<" then return true end
			if not in_class and next_char == "b" then translated[#translated + 1] = "%(<|>)"
			elseif not in_class and next_char == "B" then translated[#translated + 1] = "%(<|>)@!"
			else translated[#translated + 1] = pattern:sub(i, i + 1) end
			i = i + 2
		elseif char == "[" or char == "]" then
			in_class = char == "["
			translated[#translated + 1] = char
			i = i + 1
		elseif not in_class and char == "(" then
			local kind, length = "", 1
			if pattern:sub(i, i + 2) == "(?:" then kind, length = "noncapture", 3
			elseif pattern:sub(i, i + 2) == "(?=" then kind, length = "@=", 3
			elseif pattern:sub(i, i + 2) == "(?!" then kind, length = "@!", 3
			elseif pattern:sub(i, i + 3) == "(?<=" then kind, length = "@<=", 4
			elseif pattern:sub(i, i + 3) == "(?<!" then kind, length = "@<!", 4 end
			if next_char == "?" and kind == "" then return true end
			translated[#translated + 1] = kind ~= "" and "%(" or "("
			groups[#groups + 1] = kind
			i = i + length
		elseif not in_class and char == ")" then
			local kind = groups[#groups]
			if kind == nil then return nil end
			groups[#groups] = nil
			translated[#translated + 1] = ")" .. (kind ~= "noncapture" and kind or "")
			i = i + 1
		elseif not in_class and next_char == "?" and (char == "*" or char == "+" or char == "?" or char == "}") then
			return true
		else
			translated[#translated + 1] = in_class and char or vim.fn.escape(char, "%@=<>~&")
			i = i + 1
		end
	end
	if in_class or #groups > 0 then return nil end
	translated = table.concat(translated)
	local ok, regex = pcall(vim.regex, "\\C\\v" .. translated)
	if not ok then return nil end
	local matched, start = pcall(regex.match_str, regex, value)
	if not matched then return nil end
	return start ~= nil
end

local function has_option(field, value)
	for _, option in ipairs(field.options or {}) do
		if option.value == value then return true end
	end
	return false
end

function M.validate(field, value)
	if field.type == "external" then
		if value == true then return nil end
		return "Complete and confirm the external action"
	end
	if not vim.tbl_contains({ "string", "boolean", "integer", "number", "multiselect" }, field.type) then
		return "Unsupported field type: " .. tostring(field.type)
	end
	if value == nil then return field.required and "Answer required" or nil end
	if field.type == "string" then
		if type(value) ~= "string" then return "Expected text" end
		if field.required and value == "" then return "Answer required" end
		local length = vim.str_utfindex(value, "utf-16")
		if field.minLength and length < field.minLength then return "Must be at least " .. field.minLength .. " characters" end
		if field.maxLength and length > field.maxLength then return "Must be at most " .. field.maxLength .. " characters" end
		if field.pattern ~= nil then
			local matched = matches_pattern(field.pattern, value)
			if matched == nil then return "Invalid pattern: " .. field.pattern end
			if not matched then return "Must match pattern: " .. field.pattern end
		end
		if field.format == "email" and (has_whitespace(value) or not value:match("^[^@]+@[^@]+%.[^@]+$")) then
			return "Expected an email address"
		end
		if field.format == "uri" and not valid_uri(value) then return "Expected a URL" end
		if field.format == "date" and not valid_date(value) then return "Expected a date (YYYY-MM-DD)" end
		if field.format == "date-time" and not valid_date_time(value) then return "Expected a date and time" end
		if field.options and not field.custom and not has_option(field, value) then return "Select an available option" end
		return nil
	end
	if field.type == "number" or field.type == "integer" then
		if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return "Expected a number" end
		if field.type == "integer" and value % 1 ~= 0 then return "Expected an integer" end
		if type(field.minimum) == "number" and value < field.minimum then return "Must be at least " .. field.minimum end
		if type(field.maximum) == "number" and value > field.maximum then return "Must be at most " .. field.maximum end
		return nil
	end
	if field.type == "boolean" then
		if type(value) == "boolean" then return nil end
		return "Expected yes or no"
	end
	if type(value) ~= "table" then return "Expected selections" end
	if field.required and #value == 0 then return "Select at least one option" end
	if field.minItems and #value < field.minItems then return "Select at least " .. field.minItems end
	if field.maxItems and #value > field.maxItems then return "Select at most " .. field.maxItems end
	for _, entry in ipairs(value) do
		if type(entry) ~= "string" then return "Select text values" end
		if not field.custom and not has_option(field, entry) then return "Select only available options" end
	end
	return nil
end

return M
