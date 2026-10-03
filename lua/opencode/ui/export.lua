-- Complete session export workflow. Formatting is kept separate from the UI.
local M = {}

local actions = require("opencode.actions")
local menu = require("opencode.ui.menu")
local state = require("opencode.state")

local function error_text(err)
	return type(err) == "table" and (err.message or err.code) or tostring(err)
end

local function session_id()
	local id = (state.get_session() or {}).id
	if not id then vim.notify("No active session", vim.log.levels.WARN) end
	return id
end

local function copy(content)
	vim.fn.setreg('"', content)
	local wrote, result = pcall(vim.fn.setreg, "+", content)
	local read, copied = false, nil
	if wrote and result == 0 then read, copied = pcall(vim.fn.getreg, "+") end
	if read and copied == content then
		vim.notify("Session transcript copied", vim.log.levels.INFO)
	else
		vim.notify("Could not copy to system clipboard; transcript is in the unnamed register", vim.log.levels.ERROR)
	end
end

local function open_buffer(content, format)
	local lines = vim.split(content, "\n", { plain = true })
	if lines[#lines] == "" then table.remove(lines) end
	vim.cmd("tabnew")
	local bufnr = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].filetype = format == "json" and "json" or "markdown"
	vim.bo[bufnr].modified = true
	vim.notify("Export opened in a buffer. Use :write <path> to save it.", vim.log.levels.INFO)
	return bufnr
end

local function export(id, opts)
	if not id then return false end
	opts = opts or {}
	local format = opts.format == "json" and "json" or "markdown"
	local request_opts = format == "json" and { sanitize = opts.sanitize == true } or {}
	actions.export_session(id, request_opts, function(err, transcript)
		if err then
			vim.notify("Could not export session: " .. error_text(err), vim.log.levels.ERROR)
			return
		end
		if type(transcript) ~= "table" or type(transcript.messages) ~= "table" then
			vim.notify("Could not export session: invalid server response", vim.log.levels.ERROR)
			return
		end
		local formatter = require("opencode.export")
		local ok, content = pcall(function()
			if format == "json" then return formatter.json(transcript) end
			return formatter.markdown(transcript, {
				thinking = opts.thinking ~= false,
				tools = opts.tools ~= false,
			})
		end)
		if not ok or type(content) ~= "string" then
			vim.notify("Could not format session export: " .. error_text(content), vim.log.levels.ERROR)
			return
		end
		if opts.action == "buffer" then open_buffer(content, format) else copy(content) end
	end)
	return true
end

---Fetch from the server, then copy or open an editable export buffer.
---@param opts table { action: "copy"|"buffer", format: "markdown"|"json", thinking?: boolean, tools?: boolean, sanitize?: boolean }
function M.run(opts)
	return export(session_id(), opts)
end

---Show format, content, and destination choices in a single repeatable menu.
function M.show()
	local id = session_id()
	if not id then return false end
	local pending = require("opencode.session.pending")
	local token = pending.token(id)
	local opts = { format = "markdown", thinking = true, tools = true, sanitize = false }
	local function choose()
		local items = {
			{ label = "Format: " .. (opts.format == "json" and "JSON" or "Markdown"), value = "format" },
		}
		if opts.format == "markdown" then
			items[#items + 1] = { label = "Include thinking: " .. (opts.thinking and "Yes" or "No"), value = "thinking" }
			items[#items + 1] = { label = "Include tools: " .. (opts.tools and "Yes" or "No"), value = "tools" }
		else
			items[#items + 1] = { label = "Sanitize sensitive data: " .. (opts.sanitize and "Yes" or "No"), value = "sanitize" }
		end
		items[#items + 1] = { label = "Copy export", value = "copy" }
		items[#items + 1] = { label = "Open export buffer", value = "buffer", description = ":write to save" }
		menu.open({
			title = " Export Session ", width = 62, sort = false, items = items,
			on_select = function(item)
				if not pending.is_current(token) then return end
				local choice = item.value
				if choice == "format" then
					opts.format = opts.format == "markdown" and "json" or "markdown"
				elseif choice == "thinking" or choice == "tools" or choice == "sanitize" then
					opts[choice] = not opts[choice]
				else
					export(id, vim.tbl_extend("force", opts, { action = choice }))
					return
				end
				choose()
			end,
		})
	end
	choose()
	return true
end

return M
