-- Child-session resolution for task tool parts.
-- Extracted from tasks.lua (phase 4); tasks.lua re-exports the public entry points.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local actions = require("opencode.actions")
local render = require("opencode.ui.chat.render")
local tool_labels = require("opencode.ui.chat.tool_labels")
local task_animation = require("opencode.ui.chat.task_animation")

local function chat_tasks()
	return require("opencode.ui.chat.tasks")
end

---@param tool_part table
---@return string|nil
function M.get_task_child_session_id(tool_part)
	tool_part = chat_tasks().resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" then
		return nil
	end
	local ok_sync, sync = pcall(require, "opencode.sync")
	if ok_sync and type(sync.get_task_child_session_for_part) == "function" then
		local indexed = sync.get_task_child_session_for_part(tool_part)
		if indexed and indexed ~= "" then
			return indexed
		end
	elseif ok_sync and type(sync.get_task_child_session) == "function" then
		local indexed = sync.get_task_child_session(tool_part.messageID, tool_part.id)
		if indexed and indexed ~= "" then
			return indexed
		end
	end

	local metadata = render.get_tool_metadata(tool_part)
	return metadata.sessionId
		or metadata.sessionID
		or metadata.session_id
		or metadata.childSessionID
		or metadata.childSessionId
		or metadata.child_session_id
		or tool_part.childSessionID
		or tool_part.childSessionId
		or tool_part.child_session_id
end

---@param tool_part table|nil
---@return string|nil
function M.get_task_parent_session_id(tool_part)
	tool_part = chat_tasks().resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" then
		return nil
	end
	if tool_part.sessionID and tool_part.sessionID ~= "" then
		return tool_part.sessionID
	end
	if tool_part.messageID then
		local ok_sync, sync = pcall(require, "opencode.sync")
		if ok_sync and type(sync.find_message_session_id) == "function" then
			local session_id = sync.find_message_session_id(tool_part.messageID)
			if session_id and session_id ~= "" then
				return session_id
			end
		end
	end
	local ok_state, app_state = pcall(require, "opencode.state")
	if ok_state then
		local current = app_state.get_session()
		return current and current.id or nil
	end
	return nil
end

local task_child_resolution_pending = {}

---@param child table
---@return string
local function child_title(child)
	return tostring(child.title or child.name or child.description or "")
end

---@param child table
---@return number created
---@return number updated
local function child_times(child)
	local time = type(child.time) == "table" and child.time or {}
	local created = tool_labels.normalize_count(time.created or time.start) or 0
	local updated = tool_labels.normalize_count(time.updated or time.completed or time["end"]) or created
	return created, updated
end

---@param tool_part table
---@param parent_session_id string
---@return table
local function task_resolution_item(tool_part, parent_session_id)
	tool_part = chat_tasks().resolve_tool_part(tool_part)
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local input = type(tool_state.input) == "table" and tool_state.input or {}
	return {
		part_id = tool_part.id,
		message_id = tool_part.messageID,
		parent_session_id = parent_session_id,
		tool_part = tool_part,
		input = input,
		start_time = tool_state.time and tool_labels.normalize_count(tool_state.time.start or tool_state.time.created) or nil,
	}
end

---@param child table
---@param item table
---@return number score
local function score_child_for_task(child, item)
	local title = child_title(child)
	local input = item.input or {}
	local desc = type(input.description) == "string" and vim.trim(input.description) or ""
	local subagent = type(input.subagent_type) == "string" and vim.trim(input.subagent_type) or ""
	local value = 0

	if desc ~= "" and title:find(desc, 1, true) then
		value = value + 4
	end

	if subagent ~= "" then
		local marker = "@" .. subagent .. " subagent"
		if title:find(marker, 1, true) then
			value = value + 3
		elseif child.agent == subagent or child.mode == subagent then
			value = value + 2
		end
	end

	local created = child_times(child)
	if type(item.start_time) == "number" and item.start_time > 0 and created > 0 then
		local delta = math.abs(created - item.start_time)
		if delta <= 10000 then
			value = value + 2
		elseif delta <= 120000 then
			value = value + 1
		end
	end

	return value
end

---@param children any
---@param items table[]
---@param excluded_children table<string, boolean>
---@return table[] assignments
function M.resolve_child_assignments(children, items, excluded_children)
	if type(children) ~= "table" or #children == 0 or #items == 0 then
		return {}
	end

	local remaining_children = {}
	for _, child in ipairs(children) do
		if type(child) == "table" and type(child.id) == "string" and child.id ~= "" and not excluded_children[child.id] then
			table.insert(remaining_children, child)
		end
	end
	if #remaining_children == 0 then
		return {}
	end

	local remaining_items = {}
	for _, item in ipairs(items) do
		table.insert(remaining_items, item)
	end
	local assignments = {}

	while #remaining_items > 0 and #remaining_children > 0 do
		local proposals_by_child = {}

		for _, item in ipairs(remaining_items) do
			local best = nil
			local best_tied = false
			for _, child in ipairs(remaining_children) do
				local score = score_child_for_task(child, item)
				if score > 0 then
					local proposal = { item = item, child = child, score = score }
					if not best or score > best.score then
						best = proposal
						best_tied = false
					elseif score == best.score then
						best_tied = true
					end
				end
			end
			if best and not best_tied then
				local child_id = best.child.id
				proposals_by_child[child_id] = proposals_by_child[child_id] or {}
				table.insert(proposals_by_child[child_id], best)
			end
		end

		local selected = {}
		for child_id, proposals in pairs(proposals_by_child) do
			local best = nil
			local tied = false
			for _, proposal in ipairs(proposals) do
				if not best or proposal.score > best.score then
					best = proposal
					tied = false
				elseif proposal.score == best.score then
					tied = true
				end
			end
			if best and not tied then
				selected[child_id] = best
			end
		end

		local assigned_count = 0
		local assigned_parts = {}
		local assigned_children = {}
		for child_id, proposal in pairs(selected) do
			table.insert(assignments, proposal)
			assigned_parts[proposal.item.part_id] = true
			assigned_children[child_id] = true
			assigned_count = assigned_count + 1
		end
		if assigned_count == 0 then
			break
		end

		local next_items = {}
		for _, item in ipairs(remaining_items) do
			if not assigned_parts[item.part_id] then
				table.insert(next_items, item)
			end
		end
		remaining_items = next_items

		local next_children = {}
		for _, child in ipairs(remaining_children) do
			if not assigned_children[child.id] then
				table.insert(next_children, child)
			end
		end
		remaining_children = next_children
	end

	return assignments
end

---@param parent_session_id string
---@return table[]
local function collect_unresolved_task_items(parent_session_id)
	local items = {}
	for _, pos in pairs(state.tasks) do
		local tool_part = chat_tasks().resolve_tool_part(pos)
		if
			type(tool_part) == "table"
			and tool_part.tool == "task"
			and tool_part.id
			and tool_part.messageID
			and M.get_task_parent_session_id(tool_part) == parent_session_id
			and not M.get_task_child_session_id(tool_part)
		then
			table.insert(items, task_resolution_item(tool_part, parent_session_id))
		end
	end
	table.sort(items, function(a, b)
		local a_start = a.start_time or 0
		local b_start = b.start_time or 0
		if a_start ~= b_start then
			return a_start < b_start
		end
		return tostring(a.part_id or "") < tostring(b.part_id or "")
	end)
	return items
end

---@param parent_session_id string
---@param items table[]
---@param children table[]
---@return table[] assignments
local function record_resolved_children(parent_session_id, items, children)
	local ok_sync, sync = pcall(require, "opencode.sync")
	local excluded = {}
	for index, item in ipairs(items or {}) do
		local pos = item and state.tasks[item.part_id]
		local current = chat_tasks().resolve_tool_part(pos or (item and item.tool_part))
		if current then
			items[index] = task_resolution_item(current, parent_session_id)
		end
	end
	if ok_sync and type(sync.get_task_parent_session) == "function" then
		for _, child in ipairs(children or {}) do
			if type(child) == "table" and type(child.id) == "string" then
				local owner_parent = sync.get_task_parent_session(child.id)
				if owner_parent then
					excluded[child.id] = true
				end
			end
		end
	end

	local assignments = M.resolve_child_assignments(children, items, excluded)
	for _, assignment in ipairs(assignments) do
		local item = assignment.item
		local child = assignment.child
		if item and child and child.id then
			actions.record_task_child_session(parent_session_id, item.message_id, item.part_id, child.id)
			local pos = state.tasks[item.part_id]
			if pos then
				M.ensure_task_child_loaded(pos)
				chat_tasks().rerender_task(item.part_id)
			end
		end
	end
	return assignments
end

---@param parent_session_id string
---@param children? table[]
---@return table[]|nil assignments
function M.resolve_missing_task_children(parent_session_id, children)
	if not parent_session_id or parent_session_id == "" then
		return nil
	end
	local items = collect_unresolved_task_items(parent_session_id)
	if #items == 0 then
		return {}
	end

	if type(children) == "table" then
		return record_resolved_children(parent_session_id, items, children)
	end

	actions.get_session_children(parent_session_id, function(err, fetched_children)
		if err or type(fetched_children) ~= "table" then
			return
		end
		record_resolved_children(parent_session_id, items, fetched_children)
	end)
	return nil
end

local function schedule_task_child_resolution(parent_session_id)
	if not parent_session_id or parent_session_id == "" or task_child_resolution_pending[parent_session_id] then
		return
	end
	task_child_resolution_pending[parent_session_id] = true
	vim.defer_fn(function()
		task_child_resolution_pending[parent_session_id] = nil
		M.resolve_missing_task_children(parent_session_id)
	end, 20)
end

---@param tool_part table|nil
---@param opts? table
function M.ensure_task_child_loaded(tool_part, opts)
	tool_part = chat_tasks().resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" or tool_part.tool ~= "task" then
		return
	end
	local part_id = tool_part.id
	if not part_id then
		return
	end
	local tool_status = tool_part.state and tool_part.state.status or "pending"
	if not task_animation.is_task_working(tool_status) then
		return
	end

	local child_session_id = M.get_task_child_session_id(tool_part)
	if not child_session_id or child_session_id == "" then
		local parent_session_id = M.get_task_parent_session_id(tool_part)
		if parent_session_id and schedule_task_child_resolution then
			schedule_task_child_resolution(parent_session_id)
		end
		return
	end

	local ok_sync, sync = pcall(require, "opencode.sync")
	if ok_sync and type(sync.get_messages) == "function" then
		local messages = sync.get_messages(child_session_id)
		if type(messages) == "table" and #messages > 0 then
			state.task_child_cache[part_id] = true
			return
		end
	end

	if state.task_child_cache[part_id] or state.task_child_loading[part_id] then
		return
	end

	state.task_child_loading[part_id] = true
	local load_opts = vim.tbl_extend("force", { limit = 100 }, type(opts) == "table" and opts or {})
	actions.load_session_messages(child_session_id, load_opts, function(fetch_err)
		vim.schedule(function()
			state.task_child_loading[part_id] = nil
			if not fetch_err then
				state.task_child_cache[part_id] = true
			end
			if state.tasks[part_id] then
				chat_tasks().rerender_task(part_id)
			end
		end)
	end)
end

---@param tool_part table
---@param callback function(err: any, child_session_id: string|nil)
function M.resolve_task_child_session_id(tool_part, callback)
	tool_part = chat_tasks().resolve_tool_part(tool_part)
	local child_session_id = M.get_task_child_session_id(tool_part)
	if child_session_id then
		callback(nil, child_session_id)
		return
	end

	local ok_state, app_state = pcall(require, "opencode.state")
	if not ok_state then
		callback("Missing required modules", nil)
		return
	end

	local current = app_state.get_session()
	if not current or not current.id then
		callback(nil, nil)
		return
	end

	local input = tool_part and tool_part.state and tool_part.state.input or {}
	local start_time = tool_part and tool_part.state and tool_part.state.time and tool_part.state.time.start or nil
	local parent_session_id = M.get_task_parent_session_id(tool_part) or current.id
	local item = task_resolution_item(tool_part, parent_session_id)
	item.input = input
	item.start_time = tool_labels.normalize_count(start_time)

	actions.get_session_children(parent_session_id, function(err, children)
		if err then
			callback(err, nil)
			return
		end
		local assignments = record_resolved_children(parent_session_id, { item }, children or {})
		local assignment = assignments and assignments[1]
		callback(nil, assignment and assignment.child and assignment.child.id or nil)
	end)
end

return M
