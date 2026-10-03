-- opencode.nvim - Session palette commands

local M = {}

local actions = require("opencode.actions")
local session_util = require("opencode.util.session")
local state = require("opencode.state")
function M.register(palette)
	local keymaps = (state.get_config() or require("opencode.config").defaults).keymaps or {}
	palette.register({
		id = "session.timeline",
		title = "Timeline",
		description = "Choose a user turn to jump, copy, fork, or revert",
		category = "session",
		slash = { name = "timeline" },
		on_select = function(context) return context.run() end,
		run = function() require("opencode.ui.timeline").show() end,
		enabled = function() return state.get_session().id ~= nil end,
	})
	palette.register({ id = "session.history", title = "Load Full Session History", category = "session",
		description = "Fetch every history page", run = function()
			local sid = state.get_session().id
			if not sid then return end
			actions.load_session_messages(sid, { all = true }, function(err, messages)
				if not err then
					require("opencode.ui.chat.state").state.full_history_sessions[sid] = true
					require("opencode.ui.chat.render_coordinator").request({ session_id = sid, reason = "full_history" })
				end
				vim.notify(err and ("Could not load history: " .. err.message) or ("Loaded " .. #messages .. " messages"), err and vim.log.levels.ERROR or vim.log.levels.INFO)
			end)
		end })

	palette.register({
		id = "session.new",
		title = "New Session",
		description = "Create a new chat session",
		category = "session",
		keybind = "<leader>on",
		slash = { name = "new" },
		run = function()
			actions.new_session()
		end,
	})
	palette.register({
		id = "session.aside",
		title = "Ask a Side Question (/btw)",
		description = "Ask using session context without adding a chat turn",
		category = "session",
		slash = { name = "btw" },
		on_select = function(ctx) return ctx.run() end,
		enter_with_args = true,
		with_parts = "reject",
		parts_error = "/btw supports text questions only",
		run = function(ctx)
			local args = ctx and ctx.args
			if type(args) == "string" and vim.trim(args) ~= "" then
				actions.ask_btw(args)
				return
			end
			local session_id = state.get_session().id
			if not session_id then
				vim.notify("Open a session first", vim.log.levels.WARN)
				return
			end
			local pending = require("opencode.session.pending")
			local token = pending.token(session_id)
			require("opencode.ui.btw").prompt(function(question)
				if not pending.is_current(token) then return end
				actions.ask_btw(question, session_id)
			end)
		end,
	})
	palette.register({
		id = "session.active",
		title = "Active Sessions",
		description = "Show running, waiting, and recent sessions",
		category = "session",
		keybind = keymaps.active_sessions,
		run = function()
			actions.active_sessions()
		end,
	})
	palette.register({
		id = "session.close",
		title = "Close Session Tab",
		description = "Close the current active tab without deleting the session",
		category = "session",
		keybind = keymaps.close_session,
		slash = { name = "close", aliases = { "close-session", "close-tab" } },
		run = function()
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
		slash = { name = "sessions", aliases = { "resume", "continue" } },
		run = function()
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

				local menu = require("opencode.ui.menu")
				local current = state.get_session()
				local pending = require("opencode.session.pending")
				local token = pending.token()

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
					local msg_count = session.message_count or 0
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

				menu.open({
					items = items,
					title = " Switch Session ",
					width = 70,
					searchable = true,
					sort = function(a, b)
						-- Most recently updated first (matches TUI: toSorted((a,b) => b.time.updated - a.time.updated))
						return (a.sort_key or 0) > (b.sort_key or 0)
					end,
					on_select = function(item)
						if not pending.is_current(token) then return end
						local session = item.session
						actions.switch_session(session, {
							notify = true,
							reason = "session_switch",
						})
					end,
				})
			end)
		end,
	})
	palette.register({
		id = "session.fork",
		title = "Fork Session",
		description = "Fork full session or before a user turn",
		category = "session",
		keybind = "<leader>of",
		slash = { name = "fork" },
		on_select = function(context) return context.run() end,
		run = function()
			require("opencode.ui.timeline").show_fork_picker()
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.copy",
		title = "Copy Session Transcript",
		description = "Copy complete server transcript to clipboard",
		category = "session",
		slash = { name = "copy" },
		on_select = function(context) return context.run() end,
		run = function()
			require("opencode.ui.export").run({ action = "copy", format = "markdown", thinking = true, tools = true })
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	palette.register({
		id = "session.export",
		title = "Export Session Transcript",
		description = "Export complete history as Markdown or JSON",
		category = "session",
		slash = { name = "export" },
		on_select = function(context) return context.run() end,
		run = function() require("opencode.ui.export").show() end,
		enabled = function() return state.get_session().id ~= nil end,
	})
	palette.register({
		id = "session.copy_raw",
		title = "Copy Raw Session Object",
		description = "Copy complete server session export as JSON",
		category = "session",
		run = function()
			require("opencode.ui.export").run({ action = "copy", format = "json", sanitize = false })
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
		run = function()
			local session = state.get_session()
			if not session.id then
				vim.notify("No active session", vim.log.levels.WARN)
				return
			end

			local prompt = "Delete session '" .. (session_util.displayTitle(session.name) or session.id) .. "'?"
			local pending = require("opencode.session.pending")
			local token = pending.token(session.id)
			require("opencode.ui.menu").open({
				items = { "Yes", "No" },
				title = "Delete Session",
				message = prompt,
				width = vim.fn.strdisplaywidth(prompt) + 12,
				sort = false,
				on_select = function(choice)
					if choice == "Yes" and pending.is_current(token) then
						actions.delete_session(session.id, function(err)
							if err then
								vim.notify(
									"Failed to delete session: " .. tostring(err.message or err),
									vim.log.levels.ERROR
								)
								return
							end
							vim.notify("Session deleted", vim.log.levels.INFO)
						end)
					end
				end,
			})
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
end

return M
