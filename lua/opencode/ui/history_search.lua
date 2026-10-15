local M = {}

local function searchable(text)
	return vim.fn.tolower((text:gsub("[%c]", " ")))
end

function M.new(cfg)
	cfg = cfg or {}
	local history = require("opencode.ui.input.history")
	history.configure(cfg)
	local entries, items, lines = history.list(), {}, {}
	for index = #entries, 1, -1 do
		local entry = entries[index]
		local label = entry.text ~= "" and entry.text:gsub("[%c]", " ") or "Attachments"
		items[#items + 1] = { value = index, label = label, entry = entry, description = entry.mode, kind = "history" }
		lines[#lines + 1] = searchable(label)
	end
	if #items == 0 then vim.notify("Prompt history is empty", vim.log.levels.INFO); return end
	local provider = cfg.history_search_provider or "grep"
	local executable = ({ grep = "grep", ripgrep = "rg" })[provider]
	if not executable then
		vim.notify("OpenCode: input.history_search_provider must be grep or ripgrep", vim.log.levels.ERROR)
		return
	end
	if vim.fn.executable(executable) ~= 1 then
		vim.notify("OpenCode: prompt history search requires " .. executable .. " in PATH", vim.log.levels.WARN)
		return
	end

	local search = { items = items }
	local corpus = table.concat(lines, "\n") .. "\n"
	local job, generation, closed = nil, 0, false
	local function cancel()
		generation = generation + 1
		if job then pcall(job.kill, job, 15); job = nil end
	end
	function search.search(query, callback)
		if closed then return end
		cancel()
		if query == "" then callback(items, false); return end
		local current = generation
		callback({}, true)
		if closed or generation ~= current then return end
		local argv = executable == "rg" and { "rg", "--no-config", "--color=never", "--no-heading" } or { "grep" }
		vim.list_extend(argv, { "-n", "-F", "-e", searchable(query), "--", "-" })
		local ok, process = pcall(vim.system, argv, { stdin = corpus, text = true, timeout = 3000 }, vim.schedule_wrap(function(result)
			if closed or generation ~= current then return end
			job = nil
			if result.code ~= 0 and result.code ~= 1 then
				local reason = result.stderr and result.stderr ~= "" and result.stderr or ("exit code " .. tostring(result.code))
				vim.notify("OpenCode: prompt history search failed: " .. reason, vim.log.levels.WARN)
				callback({}, false)
				return
			end
			local matches = {}
			if result.code == 0 then
				for line in (result.stdout or ""):gmatch("[^\n]+") do
					local item = items[tonumber(line:match("^(%d+):"))]
					if item then matches[#matches + 1] = item end
				end
			end
			callback(matches, false)
		end))
		if ok then job = process
		else
			vim.notify("OpenCode: prompt history search failed: " .. tostring(process), vim.log.levels.WARN)
			callback({}, false)
		end
	end
	function search.close()
		if closed then return end
		closed = true
		cancel()
	end
	return search
end

return M
