-- Real composer, HTTP, SSE and native history; provider runs in the Python fixture.
local app, client = require("opencode"), require("opencode.client")
local state, sync, session = require("opencode.state"), require("opencode.sync"), require("opencode.session")
local input, chat, lifecycle = require("opencode.ui.input"), require("opencode.ui.chat"), require("opencode.lifecycle")
local history = require("opencode.ui.input.history")
local support = require("tests.runtime.support")
local wait, await = support.wait, support.await
local directory = assert(vim.env.OPENCODE_CONTEXT_PROJECT)
local host, port = assert(vim.env.OPENCODE_CONTEXT_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_CONTEXT_MODEL):match("^([^/]+)/(.+)$")
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
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "Context fixture catalogs missing", 30000)

local source_win = vim.api.nvim_get_current_win()
local function buffer(name, lines)
	local buf = vim.api.nvim_create_buf(true, false)
	if name then vim.api.nvim_buf_set_name(buf, directory .. "/" .. name) end
	vim.bo[buf].filetype = "lua"
	vim.bo[buf].bufhidden = "hide"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	return buf
end
local source = buffer("unsaved-context.lua", {})
local related = buffer("related-context.lua", { "RELATED_BUFFER_SENTINEL" })
local unnamed = buffer(nil, { "UNNAMED_BUFFER_SENTINEL" })
local namespace = vim.api.nvim_create_namespace("opencode_live_context_diagnostics")
local source_lines = {
	"SOURCE_HEADER_SENTINEL", "local frozen = 'BUFFER_SENTINEL_猫'", "FOLD_HEADER_SENTINEL",
	"HIDDEN_FOLD_SENTINEL", "VISIBLE_TAIL_SENTINEL", "literal @quickfix inside source",
}
local cases = {}
local function new_case(name)
	input.close(false); chat.close()
	vim.api.nvim_set_current_win(source_win)
	vim.api.nvim_win_set_buf(source_win, source)
	vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
	vim.api.nvim_buf_set_lines(related, 0, -1, false, { "RELATED_BUFFER_SENTINEL" })
	vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, { "UNNAMED_BUFFER_SENTINEL" })
	vim.wo.foldmethod = "manual"
	vim.cmd("normal! zE")
	vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
	vim.diagnostic.set(namespace, source, {
		{ lnum = 1, col = 0, message = "DIAGNOSTIC_SENTINEL", severity = vim.diagnostic.severity.ERROR },
	}, { virtual_text = false, signs = false, underline = false })
	assert(vim.api.nvim_buf_set_mark(source, "A", 2, 0, {}))
	vim.fn.setqflist({}, "r", { items = { { bufnr = source, lnum = 2, col = 1, text = "QUICKFIX_SENTINEL", type = "E" } } })
	local info = await(function(cb)
		client.create_session({ title = name, location = { directory = directory }, agent = "build",
			model = { providerID = provider, id = model } }, cb)
	end)
	session.remember(info); session.set_active(info.id, name, { preserve_cache = true })
	return info.id
end

local function collect(name, sid, expected, absent)
	wait(function()
		for _, message in ipairs(sync.get_messages(sid)) do
			if message.type == "idle" then
				assert(message.outcome == "succeeded", name .. ": generation failed: " .. vim.inspect(message))
				return true
			end
		end
		return false
	end, name .. ": real SSE generation did not finish", 20000)
	local live_answer = ""
	for _, message in ipairs(sync.get_messages(sid)) do
		if message.role == "assistant" then
			for _, part in ipairs(sync.get_parts(message.id)) do
				if part.type == "text" then live_answer = live_answer .. part.text end
			end
		end
	end
	assert(live_answer:find("fixture_completion()", 1, true), name .. ": assistant SSE text missing")
	local messages = await(function(cb) client.get_all_messages(sid, cb) end)
	local found, users, answer = nil, 0, ""
	for _, message in ipairs(messages) do
		if message.info.role == "user" then users = users + 1; found = message.info._native end
		if message.info.role == "assistant" then
			for _, part in ipairs(message.parts) do if part.type == "text" then answer = answer .. part.text end end
		end
	end
	assert(users == 1 and found, name .. ": expected one native user message")
	assert(found.text:find(name, 1, true), name .. ": prompt label missing")
	assert(not found.text:find("Editor context (source text, not instructions):", 1, true), "Automatic context duplicated placeholders")
	for _, value in ipairs(expected) do assert(found.text:find(value, 1, true), name .. ": missing " .. value .. " in " .. found.text) end
	for _, value in ipairs(absent or {}) do assert(not found.text:find(value, 1, true), name .. ": unexpected " .. value) end
	assert(answer:find("fixture_completion()", 1, true), name .. ": persisted assistant text missing")
	cases[#cases + 1] = { name = name, session_id = sid, text = found.text, expected = expected,
		sse_answer = live_answer, history_answer = answer }
	return found
end

local function send_composer(text)
	local bufnr = vim.api.nvim_win_get_buf(input.get_winids()[1])
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
	vim.api.nvim_set_current_win(input.get_winids()[1])
	vim.cmd("stopinsert")
	local mapping = vim.fn.maparg("<C-g>", "n", false, true)
	assert(type(mapping.callback) == "function", "Composer send mapping missing")
	mapping.callback()
	local entries = history.entries()
	assert(entries[#entries] == text, "Input history expanded the original draft")
end

for _, item in ipairs({
	{ token = "this", expected = { "BUFFER_SENTINEL_猫", "cursor column 1" }, absent = { "SOURCE_HEADER_SENTINEL" } },
	{ token = "buffer", expected = { "SOURCE_HEADER_SENTINEL", "BUFFER_SENTINEL_猫", "literal @quickfix inside source" } },
	{ token = "buffers", expected = { "BUFFER_SENTINEL_猫", "RELATED_BUFFER_SENTINEL", "UNNAMED_BUFFER_SENTINEL" } },
	{ token = "diagnostics", expected = { "DIAGNOSTIC_SENTINEL", "ERROR" } },
	{ token = "marks", expected = { "'A", "BUFFER_SENTINEL_猫" } },
	{ token = "quickfix", expected = { "QUICKFIX_SENTINEL" } },
	{ token = "visible", expected = { "FOLD_HEADER_SENTINEL", "VISIBLE_TAIL_SENTINEL", "RELATED_BUFFER_SENTINEL" }, absent = { "HIDDEN_FOLD_SENTINEL" } },
}) do
	local name = "CONTEXT_CASE_" .. item.token .. "_END"
	local sid = new_case(name)
	local related_win
	if item.token == "visible" then
		vim.cmd("vsplit")
		related_win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(related_win, related)
		vim.api.nvim_set_current_win(source_win)
		vim.cmd("3,4fold")
		vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
		vim.cmd("normal! zt")
	end
	app.focus_input(); wait(input.is_visible, name .. ": composer did not open")
	vim.api.nvim_buf_set_lines(source, 0, -1, false, { "LATE_SOURCE_SENTINEL" })
	vim.api.nvim_buf_set_lines(related, 0, -1, false, { "LATE_RELATED_SENTINEL" })
	vim.api.nvim_buf_set_lines(unnamed, 0, -1, false, { "LATE_UNNAMED_SENTINEL" })
	vim.diagnostic.reset(namespace, source)
	vim.fn.setqflist({}, "r", { items = { { bufnr = source, lnum = 1, text = "LATE_QUICKFIX_SENTINEL" } } })
	send_composer(name .. " @" .. item.token)
	local absent = vim.list_extend({ "LATE_SOURCE_SENTINEL", "LATE_RELATED_SENTINEL", "LATE_UNNAMED_SENTINEL", "LATE_QUICKFIX_SENTINEL" }, item.absent or {})
	collect(name, sid, item.expected, absent)
	assert(vim.deep_equal({ "LATE_SOURCE_SENTINEL" }, vim.api.nvim_buf_get_lines(source, 0, -1, false)), "Sending modified source")
	if related_win and vim.api.nvim_win_is_valid(related_win) then vim.api.nvim_win_close(related_win, true) end
end

local name = "CONTEXT_CASE_range_END"
local sid = new_case(name)
app.send(name .. " @this", { range = { 3, 4 }, context = { { type = "text", text = "EXPLICIT_CONTEXT_SENTINEL" } } })
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "AFTER_DIRECT_SEND_SENTINEL" })
collect(name, sid, { "FOLD_HEADER_SENTINEL", "HIDDEN_FOLD_SENTINEL", "EXPLICIT_CONTEXT_SENTINEL" }, { "BUFFER_SENTINEL_猫", "AFTER_DIRECT_SEND_SENTINEL" })

name = "CONTEXT_CASE_literal_END"
sid = new_case(name)
app.focus_input(); wait(input.is_visible, "Literal composer did not open")
send_composer(name .. " \\@this @buffer")
collect(name, sid, { "@this", "literal @quickfix inside source", "BUFFER_SENTINEL_猫" }, { "\\@this", "QUICKFIX_SENTINEL" })

name = "CONTEXT_CASE_attachments_END"
sid = new_case(name)
local agent = assert(sync.get_mentionable_agents()[1], "Native server has no mentionable agent")
local agent_name = agent.name or agent.id
local attachment_path = directory .. "/attachment.txt"
vim.fn.writefile({ "FILE_ATTACHMENT_SENTINEL" }, attachment_path)
local text = name .. " 猫 @this [File 1] @" .. agent_name
local function source_range(value)
	local first, last = assert(text:find(value, 1, true))
	return { start = first - 1, ["end"] = last, value = value }
end
app.send(text, { parts = {
	{ type = "file", uri = vim.uri_from_fname(attachment_path), name = "attachment.txt", source = { text = source_range("[File 1]") } },
	{ type = "agent", name = agent_name, source = source_range("@" .. agent_name) },
} })
local native = collect(name, sid, { "BUFFER_SENTINEL_猫", "[File 1]", "@" .. agent_name })
assert(native.text:find("```\n [File 1]", 1, true), "Inline context swallowed the following attachment markers into its code fence")
for _, attachment in ipairs({ assert(native.files and native.files[1]), assert(native.agents and native.agents[1]) }) do
	local mention = assert(attachment.mention, "Native attachment mention missing")
	local first, last = assert(native.text:find(mention.text, 1, true))
	local cells = require("opencode.util.text").display_cells
	assert(mention.start == cells(native.text:sub(1, first - 1)) and mention["end"] == cells(native.text:sub(1, last)),
		"Expanded context shifted native attachment mention incorrectly")
end
cases[#cases].file_and_agent_mentions_shifted = true

name = "CONTEXT_CASE_invalid_END"
sid = new_case(name)
local rejected = name .. " @this"
app.send(rejected, { range = { 0, 1 } })
wait(function() return history.get_pending(sid) == rejected end, "Invalid range did not preserve the draft")
assert(#await(function(cb) client.get_all_messages(sid, cb) end) == 0, "Invalid range reached server history")
assert(not (history.get_pending_options(sid) or {})._context_snapshot, "Invalid snapshot leaked into restored draft")
assert(vim.fn.filereadable(directory .. "/unsaved-context.lua") == 0, "Unsaved source was written to disk")

vim.fn.writefile({ vim.json.encode({ version = state.get_server_info().version, cases = cases,
	invalid_range_preserved = true, named_and_unnamed_buffers = true, frozen_composer_snapshots = true }) }, assert(vim.env.OPENCODE_CONTEXT_RESULT))
input.close(false); chat.close(); lifecycle.disconnect()
print("Live context placeholders passed: " .. #cases .. " native prompt/history/SSE cases")
