-- opencode.nvim - Session palette commands

local M = {}

local actions = require("opencode.actions")
local session_util = require("opencode.util.session")
local state = require("opencode.state")
local sync = require("opencode.sync")
function M.register(palette)
	palette.register({
		id = "session.new",
		title = "New Session",
		description = "Create a new chat session",
		category = "session",
		keybind = "<leader>on",
		action = function()
			actions.new_session()
		end,
	})
	palette.register({
		id = "session.active",
		title = "Active Sessions",
		description = "Show running, waiting, and recent sessions",
		category = "session",
		keybind = "<leader>oS",
		action = function()
			actions.active_sessions()
		end,
	})
	palette.register({
		id = "session.close",
		title = "Close Session Tab",
		description = "Close the current active tab without deleting the session",
		category = "session",
		keybind = "x",
		action = function()
			actions.close_session({ notify = true })
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.list",
		title = "Switch Session",
		description = "Switch to another session",
		category = "session",
		keybind = "<leader>os",
		action = function()
				local directory = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
				if vim.fs and vim.fs.normalize then
					directory = vim.fs.normalize(directory)
				end

				actions.list_sessions({ roots = true, directory = directory }, function(err, sessions)
						if err then
							vim.notify("Failed to list sessions: " .. tostring(err.message or err), vim.log.levels.ERROR)
							return
						end
							if not sessions or #sessions == 0 then
								vim.notify("No sessions found", vim.log.levels.INFO)
								return
						end

						local float = require("opencode.ui.float")
						local current = state.get_session()

						-- Sort sessions by update time (most recent first, like TUI)
						table.sort(sessions, function(a, b)
							local a_time = a.time and a.time.updated or 0
							local b_time = b.time and b.time.updated or 0
							return a_time > b_time
						end)

						-- Format relative time helper (timestamp is ms from JS Date.now())
						local function format_relative_time(timestamp)
							if not timestamp then
								return ""
							end
							-- Convert ms -> seconds for comparison with os.time()
							local ts_sec = math.floor(timestamp / 1000)
							local now = os.time()
							local diff = now - ts_sec
							if diff < 60 then
								return "just now"
							elseif diff < 3600 then
								return math.floor(diff / 60) .. "m ago"
							elseif diff < 7200 then
								return "1h ago"
							elseif diff < 86400 then
								return math.floor(diff / 3600) .. "h ago"
							elseif diff < 172800 then
								return "Yesterday"
							else
								return os.date("%b %d", ts_sec)
							end
						end

						-- Build items for searchable menu (same as model switch)
						local items = {}
						for _, session in ipairs(sessions) do
							local is_current = current.id == session.id
							local title = session_util.displayTitle(session.title) or "New session"
							local msg_count = session.messageCount or 0
							local time_str = format_relative_time(session.time and session.time.updated)
							local msg_str = msg_count > 0 and ("(" .. msg_count .. " msgs)") or ""
							local current_marker = is_current and "● " or "  "

							table.insert(items, {
								label = current_marker .. title .. " " .. msg_str,
								value = session.id,
								session = session,
								description = time_str,
								-- sort_key carries the ms timestamp for time-based ordering
								sort_key = session.time and session.time.updated or 0,
							})
						end

						-- Use searchable menu with time-based sort (most recent first, like TUI)
							float.create_searchable_menu(items, function(item)
								local session = item.session
								actions.switch_session(session, {
									notify = true,
									reason = "session_switch",
								})
						end, {
							title = " Switch Session ",
							width = 70,
							sort_fn = function(a, b)
								-- Most recently updated first (matches TUI: toSorted((a,b) => b.time.updated - a.time.updated))
								return (a.sort_key or 0) > (b.sort_key or 0)
							end,
							})
					end)
			end,
		})
	palette.register({
		id = "session.fork",
		title = "Fork Session",
		description = "Fork current session",
		category = "session",
		keybind = "<leader>of",
		action = function()
			local current = state.get_session()
			if not current.id then
				vim.notify("No active session to fork", vim.log.levels.WARN)
				return
			end

				actions.fork_session(current.id, {}, function(err, session)
						if err then
							vim.notify("Failed to fork session: " .. tostring(err.message or err), vim.log.levels.ERROR)
							return
						end
						actions.set_active_session(session.id, session.title or "Forked Session", {
							reason = "session_fork",
							preserve_cache = true,
						})
						vim.notify("Forked session: " .. (session_util.displayTitle(session.title) or session.id), vim.log.levels.INFO)
					end)
			end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.copy",
		title = "Copy Session Transcript",
		description = "Copy current session transcript to clipboard",
		category = "session",
		action = function()
			local session_id = state.get_session().id
			if not session_id then
				vim.notify("No active session", vim.log.levels.WARN)
				return
			end

			local sync = require("opencode.sync")
			local messages = sync.get_messages(session_id)
			if #messages == 0 then
				vim.notify("No messages to copy", vim.log.levels.INFO)
				return
			end

			local lines = { "Session: " .. session_id, "" }
			for _, message in ipairs(messages) do
				if message.role == "user" then
					table.insert(lines, "USER:")
				else
					table.insert(lines, "ASSISTANT:")
				end

				local text_parts = {}
				for _, part in ipairs(sync.get_parts(message.id) or {}) do
					if part.type == "text" and part.text and part.text ~= "" then
						table.insert(text_parts, part.text)
					end
				end

				if #text_parts > 0 then
					table.insert(lines, table.concat(text_parts, "\n"))
				else
					table.insert(lines, "[No text content]")
				end

				table.insert(lines, "")
			end

			local transcript = table.concat(lines, "\n")
			vim.fn.setreg("+", transcript)
			vim.fn.setreg("*", transcript)
			vim.notify("Session transcript copied to clipboard", vim.log.levels.INFO)
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.delete",
		title = "Delete Session",
		description = "Delete current session",
		category = "session",
		action = function()
			local session = state.get_session()
			if not session.id then
				vim.notify("No active session", vim.log.levels.WARN)
				return
			end

			vim.ui.select({ "Yes", "No" }, {
				prompt = "Delete session '" .. (session_util.displayTitle(session.name) or session.id) .. "'?",
			}, function(choice)
				if choice == "Yes" then
						actions.delete_session(session.id, function(err)
								if err then
									vim.notify("Failed to delete session: " .. tostring(err.message or err), vim.log.levels.ERROR)
									return
								end
								actions.set_active_session(nil, nil, {
									reason = "session_delete",
									preserve_cache = true,
								})
								actions.forget_session(session.id, {
									reason = "session_delete",
								})
								actions.clear_session_data(session.id)
								vim.notify("Session deleted", vim.log.levels.INFO)
							end)
					end
				end)
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.archive",
		title = "Archive Session",
		description = "Archive current session",
		category = "session",
		action = function()
			-- Note: This is a placeholder - actual archive functionality
			-- depends on server API support
			vim.notify("Archive session - not yet implemented in server API", vim.log.levels.WARN)
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
end

return M
