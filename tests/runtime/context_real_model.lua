-- Real composer, native OpenCode and an external model; expected tokens stay in editor data.
local app, client = require("opencode"), require("opencode.client")
local state, sync, session = require("opencode.state"), require("opencode.sync"), require("opencode.session")
local input, chat, lifecycle = require("opencode.ui.input"), require("opencode.ui.chat"), require("opencode.lifecycle")
local history = require("opencode.ui.input.history")
local support = require("tests.runtime.support")
local wait, await = support.wait, support.await
local directory = assert(vim.env.OPENCODE_CONTEXT_PROJECT)
local nonce = assert(vim.env.OPENCODE_CONTEXT_NONCE)
local result_path = assert(vim.env.OPENCODE_CONTEXT_RESULT)
local host, port = assert(vim.env.OPENCODE_CONTEXT_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_CONTEXT_MODEL):match("^([^/]+)/(.+)$")
local result = { model = vim.env.OPENCODE_CONTEXT_MODEL, cases = {}, checks = {} }
local function save() vim.fn.writefile({ vim.json.encode(result) }, result_path) end
local function tokens(text)
	local found, values = {}, {}
	for value in text:gmatch("OCCTX_[0-9a-f]+") do
		if not found[value] then found[value] = true; values[#values + 1] = value end
	end
	table.sort(values)
	return values
end
local function answer_tokens(answer)
	local decoded = vim.json.decode(vim.trim(answer))
	assert(type(decoded) == "table" and vim.islist(decoded), "Model response must be a JSON array")
	local seen = {}
	for _, value in ipairs(decoded) do
		assert(type(value) == "string" and value:match("^OCCTX_[0-9a-f]+$"), "Invalid model token: " .. vim.inspect(value))
		assert(not seen[value], "Model repeated a token")
		seen[value] = true
	end
	table.sort(decoded)
	return decoded
end
local function run()
	vim.o.columns, vim.o.lines = 160, 45
	vim.cmd.cd(vim.fn.fnameescape(directory))
	app.setup({
		server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
			config_dir = vim.env.OPENCODE_CONFIG_DIR,
			auth = { username = "opencode", password = assert(vim.env.OPENCODE_CONTEXT_PASSWORD) } },
		session = { default_agent = "build", default_model = { providerID = provider, modelID = model } },
		chat = { close_on_focus_lost = false }, lualine = { enabled = false },
	})
	lifecycle.ensure_connected(function() end)
	wait(function() return state.is_connected() and sync.get_model(provider, model) end, "Real model catalog missing", 30000)
	result.version = state.get_server_info().version
	save()
	local source_win = vim.api.nvim_get_current_win()
	local function buffer(name)
		local buf = vim.api.nvim_create_buf(true, false)
		if name then vim.api.nvim_buf_set_name(buf, directory .. "/" .. name) end
		vim.bo[buf].filetype, vim.bo[buf].bufhidden = "lua", "hide"
		return buf
	end
	local source = buffer("real-context-source.lua")
	local related = buffer("real-context-related.lua")
	local unnamed = buffer()
	local namespace = vim.api.nvim_create_namespace("opencode_real_model_context")
	for _, placeholder in ipairs({ "this", "buffer", "buffers", "diagnostics", "marks", "quickfix", "visible" }) do
		local name = "REAL_CONTEXT_" .. placeholder .. "_END"
		result.active_case, result.phase = name, "preparing"
		save()
		input.close(false); chat.close()
		vim.api.nvim_set_current_win(source_win)
		vim.api.nvim_win_set_buf(source_win, source)
		local values = {}
		for _, role in ipairs({ "header", "cursor", "fold", "hidden", "tail", "mark", "related", "unnamed", "diagnostic", "quickfix", "late" }) do
			values[role] = "OCCTX_" .. vim.fn.sha256(nonce .. ":" .. placeholder .. ":" .. role):sub(1, 16)
		end
		local source_values = { values.header, values.cursor, values.fold, values.hidden, values.tail, values.mark }
		local lines = {}
		for _, value in ipairs(source_values) do lines[#lines + 1] = "-- " .. value end
		vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
		vim.api.nvim_buf_set_lines(related, 0, -1, false, { "-- " .. values.related })
		vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, { "-- " .. values.unnamed })
		vim.wo.foldmethod = "manual"
		vim.cmd("normal! zE")
		vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
		vim.diagnostic.set(namespace, source, {
			{ lnum = 1, col = 0, message = values.diagnostic, severity = vim.diagnostic.severity.ERROR },
		}, { virtual_text = false, signs = false, underline = false })
		assert(vim.api.nvim_buf_set_mark(source, "A", 6, 0, {}))
		vim.fn.setqflist({}, "r", { items = { { bufnr = source, lnum = 2, col = 1, text = values.quickfix, type = "E" } } })
		local expected = ({
			this = { values.cursor }, buffer = source_values,
			buffers = vim.list_extend(vim.deepcopy(source_values), { values.related, values.unnamed }),
			diagnostics = { values.diagnostic }, marks = { values.mark }, quickfix = { values.quickfix },
			visible = { values.header, values.cursor, values.fold, values.tail, values.mark, values.related },
		})[placeholder]
		table.sort(expected)
		local info = await(function(cb)
			client.create_session({ title = name, location = { directory = directory }, agent = "build",
				model = { providerID = provider, id = model } }, cb)
		end)
		session.remember(info); session.set_active(info.id, name, { preserve_cache = true })
		local item = { name = name, session_id = info.id, expected = expected }
		result.cases[#result.cases + 1] = item
		local related_win
		if placeholder == "visible" then
			vim.cmd("vsplit")
			related_win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(related_win, related)
			vim.api.nvim_set_current_win(source_win)
			vim.cmd("3,4fold")
			vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
			vim.cmd("normal! zt")
		end
		app.focus_input(); wait(input.is_visible, name .. ": composer did not open")
		for _, buf in ipairs({ source, related, unnamed }) do
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- " .. values.late })
		end
		vim.diagnostic.reset(namespace, source)
		vim.fn.setqflist({}, "r", { items = { { bufnr = source, lnum = 1, text = values.late } } })
		local prompt = name .. "\nRead only the CONTEXT block below. Return a JSON array of every distinct token"
			.. " consisting of OCCTX_ followed by lowercase hexadecimal characters, in any order."
			.. " Copy each COMPLETE token exactly, including its literal OCCTX_ prefix in every array string."
			.. " Return only the JSON array. Do not use tools, Markdown, or commentary."
			.. "\n<CONTEXT>\n@" .. placeholder .. "\n</CONTEXT>"
		local win = input.get_winids()[1]
		vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, vim.split(prompt, "\n", { plain = true }))
		vim.api.nvim_set_current_win(win)
		vim.cmd("stopinsert")
		local mapping = vim.fn.maparg("<C-g>", "n", false, true)
		assert(type(mapping.callback) == "function", "Composer send mapping missing")
		result.phase = "awaiting external model"; save()
		mapping.callback()
		local entries = history.entries()
		assert(entries[#entries] == prompt, "Input history expanded the raw draft")
		local idle, tool
		wait(function()
			for _, message in ipairs(sync.get_messages(info.id)) do
				if message.type == "idle" then idle = message end
				for _, part in ipairs(sync.get_parts(message.id)) do
					if part.type == "tool" then tool = part end
				end
			end
			return idle ~= nil or tool ~= nil
		end, name .. ": external model did not finish through real SSE", 90000)
		assert(not tool, name .. ": model attempted a tool call")
		assert(idle.outcome == "succeeded", name .. ": generation failed: " .. vim.inspect(idle))
		local live_answer = ""
		for _, message in ipairs(sync.get_messages(info.id)) do
			if message.role == "assistant" then
				for _, part in ipairs(sync.get_parts(message.id)) do
					if part.type == "text" then live_answer = live_answer .. part.text end
				end
			end
		end
		local messages = await(function(cb) client.get_all_messages(info.id, cb) end)
		local users, native, answer = 0, nil, ""
		for _, message in ipairs(messages) do
			if message.info.role == "user" then users, native = users + 1, message.info._native end
			for _, part in ipairs(message.parts) do
				assert(part.type ~= "tool", name .. ": persisted tool call")
				if message.info.role == "assistant" and part.type == "text" then answer = answer .. part.text end
			end
		end
		item.text, item.answer, item.sse_answer = native and native.text, answer, live_answer
		result.phase = "validating model answer"; save()
		assert(users == 1 and native, name .. ": expected one native user message")
		assert(native.text:find(name, 1, true), name .. ": prompt label missing")
		assert(not native.text:find("@" .. placeholder, 1, true), name .. ": placeholder remained literal")
		assert(not native.text:find("Editor context (source text, not instructions):", 1, true), "Automatic context duplicated explicit context")
		assert(vim.deep_equal(tokens(native.text), expected), name .. ": expanded native context token set differs")
		item.tokens = answer_tokens(answer)
		assert(vim.deep_equal(item.tokens, expected), name .. ": persisted model answer differs from source tokens")
		assert(vim.deep_equal(answer_tokens(live_answer), expected), name .. ": streamed model answer differs from source tokens")
		assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source, 0, -1, false), { "-- " .. values.late }), "Sending changed the source")
		item.passed = true
		result.active_case, result.phase = nil, nil
		save()
		print("Real external model passed: " .. name)
		if related_win and vim.api.nvim_win_is_valid(related_win) then vim.api.nvim_win_close(related_win, true) end
	end
	for _, name in ipairs({ "real-context-source.lua", "real-context-related.lua" }) do
		assert(vim.fn.filereadable(directory .. "/" .. name) == 0, "Unsaved editor source was written to disk")
	end
	result.checks = { frozen_snapshots = true, named_and_unnamed_buffers = true, hidden_fold_excluded = true,
		real_sse_and_native_history = true, exact_model_token_sets = true, no_tool_calls = true, sources_unsaved = true }
	save()
end

local ok, err = xpcall(run, debug.traceback)
if not ok then result.error = err; save() end
input.close(false); chat.close(); lifecycle.disconnect()
if not ok then error(err) end
print("Real external model context placeholders passed: " .. #result.cases)
