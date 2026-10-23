-- Native foreground subagent linkage across hydration, reconnect and cold attach.
local support = require("tests.runtime.support")
local wait, await = support.wait, support.await
local app, client, state = require("opencode"), require("opencode.client"), require("opencode.state")
local actions, session, sync = require("opencode.actions"), require("opencode.session"), require("opencode.sync")
local chat, cs = require("opencode.ui.chat"), require("opencode.ui.chat.state").state
local tasks, children = require("opencode.ui.chat.tasks"), require("opencode.ui.chat.task_children")
local animation = require("opencode.ui.chat.task_animation")
local phase, profile = assert(vim.env.OPENCODE_SUBSESSION_PHASE), assert(vim.env.OPENCODE_SUBSESSION_PROFILE)
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
local function save(name, value) vim.fn.writefile({ vim.json.encode(value) }, profile .. "/" .. name .. ".json") end
local function read(name) return vim.json.decode(table.concat(vim.fn.readfile(profile .. "/" .. name .. ".json"), "\n")) end
local function key(name)
	local map = vim.fn.maparg(name, "n", false, true)
	assert(type(map.callback) == "function", "Missing mapping " .. name); map.callback()
end
local function menu_text()
	local lines = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].filetype == "opencode_float" and not vim.bo[buf].modifiable then
			vim.list_extend(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		end
	end
	return table.concat(lines, "\n")
end
local function entries()
	chat.do_render()
	local found = {}
	for id, pos in pairs(cs.tasks) do
		local part = tasks.resolve_tool_part(pos)
		if part and part.raw_tool == "subagent" then found[#found + 1] = { id = id, part = part, child = children.get_task_child_session_id(part) } end
	end
	table.sort(found, function(a, b) return a.id < b.id end)
	return found
end
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } }, lualine = { enabled = false } })
require("opencode.lifecycle").ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "Fixture model not discovered")
local background = phase:find("background", 1, true) ~= nil
local fresh = phase == "warm" or phase == "background"
local parent_file = background and "background-parent" or "parent"
local info = fresh and await(function(cb)
	client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model } }, cb)
end) or read(parent_file)
if fresh then save(parent_file, info) end
session.remember(info); session.set_active(info.id, "Subsession lifecycle", { preserve_cache = true }); chat.open(); chat.focus()
if fresh then
	assert(require("opencode.send").send(background and "SUBSESSION_BACKGROUND" or "SUBSESSION_PARENT", {}))
	wait(function()
		local found = entries()
		return #found == 2 and found[1].child and found[2].child
	end, "Two foreground child links did not arrive over SSE", 30000)
else
	await(function(cb) actions.load_session_messages(info.id, { all = true }, cb) end)
end
local found = entries()
assert(#found == 2, "Native parent did not render both subagent tasks")
local result = { parent = info.id, tasks = {}, phase = phase }
if background then
	for _, entry in ipairs(found) do result.tasks[entry.id] = entry.child end
	if phase == "background" then
		wait(function()
			for _, entry in ipairs(entries()) do
				if entry.part.state.status ~= "completed" or animation.task_status(entry.part) ~= "running" then return false end
			end
			return true
		end, "Background launches did not keep their child activity")
		local frame = cs.task_anim_frame
		wait(function() return cs.task_anim_frame ~= frame end, "Background spinner did not advance")
		for _, entry in ipairs(entries()) do
			if entry.part.state.input.prompt == "SUBSESSION_CHILD_INTERRUPTED" then
				require("opencode.ui.palette.family").show()
				wait(function()
					return vim.api.nvim_get_current_win() ~= chat.get_winid() and vim.bo.filetype == "opencode_float"
				end, "Family picker did not open for live status verification")
				local menu_win, input = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
				vim.api.nvim_buf_set_lines(input, 0, -1, false, { entry.child })
				vim.api.nvim_exec_autocmds("TextChanged", { buffer = input })
				result.family_menu_before_interrupt = menu_text()
				assert(result.family_menu_before_interrupt:find(entry.child, 1, true), "Selected child detail lost its full ID")
				assert(result.family_menu_before_interrupt:find("general · Active", 1, true), "Running child is not Active in family picker")
				await(function(cb) actions.interrupt_session(entry.child, cb) end)
				wait(function() return (sync.get_session_status(entry.child) or {}).outcome == "interrupted" end, "Child did not interrupt")
				assert(animation.task_status(entry.part) == "cancelled", "Interrupted child shows success or still spins")
				wait(function() return menu_text():find("general · Inactive", 1, true) ~= nil end,
					"Open family picker did not refresh the interrupted child status")
				assert(vim.api.nvim_get_current_win() == menu_win and vim.api.nvim_win_get_buf(menu_win) == input,
					"Live family status refresh replaced the open picker")
				result.family_menu_after_interrupt = menu_text()
				key("q"); wait(function() return not vim.api.nvim_win_is_valid(menu_win) end, "Family picker did not close")
				assert(state.get_session().id == info.id, "Closing family picker changed the active session")
			end
		end
		result.interrupted_child_stopped = true
		result.family_status_updated_live = true
	else
		result.outcomes = {}
		result.native = {}
		for _, entry in ipairs(entries()) do
			local expected = entry.part.state.input.prompt == "SUBSESSION_CHILD_INTERRUPTED" and "interrupted" or "failed"
			result.native[entry.child] = {
				session = await(function(cb) client.get_session(entry.child, cb) end),
				history = await(function(cb) client.get_all_messages(entry.child, cb) end),
				status = sync.get_session_status(entry.child), part = entry.part,
			}
			save(phase, result)
			wait(function() return animation.task_status(entry.part) == (expected == "interrupted" and "cancelled" or "error") end,
				"Background outcome lost on cold attach: " .. expected)
			result.outcomes[entry.child] = expected
		end
	end
elseif phase == "warm" then
	for _, entry in ipairs(found) do result.tasks[entry.id] = entry.child end
	assert(found[1].child ~= found[2].child, "Identical descriptions collapsed two children")
	local history = await(function(cb) client.get_all_messages(info.id, cb) end)
	result.running_history = history
	await(function(cb) actions.load_session_messages(info.id, { all = true }, cb) end)
	for _, entry in ipairs(entries()) do assert(entry.child == result.tasks[entry.id], "Hydration erased or changed an exact link") end
	client.disconnect_events(); state.set_connection("idle"); assert(client.connect_events())
	wait(state.is_connected, "SSE did not reconnect")
	await(function(cb) actions.load_session_messages(info.id, { all = true }, cb) end)
	for _, entry in ipairs(entries()) do assert(entry.child == result.tasks[entry.id], "Reconnect erased or changed an exact link") end
elseif phase == "cold" then
	-- The server can omit foreground links until completion; discovery must not guess by title.
	for _, entry in ipairs(found) do assert(not entry.child, "Cold fixture unexpectedly retained foreground metadata") end
	result.missing_running_links = true
	local native_children = await(function(cb) client.get_session_children(info.id, cb) end)
	assert(#native_children == 2, "Native family lost running children")
	for _, child in ipairs(native_children) do
		chat.focus(); chat.do_render()
		local pos = assert(cs.tasks[found[1].id])
		vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 }); key("gd")
		wait(function()
			return vim.api.nvim_get_current_win() ~= chat.get_winid() and vim.bo.filetype == "opencode_float"
		end, "Missing exact link did not open the native family picker")
		assert(state.get_session().id == info.id, "Ambiguous task navigated before an explicit selection")
		result.family_menu = menu_text()
		for _, candidate in ipairs(native_children) do
			assert(result.family_menu:find(candidate.id:sub(-6), 1, true), "Identical titles hide their distinct child suffixes")
		end
		local input = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(input, 0, -1, false, { child.id })
		vim.api.nvim_exec_autocmds("TextChanged", { buffer = input })
		assert(menu_text():find(child.id, 1, true), "Full child ID search did not update the selected detail")
		key("<CR>")
		wait(function() return state.get_session().id == child.id end, "Family picker chose the wrong explicit child")
		key("<BS>"); wait(function() return state.get_session().id == info.id end, "Family Backspace lost native parent")
		for _, entry in ipairs(entries()) do assert(not entry.child, "Explicit family selection fabricated a task link") end
	end
	result.explicit_family_navigation = true
else
	wait(function()
		local status = sync.get_session_status(info.id)
		return status and status.type == "idle"
	end, "Parent did not complete", 30000)
	await(function(cb) actions.load_session_messages(info.id, { all = true }, cb) end)
	local warm = read("warm")
	for _, entry in ipairs(entries()) do
		assert(entry.child == warm.tasks[entry.id], "Completed native history lost the exact child")
		result.tasks[entry.id] = entry.child
	end
end
if phase ~= "cold" then
	for _, entry in ipairs(entries()) do
		chat.focus(); chat.do_render()
		local pos = assert(cs.tasks[entry.id])
		vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 }); key("gd")
		wait(function() return state.get_session().id == entry.child end, "gd selected the wrong child")
		if phase == "completed" then
			chat.do_render()
			local text = table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n")
			local expected = entry.part.state.input.prompt:gsub("^SUBSESSION_", "")
			assert(text:find(expected, 1, true), "Child result does not match its task")
		end
		key("<BS>"); wait(function() return state.get_session().id == info.id end, "Backspace lost parent")
	end
	result.exact_navigation = true
end
save(phase, result)
chat.close(); require("opencode.lifecycle").disconnect()
print("Native subsession phase passed: " .. phase)
