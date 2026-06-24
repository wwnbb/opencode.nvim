local M = {}

local NuiLine = require("nui.line")
local NuiText = require("nui.text")

local state = require("opencode.ui.chat.state").state
local render = require("opencode.ui.chat.render")
local sync = require("opencode.sync")
local app_state = require("opencode.state")
local thinking = require("opencode.ui.thinking")
local spinner = require("opencode.ui.spinner")
local widget_renderer = require("opencode.ui.chat.widget_renderer")
local tool_renderer = require("opencode.ui.chat.tool_renderer")
local widget_support = require("opencode.ui.chat.widget_support")

local EDIT_WIDGET_TOOL_ROWS = {
	write = true,
	edit = true,
	apply_patch = true,
	neovim_edit = true,
	neovim_apply_patch = true,
}

local function is_processing_status(status)
	local status_type = type(status) == "table" and status.type or status
	return status_type == "busy"
		or status_type == "streaming"
		or status_type == "thinking"
		or status_type == "retry"
end

local function ensure_session_title_highlight()
	local ok, title_hl = pcall(vim.api.nvim_get_hl, 0, { name = "Title", link = false })
	local opts = { bold = true }
	if ok and type(title_hl) == "table" then
		opts = vim.tbl_extend("force", title_hl, opts)
	end
	vim.api.nvim_set_hl(0, "OpenCodeSessionTitle", opts)
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

		local hint_line = NuiLine()
		hint_line:append(NuiText("<BS> Go back", "Comment"))
		ctx:add_line(hint_line)
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
	local messages = all_messages
	local max_rendered_messages = tonumber((ctx.chat_config or {}).max_rendered_messages) or 0
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

	return all_messages, messages, skipped_messages
end

local function build_user_created_by_id(all_messages)
	local user_created_by_id = {}
	for _, msg in ipairs(all_messages) do
		if msg.id and msg.role == "user" and msg.time and type(msg.time.created) == "number" then
			user_created_by_id[msg.id] = msg.time.created
		end
	end
	return user_created_by_id
end

local function make_metadata_footer_renderer(ctx, all_messages, user_created_by_id)
	local function metadata_footer_duration(message)
		if not message or not message.time or type(message.time.completed) ~= "number" then
			return nil
		end
		local parent_created = message.parentID and user_created_by_id[message.parentID]
		if type(parent_created) ~= "number" then
			return nil
		end
		return message.time.completed - parent_created
	end

	return function(message, spinner_frame, message_revision)
		local duration_ms = metadata_footer_duration(message)
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
				spinner_frame or ""
			)
		if cache_key then
			return ctx:cached_nui_line(cache_key, function()
				return render.render_metadata_footer(message, all_messages, {
					spinner_frame = spinner_frame,
					duration_ms = duration_ms,
					duration_calculated = true,
				})
			end)
		end

		return render.render_metadata_footer(message, all_messages, {
			spinner_frame = spinner_frame,
			duration_ms = duration_ms,
			duration_calculated = true,
		})
	end
end

local function get_current_session_processing(ctx)
	if ctx.current_session.id then
		return is_processing_status(app_state.get_session_status(ctx.current_session.id))
	end
	return is_processing_status(app_state.get_status())
end

local function find_last_assistant(messages)
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" then
			return i, messages[i]
		end
	end
	return nil, nil
end

local function should_activate_spinner(current_session_processing, messages, last_assistant)
	local last_message = messages[#messages]
	local last_assistant_completed = last_assistant and last_assistant.time and last_assistant.time.completed ~= nil
	local last_assistant_waiting_on_tools = last_assistant and last_assistant.finish == "tool-calls"
	local has_pending_response_gap = not last_message
		or last_message.role ~= "assistant"
		or not last_assistant_completed
		or last_assistant_waiting_on_tools
	return spinner.is_active() and current_session_processing and has_pending_response_gap
end

local function render_hidden_history_notice(ctx, skipped_messages)
	if skipped_messages <= 0 then
		return
	end
	local history_line = NuiLine()
	history_line:append(NuiText(string.format("... %d earlier messages hidden", skipped_messages), "Comment"))
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

	local retry_msg = session_status.message or "Retrying..."
	if #retry_msg > 80 then
		retry_msg = retry_msg:sub(1, 80) .. "..."
	end
	local attempt = session_status.attempt or 0
	local retry_info = ""
	if session_status.next then
		local wait_sec = math.max(0, math.floor((session_status.next - os.time() * 1000) / 1000))
		if wait_sec > 0 then
			retry_info = string.format(" [retrying in %ds attempt #%d]", wait_sec, attempt)
		else
			retry_info = string.format(" [retrying attempt #%d]", attempt)
		end
	else
		retry_info = string.format(" [attempt #%d]", attempt)
	end

	local status_line = NuiLine()
	status_line:append(NuiText(retry_msg .. retry_info, "ErrorMsg"))
	ctx:add_line(status_line)
end

local function render_user_message(ctx, message, render_parts, msg_idx, messages, max_user_message_lines)
	local file_parts = {}
	for _, part in ipairs(render_parts.parts or {}) do
		if
			part.type == "file"
			and not part.synthetic
			and part.mime ~= "text/plain"
			and part.mime ~= "application/x-directory"
		then
			table.insert(file_parts, part)
		end
	end

	local msg_lines = ctx:cached_nui_lines(
		ctx:render_cache_key(
			"user",
			ctx.current_session.id,
			message.id,
			render_parts.message_revision,
			ctx.chat_width,
			message.agent or "",
			max_user_message_lines
		),
		function()
			return render.render_user_message(render_parts.content, message.agent, file_parts, {
				max_lines = max_user_message_lines,
			})
		end
	)
	for _, nl in ipairs(msg_lines) do
		ctx:add_line(nl)
	end

	render_retry_status_if_needed(ctx, messages, msg_idx)
	ctx:add_raw_line("")
end

local function render_reasoning_part(ctx, message, part, part_idx, render_parts, incomplete_assistant)
	if not thinking.is_enabled() then
		return
	end
	local reasoning_start = ctx:line_count()
	local cache_key = nil
	if not incomplete_assistant then
		cache_key = ctx:render_cache_key(
			"reasoning",
			ctx.current_session.id,
			message.id,
			part.id or part_idx,
			render_parts.message_revision,
			part.id and render_parts.part_revisions[part.id] or 0,
			ctx.chat_width
		)
	end
	local reasoning_lines = ctx:cached_nui_lines(cache_key, function()
		return render.render_reasoning(part.text)
	end)
	for _, nl in ipairs(reasoning_lines) do
		ctx:add_line(nl)
	end
	if incomplete_assistant and #reasoning_lines > 0 and part.id then
		ctx:register_stream_block(message.id, part, "reasoning", reasoning_start)
	end
end

local function render_text_part(ctx, message, part, part_idx, render_parts, incomplete_assistant, render_as_plain_stream)
	local content_start = ctx:line_count()
	local cache_key = nil
	if not incomplete_assistant then
		cache_key = ctx:render_cache_key(
			"text",
			ctx.current_session.id,
			message.id,
			part.id or part_idx,
			render_parts.message_revision,
			part.id and render_parts.part_revisions[part.id] or 0,
			ctx.chat_width,
			render_as_plain_stream
		)
	end
	local content_lines = ctx:cached_nui_lines(cache_key, function()
		return render.render_content(part.text, { stream_plain = render_as_plain_stream })
	end)
	ctx:add_nui_lines(content_lines)
	if incomplete_assistant and #content_lines > 0 and part.id then
		ctx:register_stream_block(message.id, part, "text", content_start)
	end
end

local function render_assistant_message(ctx, index, message, render_parts, opts)
	for part_idx, part in ipairs(render_parts.parts) do
		if part.type == "reasoning" and part.text and part.text ~= "" then
			render_reasoning_part(ctx, message, part, part_idx, render_parts, opts.incomplete_assistant)
		elseif part.type == "text" and part.text and part.text ~= "" then
			render_text_part(
				ctx,
				message,
				part,
				part_idx,
				render_parts,
				opts.incomplete_assistant,
				opts.render_as_plain_stream
			)
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
			widget_renderer.render_widgets_for_tool_call(ctx, index, message.id, part.callID)
			if part.tool == "task" then
				widget_renderer.render_child_session_widgets_for_task(ctx, index, part)
			end
		end
	end

	widget_renderer.render_widgets_for_message(ctx, index, message.id)

	if opts.force_processing_render or render.should_show_footer(message, opts.is_last_assistant) then
		ctx:ensure_single_blank_separator()
		local footer_line_idx = ctx:line_count()
		local show_spinner = opts.spinner_active and opts.is_last_assistant and opts.incomplete_assistant
		local spinner_frame = show_spinner and spinner.get_frame() or nil
		ctx:add_line(opts.render_metadata_footer_line(message, spinner_frame, render_parts.message_revision))
		if show_spinner then
			ctx:set_spinner_footer_line(footer_line_idx)
			opts.spinner_footer_rendered.value = true
		end
		ctx:add_raw_line("")
	end
end

local function render_messages(ctx, index, all_messages, messages, skipped_messages, render_metadata_footer_line)
	local current_session_processing = get_current_session_processing(ctx)
	local last_assistant_idx, last_assistant = find_last_assistant(messages)
	local spinner_active = should_activate_spinner(current_session_processing, messages, last_assistant)
	local max_user_message_lines = tonumber((ctx.chat_config or {}).max_user_message_lines) or 0
	local spinner_footer_rendered = { value = false }

	render_hidden_history_notice(ctx, skipped_messages)

	for msg_idx, message in ipairs(messages) do
		local message_start_line = ctx:line_count()
		local render_parts = ctx:get_message_render_parts(
			message.id,
			message.role == "user" and { include_synthetic = false } or nil
		)
		local incomplete_assistant = message.role == "assistant" and not (message.time and message.time.completed)
		local render_as_plain_stream = current_session_processing and incomplete_assistant

		local has_content = render_parts.content and render_parts.content ~= ""
		local has_reasoning = render_parts.reasoning and render_parts.reasoning ~= ""
		local has_tools = #render_parts.tool_parts > 0
		local is_last_assistant = (msg_idx == last_assistant_idx)
		local force_processing_render = spinner_active and is_last_assistant and incomplete_assistant
		local should_render = message.role ~= "assistant"
			or has_content
			or has_reasoning
			or has_tools
			or force_processing_render

		if should_render then
			if message.role == "user" then
				render_user_message(ctx, message, render_parts, msg_idx, messages, max_user_message_lines)
			else
				render_assistant_message(ctx, index, message, render_parts, {
					incomplete_assistant = incomplete_assistant,
					render_as_plain_stream = render_as_plain_stream,
					is_last_assistant = is_last_assistant,
					force_processing_render = force_processing_render,
					spinner_active = spinner_active,
					spinner_footer_rendered = spinner_footer_rendered,
					render_metadata_footer_line = render_metadata_footer_line,
				})
			end
		end

		if should_render then
			register_message_range(message, message_start_line, ctx:line_count() - 1)
		end
	end

	return {
		spinner_active = spinner_active,
		spinner_footer_rendered = spinner_footer_rendered.value,
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

	for _, message in ipairs(state.local_notices) do
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
			local msg_lines = render.render_user_message(message.content or "", message.agent, nil, {
				max_lines = max_user_message_lines,
			})
			for _, nl in ipairs(msg_lines) do
				ctx:add_line(nl)
			end
			ctx:add_raw_line("")
			register_message_range(message, message_start_line, ctx:line_count() - 1, "local_notice")
			goto continue_local_message
		end

		if message.content and message.content ~= "" then
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

local function render_fallback_spinner_footer(ctx, render_metadata_footer_line)
	local fallback_agent = "assistant"
	local fallback_model_id = nil
	local fallback_provider_id = nil
	local local_ok, local_state = pcall(require, "opencode.local")
	if local_ok then
		local current_agent = local_state.agent.current()
		local current_model = local_state.model.current()
		if current_agent and current_agent.name then
			fallback_agent = current_agent.name
		end
		if current_model then
			fallback_model_id = current_model.modelID
			fallback_provider_id = current_model.providerID
		end
	end

	local fallback_message = {
		role = "assistant",
		agent = fallback_agent,
		mode = fallback_agent,
		modelID = fallback_model_id,
		providerID = fallback_provider_id,
	}

	ctx:ensure_single_blank_separator()
	local footer_line_idx = ctx:line_count()
	ctx:add_line(render_metadata_footer_line(fallback_message, spinner.get_frame()))
	ctx:set_spinner_footer_line(footer_line_idx)
	ctx:add_raw_line("")
end

local function render_empty_state(ctx)
	if ctx:line_count() > 0 then
		return
	end
	if not ctx.current_session.id then
		ctx:add_raw_line(" No active session")
	end
	ctx:add_raw_line(" Press 'i' to focus input")
	ctx:add_raw_line(" Press '<C-p>' for command palette")
	ctx:add_raw_line(" Press '?' for help")
	ctx:add_raw_line("")
end

function M.render(ctx, index)
	render_session_chrome(ctx)

	local all_messages, messages, skipped_messages = select_messages(ctx, index)
	local user_created_by_id = build_user_created_by_id(all_messages)
	local render_metadata_footer_line = make_metadata_footer_renderer(ctx, all_messages, user_created_by_id)
	local message_stats = render_messages(ctx, index, all_messages, messages, skipped_messages, render_metadata_footer_line)

	render_local_notices(ctx, index, all_messages, message_stats.max_user_message_lines)
	render_orphan_widgets(ctx, index, all_messages)

	if message_stats.spinner_active and not message_stats.spinner_footer_rendered then
		render_fallback_spinner_footer(ctx, render_metadata_footer_line)
	end

	render_empty_state(ctx)

	return {
		all_messages = all_messages,
		rendered_messages = messages,
		skipped_messages = skipped_messages,
	}
end

return M
