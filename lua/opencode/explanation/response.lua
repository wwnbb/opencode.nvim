-- The default prompt asks the model to separate its final explanation from
-- any surrounding text. Custom prompts keep their output exactly as requested.
local M = {}

function M.display(text, config, opts)
	text = text:gsub("\r\n", "\n")
	if config.prompt ~= nil then return text end

	local streaming = opts and opts.streaming
	local lines = vim.split(text, "\n", { plain = true, trimempty = false })
	local started, answer
	for index, line in ipairs(lines) do
		if line:match("^%s*<answer>%s*$") then
			started = index + 1
		elseif started and line:match("^%s*</answer>%s*$") then
			local candidate = vim.trim(table.concat(lines, "\n", started, index - 1))
			if candidate ~= "" then answer = candidate end
			started = nil
		end
	end
	if streaming and started then
		local last = #lines
		local tail = vim.trim(lines[last])
		-- Hold a closing marker until its last fragment arrives.
		if tail ~= "" and ("</answer>"):sub(1, #tail) == tail then last = last - 1 end
		return vim.trim(table.concat(lines, "\n", started, last))
	end
	return answer or (streaming and "" or text)
end

return M
