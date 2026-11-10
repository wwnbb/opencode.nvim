-- The default prompt asks the model to separate its final explanation from
-- any surrounding text. Custom prompts keep their output exactly as requested.
local M = {}

local OPEN, CLOSE = "<answer>", "</answer>"

-- Markers are asked for on their own lines, but models often put a short
-- answer on one line: <answer> may lead a line and </answer> may end one.
-- Markers elsewhere in a line are literal text.
local function opening(line)
	return line:match("^%s*" .. OPEN .. "(.*)$")
end

local function closing(line)
	return line:match("^(.-)" .. CLOSE .. "%s*$")
end

-- Length of a trailing fragment that may still grow into the closing marker.
local function partial_close(line)
	for length = #CLOSE - 1, 1, -1 do
		if line:sub(-length) == CLOSE:sub(1, length) then return length end
	end
	return 0
end

function M.display(text, config, opts)
	text = text:gsub("\r\n", "\n")
	if config.prompt ~= nil then return text end

	local streaming = opts and opts.streaming
	local lines = vim.split(text, "\n", { plain = true, trimempty = false })
	local current, answer
	local function finish(body)
		current[#current + 1] = body
		local candidate = vim.trim(table.concat(current, "\n"))
		if candidate ~= "" then answer = candidate end
		current = nil
	end
	for _, line in ipairs(lines) do
		local rest = opening(line)
		if rest then
			current = {}
			local body = closing(rest)
			if body then finish(body) else current[1] = rest end
		elseif current then
			local body = closing(line)
			if body then finish(body) else current[#current + 1] = line end
		end
	end
	if streaming and current then
		-- Hold a closing marker until its last fragment arrives.
		local last = current[#current]:gsub("%s+$", "")
		current[#current] = last:sub(1, #last - partial_close(last))
		return vim.trim(table.concat(current, "\n"))
	end
	return answer or (streaming and "" or text)
end

return M
