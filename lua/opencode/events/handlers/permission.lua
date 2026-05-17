local M = {}

local util = require("opencode.events.util")
local auto_approve = require("opencode.permission.danger")

function M.setup(events)
	-- Handle tool updates - specifically edit_file tools to show approval widget
	events.on("tool_update", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local tool_name = data.tool_name or ""
			local status = data.status or ""

			local logger = require("opencode.logger")
			logger.debug("tool_update event", {
				tool = tool_name,
				status = status,
				data = data,
			})

			-- Custom tools are handled via the permission system via native diff review
			if tool_name == "neovim_edit" or tool_name == "neovim_apply_patch" then
				return
			end

			-- Check if this is an edit tool that needs approval
			local is_edit_tool = tool_name == "edit_file"
				or tool_name == "Edit"
				or tool_name == "edit"
				or tool_name == "write_file"
				or tool_name == "Write"
				or tool_name == "apply_patch"
				or tool_name:match("edit")
				or tool_name:match("Edit")
				or tool_name:match("patch")

			-- Show diff for edit tools that are pending or running (before completion)
			-- Status might be: pending, running, completed, error
			local needs_approval = status == "pending" or status == "running" or status == ""

			if is_edit_tool and needs_approval then
				logger.info("Edit tool detected, showing diff", { tool = tool_name })
				-- Tool is pending approval - try to extract file info and show diff
				local input = data.input

				if type(input) == "string" then
					-- Try to parse JSON input
					local ok, parsed = pcall(vim.json.decode, input)
					if ok then
						input = parsed
					end
				end

				if type(input) == "table" then
					local filepath = input.file_path or input.filepath or input.path or input.file
					local new_content = input.new_string or input.content or input.modified or ""
					local old_string = input.old_string or ""

					if filepath then
						-- Read original content
						local original_content = ""
						if vim.fn.filereadable(filepath) == 1 then
							local file = io.open(filepath, "r")
							if file then
								original_content = file:read("*all")
								file:close()
							end
						end

						-- If old_string/new_string pattern (patch-style), reconstruct content
						local modified_content = new_content
						if old_string ~= "" and new_content ~= "" then
							-- This is a replacement operation
							modified_content = original_content:gsub(vim.pesc(old_string), new_content, 1)
						elseif new_content == "" and input.new_string then
							modified_content = original_content:gsub(vim.pesc(old_string), input.new_string, 1)
						end

						if modified_content ~= "" and modified_content ~= original_content then
							-- Add to changes and show diff viewer
							local changes = require("opencode.artifact.changes")
							local change_id = changes.add_change(filepath, original_content, modified_content, {
								metadata = {
									source = "tool_call",
									tool_name = tool_name,
									call_id = data.call_id,
									message_id = data.message_id,
								},
							})
						end
					end
				end
			end
		end)
	end)

	-- Handle permission requests from server
	events.on("permission", function(data)
		vim.schedule(function()
			if not data then
				return
			end

				local logger = require("opencode.logger")
				logger.debug("Permission event received", { data = data })

				-- Show permission notification
				local permission_type = data.permission or data.type
				local metadata = data.metadata or {}
				local current_session = require("opencode.state").get_session()
				local message_id = util.resolve_event_message_id(data)
				local call_id = util.resolve_event_call_id(data)
				local timestamp = util.event_time_to_seconds(data.time and data.time.created)

				local is_native_diff_permission = metadata.opencode_native_diff == true
					or permission_type == "diff_review"
					or permission_type == "neovim_edit"
					or permission_type == "neovim_apply_patch"

				-- Guard: only handle edit/native-diff permissions that belong to the
				-- current session or to a task child session owned by it. Subagent
				-- tool calls run in child sessions, so filtering strictly by the
				-- current session leaves the backend waiting for an edit approval
				-- that the UI never renders.
				if is_native_diff_permission or permission_type == "edit" then
					-- Try to resolve the owning session from the most-reliable source first:
					-- the message ID via the sync store (populated only for the active session),
					-- then the raw sessionID field on the event payload / metadata.
					local event_session_id = nil

					if message_id then
						local ok_sync, sync_mod = pcall(require, "opencode.sync")
						if ok_sync and sync_mod.find_message_session_id then
							event_session_id = sync_mod.find_message_session_id(message_id)
						end
					end

					if not event_session_id or event_session_id == "" then
						event_session_id = data.sessionID
							or data.session_id
							or data.sessionId
							or metadata.sessionID
							or metadata.session_id
							or metadata.sessionId
					end

					-- If we successfully resolved a session and it belongs neither to
					-- the selected chat nor to any root session started in this editor
					-- run, skip it as unrelated backend history.
					local is_relevant = util.permission_session_is_relevant(current_session.id, event_session_id)
						or util.runtime_root_for_session(event_session_id) ~= nil
					if not is_relevant then
						local logger_g = require("opencode.logger")
						logger_g.debug("edit permission belongs to an unrelated session, skipping", {
							event_session = event_session_id,
							current_session = current_session.id,
							permission_type = permission_type,
						})
						return
					end
				end

				---@param session_hint table
				---@param event_data table
				---@param event_metadata table
				---@param source_message_id string|nil
				---@return string
				local function resolve_widget_session_id(session_hint, event_data, event_metadata, source_message_id)
					if source_message_id then
						local ok_sync, sync_mod = pcall(require, "opencode.sync")
						if ok_sync and sync_mod.find_message_session_id then
							local msg_session = sync_mod.find_message_session_id(source_message_id)
							if msg_session and msg_session ~= "" then
								return msg_session
							end
						end
					end

					local fallback_session = event_data.sessionID
						or event_data.session_id
						or event_data.sessionId
						or event_metadata.sessionID
						or event_metadata.session_id
						or event_metadata.sessionId
					if fallback_session and fallback_session ~= "" then
						return fallback_session
					end

					return (session_hint and session_hint.id) or ""
				end

				local permission_id = data.id or data.requestID or ("perm_" .. os.time())
				local permission_session_id = resolve_widget_session_id(current_session, data, metadata, message_id)
				if require("opencode.state").is_danger_mode_enabled() then
					local handled = auto_approve.approve(permission_id, {
						permission_type = permission_type,
						session_id = permission_session_id,
						kind = (is_native_diff_permission or permission_type == "edit") and "edit" or "permission",
					})
					if handled then
						return
					end
				end

				---@param ... any
				---@return string|nil
				local function first_non_empty(...)
					for i = 1, select("#", ...) do
						local value = select(i, ...)
						if type(value) == "string" and value ~= "" then
							return value
						end
					end
					return nil
				end

				---@param diff_text any
				---@return number, number
				local function calc_diff_stats(diff_text)
					if type(diff_text) ~= "string" or diff_text == "" then
						return 0, 0
					end

					local additions = 0
					local deletions = 0
					for _, line in ipairs(vim.split(diff_text, "\n", { plain = true })) do
						if line:sub(1, 3) ~= "+++" and line:sub(1, 1) == "+" then
							additions = additions + 1
						elseif line:sub(1, 3) ~= "---" and line:sub(1, 1) == "-" then
							deletions = deletions + 1
						end
					end

					return additions, deletions
				end

				---@param patterns any
				---@return string|nil
				local function extract_pattern_path(patterns)
					if type(patterns) ~= "table" then
						return nil
					end

					if vim.tbl_islist(patterns) then
						for _, item in ipairs(patterns) do
							if type(item) == "string" and item ~= "" then
								return item
							end
							if type(item) == "table" then
								local nested = first_non_empty(
									item.path,
									item.filepath,
									item.file_path,
									item.file,
									item.pattern
								)
								if nested then
									return nested
								end
							end
						end
						return nil
					end

					return first_non_empty(
						patterns.path,
						patterns.filepath,
						patterns.file_path,
						patterns.file,
						patterns.pattern
					)
				end

				---@param raw_files any
				---@return table
				local function normalize_edit_files(raw_files)
					if type(raw_files) ~= "table" then
						return {}
					end
					if vim.tbl_islist(raw_files) then
						return raw_files
					end
					return { raw_files }
				end

				---@param event_data table
				---@param event_metadata table
				---@return table
				local function synthesize_edit_files(event_data, event_metadata)
					local path = first_non_empty(
						event_metadata.filepath,
						event_metadata.file_path,
						event_metadata.file,
						event_metadata.path,
						event_data.filepath,
						event_data.file_path,
						event_data.file,
						event_data.path,
						event_metadata.pattern,
						event_data.pattern,
						extract_pattern_path(event_metadata.patterns),
						extract_pattern_path(event_data.patterns)
					) or "(pending edit)"

					local before = event_metadata.before or event_data.before or ""
					local after = event_metadata.after or event_data.after or event_metadata.content or event_data.content or ""
					local diff = first_non_empty(event_metadata.diff, event_data.diff, event_metadata.patch, event_data.patch)
					local diff_additions, diff_deletions = calc_diff_stats(diff)

					return {
						{
							filePath = path,
							relativePath = vim.fn.fnamemodify(path, ":."),
							before = before,
							after = after,
							diff = diff,
							additions = event_metadata.additions or event_data.additions or diff_additions,
							deletions = event_metadata.deletions or event_data.deletions or diff_deletions,
							type = event_metadata.type or event_data.type or "update",
						},
					}
				end

				if is_native_diff_permission or permission_type == "edit" then
					local edit_state_mod = require("opencode.edit.state")

					-- Skip if already handled (dedup for duplicate SSE events)
					if edit_state_mod.get_edit(permission_id) then
						logger.debug("edit permission already handled, skipping", {
							id = permission_id,
							type = permission_type,
						})
						return
					end

					local nd_files = normalize_edit_files(metadata.files)
					if #nd_files == 0 then
						nd_files = synthesize_edit_files(data, metadata)
					end
					local edit_session_id = resolve_widget_session_id(current_session, data, metadata, message_id)
					local review_mode = "interactive"
					if permission_type == "edit" and not is_native_diff_permission then
						review_mode = "readonly"
					end

					edit_state_mod.add_edit(permission_id, edit_session_id, nd_files, {
						data = data,
						metadata = metadata,
						message_id = message_id,
						call_id = call_id,
						review_mode = review_mode,
						timestamp = timestamp,
					})
					events.emit("edit_pending", {
						permission_id = permission_id,
						file_count = #nd_files,
						session_id = edit_session_id,
						message_id = message_id,
						call_id = call_id,
					})
					events.emit("interaction_changed", {
						kind = "edit",
						action = "pending",
						id = permission_id,
						session_id = edit_session_id,
					})

					-- Stop spinner so user can interact
					local spinner_ok, perm_spinner = pcall(require, "opencode.ui.spinner")
					if spinner_ok and perm_spinner.is_active and perm_spinner.is_active() then
						perm_spinner.stop()
					end

					return
				else
					-- Non-edit permission: handle interactively via permission state + chat widget
					-- Resolve tool_input from sync store if tool info is available
					local tool_input = {}
					if message_id and call_id then
						local sync = require("opencode.sync")
						local parts = sync.get_parts(message_id)
						for _, part in ipairs(parts) do
							if part.callID == call_id and part.state and part.state.input then
								tool_input = part.state.input
								break
							end
						end
					end

					-- Fallback: extract input fields from metadata and top-level data fields
					if not next(tool_input) then
						tool_input = vim.tbl_deep_extend("force", {}, metadata.input or {}, {
							command = data.command or metadata.command,
							description = data.description or metadata.description,
							path = data.path or metadata.path or data.filepath or metadata.filepath,
							file_path = data.file_path or metadata.file_path or data.file or metadata.file or data.filepath
								or metadata.filepath,
							pattern = data.pattern or metadata.pattern,
							query = data.query or metadata.query,
							url = data.url or metadata.url,
							directory = data.directory or metadata.directory or data.parentDir or metadata.parentDir,
							subagent_type = data.subagent_type or metadata.subagent_type,
						})
					end

					-- Store permission state
					local perm_state_mod = require("opencode.permission.state")
					perm_state_mod.add_permission(permission_id, permission_session_id, permission_type, {
						metadata = metadata,
						patterns = data.patterns or {},
						always = data.always or {},
						tool_input = tool_input,
						message_id = message_id,
						call_id = call_id,
						timestamp = timestamp,
					})
					events.emit("permission_pending", {
						permission_id = permission_id,
						permission_type = permission_type,
						session_id = permission_session_id,
						message_id = message_id,
						call_id = call_id,
					})
					events.emit("interaction_changed", {
						kind = "permission",
						action = "pending",
						id = permission_id,
						session_id = permission_session_id,
					})

					-- Stop spinner so user can interact
					local spinner_ok2, perm_spinner = pcall(require, "opencode.ui.spinner")
					if spinner_ok2 and perm_spinner.is_active() then
						perm_spinner.stop()
						logger.debug("Stopped spinner for permission interaction")
					end

					logger.info("Permission request added", {
						permission_id = permission_id,
						type = permission_type,
					})
				end
		end)
	end)

	-- Handle file edit events - show approval widget with diff viewer
	events.on("edit", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local filepath = data.file or data.filepath
			local original_content = data.original or data.original_content or ""
			local modified_content = data.modified or data.modified_content or data.content or ""

			if not filepath then
				vim.notify("Edit event missing filepath", vim.log.levels.WARN)
				return
			end

			-- If no original content provided, try to read from file
			if original_content == "" and vim.fn.filereadable(filepath) == 1 then
				local file = io.open(filepath, "r")
				if file then
					original_content = file:read("*all")
					file:close()
				end
			end

			-- If no modified content, nothing to show
			if modified_content == "" then
				vim.notify("File edited: " .. filepath, vim.log.levels.INFO)
				return
			end

			-- Add change to the changes module
			local changes = require("opencode.artifact.changes")
			local change_id = changes.add_change(filepath, original_content, modified_content, {
				metadata = {
					source = "server",
					session_id = data.sessionID,
				},
			})

			if not change_id then
				vim.notify("Failed to create change record for: " .. filepath, vim.log.levels.ERROR)
			end
		end)
	end)

	-- Handle session.diff events (alternative edit format)
	events.on("session_diff", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			-- session.diff may contain multiple file changes
			local diffs = data.diffs or { data }

			for _, diff_data in ipairs(diffs) do
				local filepath = diff_data.file or diff_data.filepath
				local original = diff_data.original or ""
				local modified = diff_data.modified or diff_data.content or ""

				if filepath and modified ~= "" then
					-- Read original if not provided
					if original == "" and vim.fn.filereadable(filepath) == 1 then
						local file = io.open(filepath, "r")
						if file then
							original = file:read("*all")
							file:close()
						end
					end

					local changes = require("opencode.artifact.changes")
					local change_id = changes.add_change(filepath, original, modified, {
						metadata = {
							source = "session_diff",
							session_id = data.sessionID,
						},
					})
				end
			end
			end)
		end)

	local app_state = require("opencode.state")
	local logger = require("opencode.logger")

	-- Clear permissions and edits on session change unless the session boundary
	-- marks this as a cache-preserving navigation.
	events.on("session_change", function(data)
		if data and data.preserve_cache then
			return
		end
		auto_approve.clear()
		local perm_state_ok, perm_state = pcall(require, "opencode.permission.state")
		if perm_state_ok then
			local removed = perm_state.clear_all()
			for _, permission_id in ipairs(removed or {}) do
				events.emit("permission_removed", { permission_id = permission_id })
			end
		end
		local edit_state_ok, edit_state_mod = pcall(require, "opencode.edit.state")
		if edit_state_ok then
			local removed = edit_state_mod.clear_all()
			for _, permission_id in ipairs(removed or {}) do
				events.emit("edit_removed", { permission_id = permission_id })
			end
		end
	end)

	-- OpenCode clients treat permission.replied as the lifecycle event that resolves
	-- the active request. Keep local permission/edit widgets in step with the
	-- server even when the reply was sent by another UI or arrives before the
	-- HTTP callback completes.
	events.on("permission_replied", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local permission_id = data.requestID or data.permissionID or data.id
			if not permission_id or permission_id == "" then
				return
			end

			local reply = data.reply or data.response
			local changed = false

			local perm_state_ok, perm_state_mod = pcall(require, "opencode.permission.state")
			if perm_state_ok and perm_state_mod.has_permission and perm_state_mod.has_permission(permission_id) then
				if reply == "reject" then
					changed = perm_state_mod.mark_rejected(permission_id) or changed
					events.emit("permission_rejected", {
						permission_id = permission_id,
					})
				else
					changed = perm_state_mod.mark_approved(permission_id, reply == "always" and "always" or "once")
						or changed
					events.emit("permission_approved", {
						permission_id = permission_id,
						reply = reply == "always" and "always" or "once",
					})
				end
			end

			local edit_state_ok, edit_state_mod = pcall(require, "opencode.edit.state")
			if edit_state_ok and edit_state_mod.get_edit and edit_state_mod.get_edit(permission_id) then
				edit_state_mod.mark_sent(permission_id)
				changed = true
				events.emit("interaction_changed", {
					kind = "edit",
					action = "sent",
					id = permission_id,
					session_id = data.sessionID,
				})
			end

			if changed then
				local session = app_state.get_session()
				events.emit("interaction_changed", {
					kind = "permission",
					action = reply == "reject" and "rejected" or "approved",
					id = permission_id,
					session_id = data.sessionID or (session and session.id),
				})
				logger.debug("Permission reply handled", {
					permission_id = permission_id,
					reply = reply,
					sessionID = data.sessionID,
				})
			end
		end)
	end)
end

return M
