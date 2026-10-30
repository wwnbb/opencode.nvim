local cs = require("opencode.ui.chat.state")
return cs.factory("message_renderer", function(view)
local M = {}

local NuiLine = require("nui.line")
local NuiText = require("nui.text")

local state = view
local render = cs.module(view, require("opencode.ui.chat.render"))
local sync = require("opencode.sync")
local app_state = require("opencode.state")
local local_state = require("opencode.local")
local activity = cs.module(view, require("opencode.ui.chat.activity"))
local spinner = require("opencode.ui.spinner")
local processing_footer = require("opencode.ui.chat.processing_footer")
local history_metadata = require("opencode.ui.chat.history_metadata")
local widget_renderer = cs.module(view, require("opencode.ui.chat.widget_renderer"))
local tool_renderer = cs.module(view, require("opencode.ui.chat.tool_renderer"))
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))
local tree = require("opencode.ui.chat.widget_tree")

require("opencode.ui.highlights").register("opencode.ui.chat.welcome", function()
	vim.api.nvim_set_hl(0, "OpenCodeWelcomeTitle", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeWelcomeHint", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeWelcomeKey", { link = "Special", default = true })
end)

local EDIT_WIDGET_TOOL_ROWS = {
	write = true,
	edit = true,
	patch = true,
	apply_patch = true,
	neovim_edit = true,
	neovim_patch = true,
}

local session_title = {}
-- nvim_set_hl redraws every window: write only when Title or the group changed.
local function ensure_session_title_highlight()
	local ok, title_hl = pcall(vim.api.nvim_get_hl, 0, { name = "Title", link = false })
	local opts = { bold = true }
	if ok and type(title_hl) == "table" then
		opts = vim.tbl_extend("force", title_hl, opts)
	end
	local get = function() return vim.api.nvim_get_hl(0, { name = "OpenCodeSessionTitle" }) end
	if vim.deep_equal(session_title.opts, opts) and vim.deep_equal(session_title.written, get()) then
		return
	end
	vim.api.nvim_set_hl(0, "OpenCodeSessionTitle", opts)
	session_title.opts, session_title.written = opts, get()
end

local function render_session_chrome(ctx)
	if #state.session_stack > 0 then
		local bc_line = NuiLine()
		for i, entry in ipairs(state.session_stack) do
			if i > 1 then
				bc_line:append(NuiText(" > ", "Comment"))
			end
			bc_line:append(NuiText(entry.name, "Comment"))
		end
		bc_line:append(NuiText(" > ", "Comment"))
		bc_line:append(NuiText(ctx.current_session.name or "Subagent", "Special"))
		ctx:add_line(bc_line)

		local keymaps = require("opencode.util.keymap")
		local back = keymaps.hint({ { keymaps.label("chat", "leave_subagent", (ctx.chat_config or {}).keymaps), "Go back" } })
		if back then
			local hint_line = NuiLine()
			hint_line:append(NuiText(back, "Comment"))
			ctx:add_line(hint_line)
		end
		ctx:add_raw_line("")
	end

	local tabs_cfg = (ctx.chat_config or {}).session_tabs or {}
	if tabs_cfg.enabled == false or ctx.in_child_session_view then
		ensure_session_title_highlight()
		local header = NuiLine()
		header:append(NuiText(ctx.current_session.name or "New session", "OpenCodeSessionTitle"))
		ctx:add_line(header)
		ctx:add_raw_line("")
	end
end

local function select_messages(ctx, index)
	local all_messages = ctx.current_session.id and sync.get_messages(ctx.current_session.id) or {}
	local record = app_state.get_session_record(ctx.current_session.id)
	local revert = record and record.revert
	if type(revert) == "table" then
		for i, message in ipairs(all_messages) do
			if message.id == revert.messageID then
				local visible = vim.list_slice(all_messages, 1, i - 1)
				for j = i + 1, #all_messages do
					if all_messages[j].provisional then visible[#visible + 1] = all_messages[j] end
				end
				all_messages = visible
				break
			end
		end
		ctx:begin_block("revert")
		ctx:add_raw_line("Undo staged · /redo restores the turn")
		ctx:add_raw_line("")
	end
	-- Inbox echoes are not conversation history yet. Keep them below all
	-- output, independently of their timestamps and the history render limit.
	local history_messages, pending_messages = {}, {}
	for _, message in ipairs(all_messages) do
		local target = message.role == "user" and message.provisional and pending_messages or history_messages
		target[#target + 1] = message
	end
	all_messages = history_messages
	local messages = all_messages
	local max_rendered_messages = (state.full_history_sessions or {})[ctx.current_session.id] and 0
		or tonumber((ctx.chat_config or {}).max_rendered_messages) or 0
	local skipped_messages = 0

	if max_rendered_messages > 0 and #all_messages > max_rendered_messages then
		local first_render_index = #all_messages - max_rendered_messages + 1
		local message_index_by_id = {}
		for msg_index, message in ipairs(all_messages) do
			if message.id then
				message_index_by_id[message.id] = msg_index
			end
		end

		local function anchor_message(message_id, owner_session_id, status)
			local message_index = message_id and message_index_by_id[message_id]
			if message_index and index:should_render_session_widget(owner_session_id, status) then
				first_render_index = math.min(first_render_index, message_index)
			end
		end

		for _, qstate in ipairs(index.all_questions) do
			if qstate.status == "pending" or qstate.status == "confirming" then
				anchor_message(qstate.message_id, qstate.session_id, qstate.status)
			end
		end
		for _, pstate in ipairs(index.all_permissions) do
			if pstate.status == nil or pstate.status == "pending" then
				anchor_message(pstate.message_id, pstate.session_id, pstate.status)
			end
		end
		for _, estate in ipairs(index.all_edits) do
			if estate.status == nil or estate.status == "pending" then
				anchor_message(estate.message_id, estate.session_id, estate.status)
			end
		end

		skipped_messages = first_render_index - 1
		messages = {}
		for i = skipped_messages + 1, #all_messages do
			messages[#messages + 1] = all_messages[i]
		end
	end

	return all_messages, messages, skipped_messages, pending_messages, type(revert) == "table" and revert.messageID or nil
end

local function make_metadata_footer_renderer(ctx, all_messages, metadata)
	local function metadata_footer_duration(message)
		if not message or not message.time or type(message.time.completed) ~= "number" then
			return nil
		end
		local parent_created = message.parentID and metadata.created(message.parentID)
		if type(parent_created) ~= "number" then
			return nil
		end
		return message.time.completed - parent_created
	end

	return function(message, spinner_frame, message_revision)
		local duration_ms = metadata_footer_duration(message)
		local tokens_per_second = message and message.id and metadata.rate(message.id) or nil
		local turn = message and message.id and metadata.turn(message.id) or nil
		local cache_key = message
			and message.id
			and ctx:render_cache_key(
				"metadata_footer",
				ctx.current_session.id,
				message.id,
				message_revision or 0,
				ctx.metadata_provider_revision,
				ctx.metadata_agent_revision,
				duration_ms or "",
				tokens_per_second or "",
				turn and table.concat({ turn.steps, turn.new, turn.cached, turn.total, tostring(turn.complete) }, ":") or "",
				spinner_frame or "",
				ctx.verbosity
			)
		if cache_key then
			-- The key is also the footer row's block signature (see add_footer_rows).
			return ctx:cached_nui_line(cache_key, function()
				return render.render_metadata_footer(message, all_messages, {
					spinner_frame = spinner_frame,
					duration_ms = duration_ms,
					duration_calculated = true,
					tokens_per_second = tokens_per_second,
					turn_usage = turn,
					verbosity = ctx.verbosity,
				})
			end, ctx:render_owner_key("metadata_footer", message.id)), cache_key
		end

		return render.render_metadata_footer(message, all_messages, {
			spinner_frame = spinner_frame,
			duration_ms = duration_ms,
			duration_calculated = true,
			tokens_per_second = tokens_per_second,
			turn_usage = turn,
			verbosity = ctx.verbosity,
		})
	end
end

local function add_token_breakdown(ctx, message)
	local turn = message and message.id and ctx.history_metadata.turn(message.id) or nil
	local lines = render.render_token_breakdown(message, turn, { verbosity = ctx.verbosity })
	ctx:add_nui_lines(lines)
	return #lines
end

---Metadata footer row, token breakdown and closing blank of a footer or
---processing block. The footer key covers the message revision, turn usage
---and verbosity; the breakdown also wraps to the chat width.
local function add_footer_rows(ctx, footer_line, cache_key, message)
	ctx:add_line(footer_line)
	local breakdown = add_token_breakdown(ctx, message)
	ctx:add_raw_line("")
	if cache_key then
		ctx:sign_block(breakdown == 0 and cache_key or ctx:render_cache_key(cache_key, ctx.chat_width))
	end
end

local function get_current_session_status(ctx)
	if ctx.current_session.id then
		local state_status = app_state.get_session_status(ctx.current_session.id)
		-- The state store is normally mirrored from session.execution SSE
		-- event as sync. During an SSE/hydration race it may briefly still be
		-- idle while sync already has the server's busy status. Do not lose the
		-- processing footer in that window: a busy sync status is sufficient to
		-- keep the active session visibly animated.
		if processing_footer.is_processing(state_status) then
			return state_status
		end

		local sync_status = sync.get_session_status(ctx.current_session.id)
		if processing_footer.is_processing(sync_status) then
			return sync_status
		end

		return state_status
	end
	return view.session_bound and "idle" or app_state.get_status()
end

local function find_last_assistant(messages)
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" then
			return i, messages[i]
		end
	end
	return nil, nil
end

local function render_hidden_history_notice(ctx, skipped_messages)
	if skipped_messages <= 0 then
		return
	end
	ctx:begin_block("hidden_history")
	local history_line = NuiLine()
	history_line:append(NuiText(string.format("... %d earlier messages hidden · use Load Full Session History in the palette", skipped_messages), "Comment"))
	ctx:add_line(history_line)
	ctx:add_raw_line("")
end

local function register_message_range(message, start_line, end_line, source)
	if type(message) ~= "table" or not message.role then
		return
	end
	if type(start_line) ~= "number" or type(end_line) ~= "number" or end_line < start_line then
		return
	end

	table.insert(state.message_positions, widget_support.mark_render_generation({
		id = message.id,
		role = message.role,
		agent = message.agent or message.mode,
		kind = message.kind,
		source = source or "message",
		start_line = start_line,
		end_line = end_line,
	}))
end

local function render_retry_status_if_needed(ctx, messages, msg_idx)
	local session_status = ctx.current_session.id and sync.get_session_status(ctx.current_session.id)
	if not session_status or session_status.type ~= "retry" then
		return
	end

	local is_last_user = true
	for j = msg_idx + 1, #messages do
		if messages[j].role == "user" then
			is_last_user = false
			break
		end
	end
	if not is_last_user then
		return
	end

	local retry_msg = require("opencode.util.text").truncate(session_status.message or "Retrying…", 80, "…")
	local attempt = session_status.attempt or 0
	local retry_info = ""
	if session_status.next then
		local wait_ms = math.max(0, math.floor((session_status.next - os.time() * 1000) / 1000) * 1000)
		if wait_ms > 0 then
			retry_info = string.format(" [retrying in %s · attempt #%d]", require("opencode.util.locale").duration(wait_ms), attempt)
		else
			retry_info = string.format(" [retrying · attempt #%d]", attempt)
		end
	else
		retry_info = string.format(" [attempt #%d]", attempt)
	end

	local status_line = NuiLine()
	status_line:append(NuiText(retry_msg .. retry_info, "ErrorMsg"))
	ctx:add_line(status_line)
	ctx:unsign_block()
end

local function render_user_message(ctx, message, render_parts, msg_idx, messages, max_user_message_lines)
	local start_line = ctx:line_count()
	local agent = message.agent or local_state.message_agent.get(ctx.current_session.id, message.id)
		or ctx.history_metadata.agent(message.id) or "unknown"
	local file_parts, attachment_parts = {}, {}
	for _, part in ipairs(render_parts.parts or {}) do
		if part._editor_context then
			attachment_parts[#attachment_parts + 1] = part
		elseif not part.synthetic then
			if part.type == "skill" then
				attachment_parts[#attachment_parts + 1] = part
			elseif part.type == "file" or part.type == "agent" then
				file_parts[#file_parts + 1] = part
			end
		end
	end

	local cache_key = ctx:render_cache_key(
		"user",
		ctx.current_session.id,
		message.id,
		render_parts.message_revision,
		ctx.chat_width,
		agent or "",
		ctx.metadata_agent_revision,
		max_user_message_lines
	)
	ctx:begin_block("user", message.id, cache_key)
	local msg_lines = ctx:cached_nui_lines(
		cache_key,
		function()
			return render.render_user_message(render_parts.content, agent, file_parts, {
				max_lines = max_user_message_lines,
				highlight_code = ctx:code_highlighter(message.id),
			})
		end,
		ctx:render_owner_key("user", message.id)
	)
	ctx:add_nui_lines(msg_lines)
	local prompt_status, pending_input = require("opencode.selectors").prompt_status(ctx.current_session.id, message.id)
	if prompt_status then
		local keymaps = require("opencode.util.keymap")
		local items = { { status = prompt_status } }
		if pending_input then
			local configured = keymaps.get("chat", (ctx.chat_config or {}).keymaps)
			for _, command in ipairs(cs.module(view, require("opencode.ui.chat.pending_inputs")).commands) do
				local action = command.name .. "_pending"
				if #keymaps.keys(configured[action]) > 0
					and (command.name ~= "steer" or pending_input.status == "queued")
					and (command.name ~= "queue" or pending_input.status == "accepted") then
					items[#items + 1] = { keymaps.label("chat", action, configured), command.name }
				end
			end
		end
		prompt_status = keymaps.hint(items)
		local status_line = NuiLine()
		status_line:append(NuiText(prompt_status, "Comment"))
		ctx:add_line(status_line)
		ctx:unsign_block()
	end
	if pending_input then
		state.pending_inputs[message.id] = widget_support.mark_render_generation({
			session_id = ctx.current_session.id,
			start_line = start_line,
			end_line = ctx:line_count() - 1,
		})
	end

	if not message.provisional then render_retry_status_if_needed(ctx, messages, msg_idx) end
	-- Keep queued-input actions scoped to the prompt and its status. Expandable
	-- attachment rows own their own ranges below that fixed block.
	for _, part in ipairs(attachment_parts) do
		tool_renderer.render_tool_part(ctx, part, render_parts.message_revision, render_parts.part_revisions)
	end
	ctx:add_raw_line("")
end

local function render_activity(ctx, group)
	local expanded = state.expanded_tools[group.id]
	local result = activity.render(group, expanded, state.expanded_tools)
	ctx:begin_block("activity", group.id)
	local base_line = ctx:add_render_result(result, "activity")
	state.tools[group.id] = widget_support.mark_render_generation({
		id = group.id,
		kind = "activity",
		start_line = base_line,
		end_line = base_line + #result.lines - 1,
		activity_group = group,
		children = tree.positions(result.children, base_line, state.render_generation),
		session_id = ctx.current_session.id,
		highlights = result.highlights,
	})
end

local function render_text_part(ctx, message, part, part_idx, render_parts, incomplete_assistant)
	-- Every text change bumps the part's own revision, including streamed deltas,
	-- so sibling tool updates must not re-render this part. Unidentified parts
	-- have no part revision and fall back to the message revision.
	local part_revision = part.id and render_parts.part_revisions[part.id]
	local cache_key = ctx:render_cache_key(
		"text",
		ctx.current_session.id,
		message.id,
		part.id or part_idx,
		part_revision or ("message:" .. tostring(render_parts.message_revision)),
		ctx.chat_width
	)
	local content_lines = ctx:cached_nui_lines(cache_key, function()
		return render.render_content(part.text, {
			highlight_code = ctx:code_highlighter(message.id, part.id or part_idx),
			streaming = incomplete_assistant,
		})
	end, ctx:render_owner_key("text", message.id, part.id or part_idx))
	if #content_lines == 0 then return end
	ctx:begin_block("text", part.id or (tostring(message.id) .. "#" .. part_idx), cache_key)
	-- TextPart has marginTop=1 even between adjacent text parts. Capture the
	-- streaming range after the separator, which belongs to the prior block.
	ctx:normalize_block_transition("non_tool")
	ctx:ensure_single_blank_separator()
	local content_start = ctx:line_count()
	ctx:add_nui_lines(content_lines)
	if incomplete_assistant and part.id then
		ctx:register_stream_block(message.id, part, "text", content_start)
	end
end

local function render_assistant_message(ctx, index, message, render_parts, opts)
	for part_idx, part in ipairs(render_parts.parts) do
		local group = opts.activities[part.id]
		if group then
			if group.first_part_id == part.id then render_activity(ctx, group) end
		elseif part.type == "reasoning" then
			-- Empty/redacted/disabled reasoning has no visible row.
		elseif part.type == "text" and part.text and part.text ~= "" then
			if part.shell_notification or part.subagent_notification or part.system_reminder then
				tool_renderer.render_tool_part(ctx, part, render_parts.message_revision, render_parts.part_revisions)
			else
				render_text_part(ctx, message, part, part_idx, render_parts, opts.incomplete_assistant)
			end
		elseif part.type == "tool" then
			local skip_tool_row = false
			if part.tool == "question" then
				skip_tool_row = index:has_question_widget_for_tool_call(message.id, part.callID)
			elseif EDIT_WIDGET_TOOL_ROWS[part.tool] then
				skip_tool_row = index:has_edit_widget_for_tool_call(message.id, part.callID)
			end
			if not skip_tool_row then
				tool_renderer.render_tool_part(ctx, part, render_parts.message_revision, render_parts.part_revisions)
			end
			widget_renderer.render_widgets_for_tool_call(ctx, index, message.id, part.callID,
				not skip_tool_row and part or nil)
			if part.tool == "task" then
				widget_renderer.render_child_session_widgets_for_task(ctx, index, part)
			end
		end
	end

	widget_renderer.render_widgets_for_message(ctx, index, message.id)
	if message.error_message then
		ctx:begin_block("error", message.id)
		widget_renderer.render_session_error_notice(ctx, { content = message.error_message })
	end

	if not opts.suppress_footer and render.should_show_footer(message, opts.is_last_assistant) then
		ctx:begin_block("footer", message.id)
		ctx:ensure_single_blank_separator()
		local footer_line, cache_key = opts.render_metadata_footer_line(message, nil, render_parts.message_revision)
		add_footer_rows(ctx, footer_line, cache_key, message)
	end
end

local function render_messages(
	ctx,
	index,
	messages,
	skipped_messages,
	render_metadata_footer_line,
	processing_presentation
)
	local last_assistant_idx = find_last_assistant(messages)
	local max_user_message_lines = tonumber((ctx.chat_config or {}).max_user_message_lines) or 0
	local activities = activity.collect(messages, function(id) return ctx:get_message_render_parts(id) end, function(message, part)
		return #index:items_for_tool_call(message.id, part.callID) > 0
			or #index:items_for_message(message.id) > 0
	end)

	render_hidden_history_notice(ctx, skipped_messages)

	for msg_idx, message in ipairs(messages) do
		local message_start_line = ctx:line_count()
		local render_parts = ctx:get_message_render_parts(
			message.id,
			message.role == "user" and { include_synthetic = false } or nil
		)
		local incomplete_assistant = message.role == "assistant" and not (message.time and message.time.completed)

		local has_content = render_parts.content and render_parts.content ~= ""
		local has_reasoning = render_parts.reasoning and render_parts.reasoning ~= ""
		local has_tools = #render_parts.tool_parts > 0
		local is_last_assistant = (msg_idx == last_assistant_idx)
		local should_render = not message.hidden and (message.role ~= "assistant"
			or has_content
			or has_reasoning
			or has_tools
			or message.error_message ~= nil)

		if should_render then
			if message.role == "user" then
				if ctx:line_count() > 0 then ctx:ensure_single_blank_separator() end
				message_start_line = ctx:line_count()
				render_user_message(ctx, message, render_parts, msg_idx, messages, max_user_message_lines)
			elseif message.type == "system" then
				-- System text is model-facing; only its description belongs in the chat.
				ctx:begin_block("system", message.id)
				ctx:ensure_single_blank_separator()
				message_start_line = ctx:line_count()
				local result = { lines = {}, highlights = {} }
				render.add_panel_line(result, message.description or "Instructions updated", "Comment", {
					prefix = " ◈ ", prefix_hl_group = "Comment",
				})
				local base_line = ctx:add_render_result(result, "non_tool")
				ctx:append_relative_highlights(result.highlights, base_line)
				ctx:add_raw_line("")
			else
				render_assistant_message(ctx, index, message, render_parts, {
					activities = activities,
					incomplete_assistant = incomplete_assistant,
					is_last_assistant = is_last_assistant,
					-- A new user turn may be waiting for its first assistant message.
					-- Its processing footer must not replace the previous turn's footer.
					suppress_footer = processing_presentation ~= nil
						and is_last_assistant
						and processing_presentation.source_message == message,
					render_metadata_footer_line = render_metadata_footer_line,
				})
			end
		end

		if should_render then
			register_message_range(message, message_start_line, ctx:line_count() - 1)
		end
	end

	return {
		max_user_message_lines = max_user_message_lines,
	}
end

local function make_server_user_echo_checker(ctx, all_messages)
	local server_user_echoes = nil

	local function ensure_server_user_echoes()
		if server_user_echoes then
			return server_user_echoes
		end
		server_user_echoes = {}
		for _, synced in ipairs(all_messages) do
			if synced.role == "user" then
				table.insert(server_user_echoes, {
					created = synced.time and synced.time.created,
					content = ctx:get_message_render_parts(synced.id, { include_synthetic = false }).content,
				})
			end
		end
		return server_user_echoes
	end

	return function(local_message)
		if local_message.role ~= "user" or type(local_message.content) ~= "string" then
			return false
		end
		local local_ms = (local_message.timestamp or 0) * 1000
		for _, synced in ipairs(ensure_server_user_echoes()) do
			local same_turn = not synced.created or local_ms == 0 or synced.created >= local_ms - 5000
			if same_turn and synced.content == local_message.content then
				return true
			end
		end
		return false
	end
end

local function render_local_notices(ctx, index, all_messages, max_user_message_lines)
	local has_server_user_echo = make_server_user_echo_checker(ctx, all_messages)

	for notice_index, message in ipairs(state.local_notices) do
		local message_start_line = ctx:line_count()
		if message.id and index:is_local_notice_rendered(message.id) then
			goto continue_local_message
		end
		if message.session_id and ctx.current_session.id and message.session_id ~= ctx.current_session.id then
			goto continue_local_message
		end
		if message.id and ctx.current_session.id then
			local sync_msg = sync.get_message(ctx.current_session.id, message.id)
			if sync_msg then
				goto continue_local_message
			end
		end

		if message.role == "user" then
			if message.optimistic then
				goto continue_local_message
			end
			if has_server_user_echo(message) then
				goto continue_local_message
			end
			ctx:begin_block("notice", message.id or ("#" .. notice_index))
			if ctx:line_count() > 0 then ctx:ensure_single_blank_separator() end
			message_start_line = ctx:line_count()
			local agent = message.agent or local_state.message_agent.get(ctx.current_session.id, message.id)
				or "unknown"
			local msg_lines = render.render_user_message(message.content or "", agent, nil, {
				max_lines = max_user_message_lines,
				highlight_code = ctx:code_highlighter(message.id),
			})
			ctx:add_nui_lines(msg_lines)
			ctx:add_raw_line("")
			register_message_range(message, message_start_line, ctx:line_count() - 1, "local_notice")
			goto continue_local_message
		end

		if message.content and message.content ~= "" then
			ctx:begin_block("notice", message.id or ("#" .. notice_index))
			if message.kind == "session_error" then
				widget_renderer.render_session_error_notice(ctx, message)
			else
				ctx:add_nui_lines(render.render_content(message.content))
			end
			ctx:add_raw_line("")
			register_message_range(message, message_start_line, ctx:line_count() - 1, "local_notice")
		end
		::continue_local_message::
	end
end

local function render_orphan_widgets(ctx, index, all_messages)
	local session_msg_ids = {}
	for _, message in ipairs(all_messages) do
		session_msg_ids[message.id] = true
	end

	widget_renderer.render_orphan_widgets(ctx, index, session_msg_ids)
end

local function build_fallback_metadata_message(ctx)
	local fallback_agent = "assistant"
	local fallback_model_id = nil
	local fallback_provider_id = nil
	local local_ok, local_state = pcall(require, "opencode.local")
	if local_ok then
		local selection = { session_id = ctx.current_session.id }
		local current_agent = local_state.agent.current(selection)
		local current_model = local_state.model.current(selection)
		if current_agent and current_agent.name then
			fallback_agent = current_agent.name
		end
		if current_model then
			fallback_model_id = current_model.modelID
			fallback_provider_id = current_model.providerID
		end
	end

	return {
		role = "assistant",
		agent = fallback_agent,
		mode = fallback_agent,
		modelID = fallback_model_id,
		providerID = fallback_provider_id,
	}
end

local function render_processing_footer(ctx, presentation, render_metadata_footer_line)
	if not presentation then
		return
	end
	ctx:begin_block("processing")
	local message = presentation.message
	local message_revision = nil
	if message and message.id then
		message_revision = ctx:get_message_render_parts(message.id).message_revision
	end
	ctx:ensure_single_blank_separator()
	local footer_line_idx = ctx:line_count()
	local spinner_frame = presentation.animated and spinner.get_frame() or nil
	local footer_line, cache_key = render_metadata_footer_line(message, spinner_frame, message_revision)
	-- The spinner row is patched in place between frames: leave it unsigned.
	add_footer_rows(ctx, footer_line, not presentation.animated and cache_key or nil, message)
	if presentation.animated then
		ctx:set_spinner_footer_line(footer_line_idx)
	end
end

local function render_empty_state(ctx, chrome_lines)
	if ctx:line_count() > chrome_lines then
		return
	end
	ctx:begin_block("empty")
	local keymaps = require("opencode.util.keymap")
	-- A row is { text, highlight, key prefix to emphasize }.
	local function key_row(action, description, hl)
		local key = keymaps.label("chat", action, ctx.chat_config.keymaps)
		local text = keymaps.hint({ { key, description } }, { join = "  " })
		return text and { text, hl, key }
	end
	local rows = {
		{ "OpenCode", "OpenCodeWelcomeTitle" },
		{ "What would you like to build?", "OpenCodeWelcomeHint" },
	}
	local focus = key_row("focus_input", "Start a conversation")
	if focus then
		vim.list_extend(rows, {
			{ "" },
			focus,
			{ "" },
			key_row("command_palette", "Command palette", "OpenCodeWelcomeHint"),
			key_row("help", "Help & shortcuts", "OpenCodeWelcomeHint"),
		})
	end
	local lines = {}
	for _, row in ipairs(rows) do
		for _, chunk in ipairs(render.wrap_text_with_ranges(row[1], ctx.chat_width)) do
			local line = NuiLine()
			local padding = math.max(0, math.floor((ctx.chat_width - vim.fn.strdisplaywidth(chunk.text)) / 2))
			line:append(chunk.text == "" and "" or string.rep(" ", padding))
			local key_end = math.max(0, math.min(#chunk.text, #(row[3] or "") - chunk.byte_start))
			if key_end > 0 then
				line:append(NuiText(chunk.text:sub(1, key_end), "OpenCodeWelcomeKey"))
			end
			line:append(NuiText(chunk.text:sub(key_end + 1), row[2]))
			lines[#lines + 1] = line
		end
	end
	local height = state.winid and vim.api.nvim_win_is_valid(state.winid)
		and vim.api.nvim_win_get_height(state.winid) or 0
	local top = math.max(0, math.floor((height - chrome_lines - #lines - 1) / 3))
	for _ = 1, top do ctx:add_raw_line("") end
	ctx:add_nui_lines(lines)
	ctx:add_raw_line("")
end

function M.render(ctx, index)
	render_session_chrome(ctx)
	local chrome_lines = ctx:line_count()

	local all_messages, messages, skipped_messages, pending_messages, revert_message_id = select_messages(ctx, index)
	ctx.history_metadata = history_metadata.get(ctx.current_session.id, all_messages, revert_message_id, (ctx.chat_config or {}).tps)
	local render_metadata_footer_line = make_metadata_footer_renderer(ctx, all_messages, ctx.history_metadata)
	local processing_presentation = processing_footer.derive({
		status = get_current_session_status(ctx),
		messages = all_messages,
		waiting_for_interaction = index:has_pending_interaction(),
		fallback_message = build_fallback_metadata_message(ctx),
	})
	local message_stats = render_messages(
		ctx,
		index,
		messages,
		skipped_messages,
		render_metadata_footer_line,
		processing_presentation
	)

	render_local_notices(ctx, index, all_messages, message_stats.max_user_message_lines)
	render_orphan_widgets(ctx, index, all_messages)
	render_processing_footer(ctx, processing_presentation, render_metadata_footer_line)
	for msg_idx, message in ipairs(pending_messages) do
		if not message.hidden then
			if ctx:line_count() > 0 then ctx:ensure_single_blank_separator() end
			local start_line = ctx:line_count()
			local parts = ctx:get_message_render_parts(message.id, { include_synthetic = false })
			render_user_message(ctx, message, parts, msg_idx, pending_messages, message_stats.max_user_message_lines)
			register_message_range(message, start_line, ctx:line_count() - 1)
		end
	end

	render_empty_state(ctx, chrome_lines)

	return {
		all_messages = all_messages,
		rendered_messages = messages,
		skipped_messages = skipped_messages,
	}
end

return M

end)
