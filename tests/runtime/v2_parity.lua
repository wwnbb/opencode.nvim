-- Real native contracts in a disposable loopback server; no prompts/provider credentials.
-- Native moves may drain pending synthetic shell notices without an explicit prompt.
local app, client, actions = require("opencode"), require("opencode.client"), require("opencode.actions")
local state, session, lifecycle = require("opencode.state"), require("opencode.session"), require("opencode.lifecycle")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local function wait(predicate, why, timeout)
	assert(vim.wait(timeout or 15000, predicate, 20), why)
end
local function await(register, optional)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "HTTP timeout")
	if optional and failure and (failure.status == 404 or failure.status == 405) then return nil end
	assert(not failure, vim.inspect(failure)); return value
end
local function git(args)
	vim.fn.system(vim.list_extend({ "git", "-C", directory }, args)); assert(vim.v.shell_error == 0, "Git fixture failed")
end
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	lualine = { enabled = false }, chat = { session_tabs = { persist = false } } })
lifecycle.ensure_connected(function() end); wait(state.is_connected, "No native connection")
local server = await(client.health)
local plugins = await(function(cb) client.list_server_plugins({ directory = directory }, cb) end)
assert(type(plugins) == "table", "Native plugin inventory missing")
local pairing = await(client.pair_server, true)
if pairing then assert(type(pairing.code) == "string" and pairing.expires_in > 0, "Native pairing contract malformed") end
local other = directory .. "-other"
vim.fn.mkdir(other, "p"); vim.fn.system({ "git", "init", "--quiet", other }); assert(vim.v.shell_error == 0)
for _, scope in ipairs({ directory, other }) do
	local providers = await(function(cb) client.list_providers(cb, { directory = scope }) end)
	assert(next(providers) == nil, "Native parity profile must deny all provider use")
end
local first = await(function(cb) client.create_session({ title = "Parity local", location = { directory = directory } }, cb) end)
local second = await(function(cb) client.create_session({ title = "Parity remote", location = { directory = other } }, cb) end)
session.remember(first); session.set_active(first.id, first.title, { preserve_cache = true })
local cwd = vim.fn.getcwd()
await(function(cb) actions.open_session(second.id, {}, cb) end)
assert(state.get_session().id == second.id and vim.fn.getcwd() == cwd, "Cross-project open failed")
await(function(cb) actions.rename_session(second.id, "Renamed remote", cb) end)
assert(state.get_session().name == "Renamed remote", "Native rename was not reconciled")
await(function(cb) client.view_session(second.id, 123, cb) end)
local viewed = await(function(cb) client.get_session(second.id, cb) end)
assert(viewed.time.viewed == nil, "Viewing a session without an idle transition must be a no-op")

-- Worktree CRUD and move retain history and change the actual execution directory.
local location = await(function(cb) client.get_location(directory, cb) end)
local tree = await(function(cb) client.create_worktree(location.project.id, { name = "parity-worktree", directory = directory .. "-trees" }, cb) end)
local trees = await(function(cb) client.list_worktrees(location.project.id, cb) end)
assert(vim.tbl_contains(vim.tbl_map(function(item) return item.directory end, trees), tree.directory), "Created worktree missing")
await(function(cb) client.move_session(first.id, tree.directory, cb) end)
local moved = await(function(cb) client.get_session(first.id, cb) end)
assert(moved.location.directory == tree.directory, "Native move did not change location")
await(function(cb) client.run_session_shell(first.id, "pwd", cb) end)
local moved_history = await(function(cb) client.get_messages(first.id, {}, cb) end)
local moved_output = false
for _, message in ipairs(moved_history) do
	local result = message.info.output
	if type(result) == "table" and vim.trim(result.output or "") == tree.directory then moved_output = true end
end
assert(moved_output, "Tools did not execute in moved location")
vim.fn.writefile({ "dirty fixture" }, tree.directory .. "/dirty.txt")
local dirty_done, dirty_err
client.remove_worktree(location.project.id, tree.directory, false, function(err) dirty_err, dirty_done = err, true end)
wait(function() return dirty_done end, "Dirty removal timeout")
assert(dirty_err and dirty_err.force_required and vim.fn.isdirectory(tree.directory) == 1, "Dirty worktree was removed without force")
await(function(cb) client.move_session(first.id, directory, cb) end)
await(function(cb) client.remove_worktree(location.project.id, tree.directory, true, cb) end)
assert(vim.fn.isdirectory(tree.directory) == 0, "Forced removal failed")
local moved_ids = {}
for _, message in ipairs(await(function(cb) client.get_messages(first.id, {}, cb) end)) do moved_ids[message.info.id] = true end
for _, message in ipairs(moved_history) do assert(moved_ids[message.info.id], "Move lost session history") end

-- Native VCS DTOs contain patches rather than reconstructed full files.
git({ "branch", "parity-base" })
vim.fn.writefile({ "committed change" }, directory .. "/counter.txt")
git({ "add", "counter.txt" }); git({ "-c", "user.name=OpenCode Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "Parity change" })
vim.fn.writefile({ "working change" }, directory .. "/counter.txt")
local branches = await(function(cb) client.list_vcs_branches({ directory = directory }, cb) end)
assert(#branches >= 2, "VCS branches unavailable")
for _, mode in ipairs({ "branch", "committed", "working" }) do
	local files = await(function(cb) client.get_vcs_diff({ directory = directory, mode = mode, base = "parity-base" }, cb) end)
	assert(require("opencode.vcs").files(files) and #files == 1 and files[1].patch:find("@@", 1, true), "Invalid native VCS " .. mode)
end

-- A session environment replaces the server shell environment.
await(function(cb) client.set_session_environment(second.id, { PATH = "/usr/bin:/bin", PARITY_ENV = "native-env" }, cb) end)
await(function(cb) client.run_session_shell(second.id, "printf '%s' \"$PARITY_ENV\"", cb) end)
local env_history = await(function(cb) client.get_messages(second.id, {}, cb) end)
local env_output = false
for _, message in ipairs(env_history) do
	local result = message.info.output
	if type(result) == "table" and result.output == "native-env" then env_output = true end
end
assert(env_output, "Native environment replacement missing")

-- Persistent terminal input, control resize, detach and byte-cursor replay.
local terminal = await(function(cb) client.create_terminal(second.id, { command = "/bin/sh", args = {}, title = "Parity PTY", env = {}, size = { cols = 80, rows = 24 } }, cb) end)
local terminal_list = await(function(cb) client.list_terminals(second.id, cb) end)
assert(vim.tbl_contains(vim.tbl_map(function(item) return item.id end, terminal_list), terminal.id))
local output, pty_err, resized, handle = "", nil, false
local function attach(cursor, name)
	return assert(actions.connect_terminal({ id = terminal.id, session_id = second.id, directory = other,
		attachment_id = name, cursor = cursor,
		on_data = function(data) output = output .. data end,
		on_event = function(event) if event.type == "resized" then resized = true end end,
		on_error = function(err) pty_err = err end }))
end
handle = attach(0, "parity-first")
wait(function() return handle.is_ready() or pty_err end, "PTY attachment timeout"); assert(not pty_err, vim.inspect(pty_err))
assert(handle.control(100, 30)); wait(function() return resized or pty_err end, "PTY resize timeout")
assert(handle.input("printf 'native-pty-output\\n'\n", 100, 30))
wait(function() return output:find("native-pty-output\r\n", 1, true) or pty_err end, "PTY output timeout"); assert(not pty_err, vim.inspect(pty_err))
local cursor = handle.cursor(); handle.close()
local info = await(function(cb) client.get_terminal(terminal.id, cb) end)
assert(info.status == "running" and info.size.cols == 100 and info.size.rows == 30, "Detach killed terminal or resize was lost")
local snapshot = await(function(cb) client.get_terminal_snapshot(terminal.id, cb) end)
assert(snapshot.info.id == terminal.id and type(snapshot.checkpoint) == "string")
output = ""; handle = attach(cursor, "parity-second")
wait(function() return handle.is_ready() or pty_err end, "PTY reconnect timeout")
assert(not pty_err and not output:find("native-pty-output", 1, true), "PTY replay duplicated consumed output")
assert(handle.input("printf 'after-detach\\n'\n", 100, 30))
wait(function() return output:find("after-detach\r\n", 1, true) or pty_err end, "PTY reconnect output missing")
assert(not pty_err, vim.inspect(pty_err)); handle.close()
await(function(cb) client.remove_terminal(terminal.id, cb) end)

-- Two independently targeted shell processes; one kill must leave the other running.
local shell_requests, shell_errors = 0, {}
local function shell_done(err)
	shell_requests = shell_requests + 1
	if err then shell_errors[#shell_errors + 1] = err end
end
client.run_session_shell(second.id, "printf 'native-shell-привет\\n'; sleep 60", shell_done)
client.run_session_shell(second.id, "printf 'other-shell\\n'; sleep 60", shell_done)
local shells
wait(function()
	local done
	client.list_shells({ directory = other }, function(err, data)
		if not err then
			shells = vim.tbl_filter(function(entry)
				return entry.status == "running" and entry.command:find("sleep 60", 1, true) ~= nil
			end, data)
		end
		done = true
	end)
	vim.wait(1000, function() return done end, 10)
	return shells and #shells >= 2
end, "Shell processes unavailable")
local target, survivor = shells[1], shells[2]
local shell_output
wait(function()
	shell_output = await(function(cb) client.get_shell_output(target.id, { directory = other, cursor = 0 }, cb) end)
	return type(shell_output.output) == "string" and shell_output.cursor > 0
end, "Native shell output missing")
await(function(cb) client.remove_shell(target.id, { directory = other }, cb) end)
local alive = await(function(cb) client.get_shell(survivor.id, { directory = other }, cb) end)
assert(alive.status == "running", "Targeted kill stopped the other shell")
await(function(cb) client.remove_shell(survivor.id, { directory = other }, cb) end)
wait(function() return shell_requests == 2 end, "Shell requests did not settle after targeted termination")
assert(#shell_errors == 0, vim.inspect(shell_errors))

-- Suspend only this runner's server. The frontend must reconnect by itself.
local sse = require("opencode.client.sse")
sse.setup({ read_idle_timeout = 1000, connect_timeout = 500, reconnect_delay = 100, max_reconnect_delay = 200 })
local connections, max_attempts, resumed = 0, 0, false
client.on_event("server.connected", function() connections = connections + 1 end)
local function signal(name)
	vim.fn.system({ "/bin/kill", "-" .. name, tostring(server.pid) }); assert(vim.v.shell_error == 0, "Server signal failed")
end
signal("STOP")
local timer = vim.defer_fn(function() signal("CONT"); resumed = true end, 10000)
local ok, failure = xpcall(function()
	wait(function() return not state.is_connected() end, "Read-idle watchdog did not drop frozen server", 5000)
	wait(function()
		max_attempts = math.max(max_attempts, sse.status().reconnect_count)
		return resumed and connections > 0 and state.is_connected()
	end, "Automatic SSE recovery failed", 20000)
	assert(max_attempts > 5, "Outage did not exceed the former retry budget")
end, debug.traceback)
pcall(signal, "CONT"); pcall(timer.stop, timer); pcall(timer.close, timer)
assert(ok, failure)
local recovered = await(function(cb) client.get_session(second.id, cb) end)
assert(recovered.title == "Renamed remote" and state.get_session().id == second.id, "Recovery changed session metadata")
local completed = await(function(cb) client.get_session(first.id, cb) end)
assert(type(completed.time.idle) == "number", "Completed shell did not produce a native idle watermark")
await(function(cb) client.view_session(first.id, completed.time.idle, cb) end)
local acknowledged = await(function(cb) client.get_session(first.id, cb) end)
assert(acknowledged.time.viewed == completed.time.idle, "Native view acknowledgement missing")
await(function(cb) client.delete_session(first.id, cb) end); await(function(cb) client.delete_session(second.id, cb) end)
vim.fn.writefile({ vim.json.encode({ version = server.version, cross_project_open = true, native_rename = true,
	view_without_idle_ignored = true, native_view_acknowledgement = true, shell_output = true, targeted_kill = true, automatic_sse_recovery = true,
	reconnect_attempts = max_attempts, native_plugin_list = true, native_pairing = pairing ~= nil,
	native_worktree_crud = true, dirty_worktree_guard = true, session_move_execution = true, move_preserves_history = true,
	native_vcs_sources = true, session_environment = true, persistent_pty = true, pty_resize = true, pty_detach_replay = true,
	all_provider_use_denied = true, explicit_model_prompt_submitted = false, personal_provider_credentials_used = false }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
lifecycle.disconnect()
print("Native parity contracts and automatic recovery passed")
