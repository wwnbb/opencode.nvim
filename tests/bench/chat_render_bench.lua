-- Chat render benchmark (report only): ./tests/run.sh bench
-- Builds a long transcript, then times representative frames and counts the
-- buffer writes each one makes. Block verification is off, as in normal use.
vim.g.opencode_debug_render_blocks = false

local chat_surface = require("tests.helpers.chat_surface")
local sync = require("opencode.sync")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local state = require("opencode.ui.chat.state").state
local projection = require("opencode.protocol.messages")
local permissions = require("opencode.permission.state")
local questions = require("opencode.question.state")
local spinner = require("opencode.ui.spinner")

local SESSION = "bench-session"
local TURNS = tonumber(vim.env.OPENCODE_BENCH_TURNS) or 150
local RUNS = tonumber(vim.env.OPENCODE_BENCH_RUNS) or 21

spinner.get_frame = function() return "⠋" end

local function tool(id, name, input, status)
	return { type = "tool", id = id, name = name, time = { created = 1, completed = 2 }, state = {
		status = status or "completed", input = input,
		content = { { type = "text", text = "line 1\nline 2\nline 3" } }, output = "",
	} }
end

local messages = {}
for turn = 1, TURNS do
	local created = turn * 10
	messages[#messages + 1] = { id = "u" .. turn, type = "user", text = "Request " .. turn .. "\nwith **detail**",
		time = { created = created } }
	local last = turn == TURNS
	messages[#messages + 1] = {
		id = "a" .. turn, type = "assistant", parentID = "u" .. turn, agent = "build",
		model = { id = "test-model", providerID = "test-provider" }, finish = (not last) and "stop" or nil,
		time = { created = created + 1, completed = (not last) and (created + 5) or nil },
		content = {
			{ type = "text", text = "Answer " .. turn .. "\n\n- point `one`\n- point **two**\n\n```lua\nlocal x = " .. turn .. "\n```" },
			tool("s" .. turn, "shell", { command = "ls " .. turn, description = "List " .. turn }),
			tool("r" .. turn, "read", { path = "/srv/file" .. turn .. ".lua" }),
			{ type = "text", text = "Done with " .. turn },
		},
	}
end

local function update()
	sync.handle_session_messages(SESSION, projection.page(SESSION, messages))
end

local counts = { set_lines = 0, set_extmark = 0 }
local api_set_lines, api_set_extmark = vim.api.nvim_buf_set_lines, vim.api.nvim_buf_set_extmark
vim.api.nvim_buf_set_lines = function(bufnr, ...)
	if bufnr == state.bufnr then counts.set_lines = counts.set_lines + 1 end
	return api_set_lines(bufnr, ...)
end
vim.api.nvim_buf_set_extmark = function(bufnr, ...)
	if bufnr == state.bufnr then counts.set_extmark = counts.set_extmark + 1 end
	return api_set_extmark(bufnr, ...)
end

local function median(values)
	table.sort(values)
	return values[math.ceil(#values / 2)]
end

local results = {}
---@param name string
---@param prepare fun(run: integer) Change the stores (untimed)
---@param frame fun() The timed work
---@param reset? fun(run: integer) Undo prepare through a render (untimed)
local function measure(name, prepare, frame, reset)
	local times, set_lines, set_extmark = {}, {}, {}
	for run = 1, RUNS do
		prepare(run)
		counts.set_lines, counts.set_extmark = 0, 0
		local started = vim.uv.hrtime()
		frame()
		times[#times + 1] = (vim.uv.hrtime() - started) / 1e6
		set_lines[#set_lines + 1], set_extmark[#set_extmark + 1] = counts.set_lines, counts.set_extmark
		if reset then reset(run) end
	end
	results[#results + 1] = string.format("%-34s median %7.2f ms   set_lines %4d   set_extmark %6d",
		name, median(times), median(set_lines), median(set_extmark))
end

local surface = chat_surface.setup()
local ok, err = xpcall(function()
	app.set_session(SESSION, "Bench")
	app.set_session_status(SESSION, { type = "busy" })
	state.full_history_sessions[SESSION] = true
	questions.add_form({ id = "bench-question", sessionID = SESSION, fields = { { key = "choice", type = "select",
		title = "Pick one", options = { { label = "Yes", value = "yes" }, { label = "No", value = "no" } } } } })
	update()
	local started = vim.uv.hrtime()
	chat.do_render()
	local cold = (vim.uv.hrtime() - started) / 1e6
	chat.do_render()
	local line_count = vim.api.nvim_buf_line_count(state.bufnr)

	local last = messages[#messages]
	local stream_part = sync.get_parts(last.id)[4].id
	local function delta(run)
		sync.handle_server_event({ id = "bench-delta-" .. tostring(run) .. "-" .. tostring(vim.uv.hrtime()),
			created = 1e6 + run, type = "session.text.delta",
			data = { sessionID = SESSION, assistantMessageID = last.id, ordinal = 3, delta = " word" .. run } })
	end
	measure("(a) stream delta, in place", delta, function()
		assert(chat.update_stream_part_block(SESSION, last.id, stream_part), "in-place stream update")
	end)
	measure("(a) stream delta, render", delta, chat.do_render)

	local middle = messages[TURNS + (TURNS % 2)].content[2]
	measure("(b) tool status change, middle", function(run)
		middle.state.status = run % 2 == 0 and "completed" or "error"
		update()
	end, chat.do_render)

	measure("(c) permission near the top", function()
		permissions.add_permission("bench-perm", SESSION, "shell", { message_id = "a2", call_id = "s2",
			tool_name = "bash", patterns = { "ls 2" }, always = { "ls *" }, tool_input = { command = "ls 2" }, timestamp = 1 })
	end, chat.do_render, function()
		permissions.remove_permission("bench-perm")
		chat.do_render()
	end)

	measure("(d) no-op render", function() end, chat.do_render)
	-- A failing render is fast; do not report its timings.
	assert(require("opencode.logger").count_by_level("ERROR") == 0, "a benchmark frame failed to render")

	print(string.format("transcript: %d messages, %d buffer lines, cold render %.1f ms, %d runs each",
		#messages, line_count, cold, RUNS))
	for _, line in ipairs(results) do print(line) end
end, debug.traceback)
chat_surface.restore(surface)
if not ok then
	io.stderr:write(tostring(err) .. "\n")
	vim.cmd("cquit 1")
end
vim.cmd("qa!")
