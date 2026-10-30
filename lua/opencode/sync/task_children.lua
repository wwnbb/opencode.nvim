-- Task-child ownership owned by sync.lua: which task tool part launched a child
-- session. Indexes live in sync's store (task_child_parent, task_child_owner,
-- task_part_child); call provenance stays private to each sync instance.
local M = {}

local function nonempty_string(value)
	if type(value) ~= "string" or value == "" then return nil end
	return value
end

---@param sync table The sync facade (get_part, get_messages, get_message_tools, clear_session)
---@param store table Sync's store
---@param hooks { part_key: function, find_message_session_id: function, bump_part_revision: function, forget_native: function }
---@return table
function M.new(sync, store, hooks)
	local T = {}
	-- Navigation references can share a child after a fork copies settled history.
	local task_child_references, task_child_pending, task_reference_sequence = {}, {}, 0
	-- { [messageID] = { [partID] = true } } so clearing a message skips other messages' links.
	local message_task_parts = {}

	---@param tool_part table|nil
	---@return string|nil
	function T.resolve_child_session_id(tool_part)
		if type(tool_part) ~= "table" or tool_part.tool ~= "task" then
			return nil
		end

		local part_metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
		local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
		local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}

		-- Both spellings occur in verified v2 runtimes: 2.0.11 emits sessionID,
		-- while the current task tool source uses sessionId.
		return nonempty_string(state_metadata.sessionID) or nonempty_string(state_metadata.sessionId)
			or nonempty_string(part_metadata.sessionID) or nonempty_string(part_metadata.sessionId)
	end

	local function inherited_task_reference(child_session_id, parent_session_id)
		local state = require("opencode.state")
		local source = state.get_session_fork_source_id(parent_session_id)
		if not source then return false end
		local native_parent = state.get_session_parent_id(child_session_id)
		local visited = { [parent_session_id] = true }
		while source and not visited[source] do
			if source == native_parent then return true end
			for _, reference in pairs(task_child_references[child_session_id] or {}) do
				if reference.parent == source then return true end
			end
			visited[source] = true
			source = state.get_session_fork_source_id(source)
		end
		return false
	end

	local function task_reference_can_replace(child_session_id, reference, existing)
		local native_parent = require("opencode.state").get_session_parent_id(child_session_id)
		-- Copies retain call IDs; a distinct call can establish a genuine conflict
		-- only after native ancestry is known.
		if not existing then return not native_parent or native_parent == reference.parent end
		if reference.parent == existing.parent or native_parent == reference.parent then return true end
		if native_parent and reference.callID and existing.callID and reference.callID ~= existing.callID then
			for _, other in pairs(task_child_references[child_session_id] or {}) do
				if other.parent ~= reference.parent and other.callID == reference.callID then return false end
			end
			return true
		end
		return false
	end

	local function task_reference_can_own(child_session_id, parent_session_id, reference)
		local state = require("opencode.state")
		local native_parent = state.get_session_parent_id(child_session_id)
		if reference and reference.explicit then return true end
		if native_parent == parent_session_id then return true end
		if inherited_task_reference(child_session_id, parent_session_id) then return false end
		if reference and reference.genuine then return true end
		-- Without source history or native ancestry a fork launch is ambiguous. Keep
		-- its navigation link, but wait for metadata before claiming a new child.
		return not state.get_session_fork_source_id(parent_session_id)
	end

	local function bump_task_reference_revision(key)
		local message_id, part_id = key:match("^(.-)%z(.+)$")
		if message_id and part_id then
			hooks.forget_native(message_id)
			hooks.bump_part_revision(message_id, part_id, hooks.find_message_session_id(message_id))
		end
	end

	-- Metadata may arrive after either history. Repair only this child's claims;
	-- explicit removal of a genuine owner must not revive an older task link.
	local function refresh_task_child_owner(child_session_id)
		local parent = store.task_child_parent[child_session_id]
		local previous = store.task_child_owner[child_session_id]
		local references = task_child_references[child_session_id] or {}
		local current = references[previous]
		local native_parent = require("opencode.state").get_session_parent_id(child_session_id)
		local valid = parent and current and not current.retired and task_reference_can_own(child_session_id, parent, current)
			and (current.genuine or task_reference_can_replace(child_session_id, current, nil))
		if valid and native_parent then current.genuine = true end
		if valid and not task_child_pending[child_session_id] then return false end
		if not parent and not task_child_pending[child_session_id] then return false end
		local existing = valid and references[previous] or nil
		local owner, sequence, pending = valid and previous or nil, existing and existing.sequence, false
		if not valid then parent = nil end
		for key, reference in pairs(references) do
			if not reference.retired then
				if not task_reference_can_own(child_session_id, reference.parent, reference) then pending = true
				elseif not sequence or reference.sequence > sequence then
					if reference.genuine or task_reference_can_replace(child_session_id, reference, existing) then
						if native_parent then reference.genuine = true end
						owner, parent, sequence = key, reference.parent, reference.sequence
					else pending = true end
				end
			end
		end
		store.task_child_parent[child_session_id], store.task_child_owner[child_session_id] = parent, owner
		task_child_pending[child_session_id] = pending and true or nil
		if previous == owner then return false end
		if previous then bump_task_reference_revision(previous) end
		if owner then bump_task_reference_revision(owner) end
		return true
	end

	---@param message_id string|nil
	---@param part_id string|nil
	function T.clear(message_id, part_id)
		local key = hooks.part_key(message_id, part_id)
		if not key then
			return
		end
		local child_session_id = store.task_part_child[key]
		if child_session_id then
			refresh_task_child_owner(child_session_id)
			hooks.forget_native(message_id)
			local references = task_child_references[child_session_id]
			local removed = references and references[key]
			if references then
				references[key] = nil
				if not next(references) then
					task_child_references[child_session_id], task_child_pending[child_session_id] = nil, nil
				end
			end
			if store.task_child_owner[child_session_id] == key then
				if removed and removed.genuine then
					-- Keep navigation, but only another genuine write may reclaim this child.
					for _, reference in pairs(references or {}) do reference.retired = true end
				end
				store.task_child_parent[child_session_id] = nil
				store.task_child_owner[child_session_id] = nil
				task_child_pending[child_session_id] = nil
			end
		end
		store.task_part_child[key] = nil
		local parts = message_task_parts[message_id]
		if parts then
			parts[part_id] = nil
			if not next(parts) then message_task_parts[message_id] = nil end
		end
	end

	---@param parent_session_id string
	---@param message_id string
	---@param part_id string
	---@param child_session_id string
	---@return boolean changed
	local function record_task_child_index(parent_session_id, message_id, part_id, child_session_id, explicit)
		if
			not parent_session_id
			or parent_session_id == ""
			or not message_id
			or message_id == ""
			or not part_id
			or part_id == ""
			or not child_session_id
			or child_session_id == ""
		then
			return false
		end

		local key = hooks.part_key(message_id, part_id)
		if not key then
			return false
		end
		hooks.forget_native(message_id)

		local changed = false
		local existing_child = store.task_part_child[key]
		local existing_references = existing_child and task_child_references[existing_child]
		local existing_reference = existing_references and existing_references[key]
		local new_reference = existing_child ~= child_session_id
			or (existing_reference and existing_reference.parent ~= parent_session_id)
		if new_reference then
			T.clear(message_id, part_id)
			changed = true
		end

		store.task_part_child[key] = child_session_id
		message_task_parts[message_id] = message_task_parts[message_id] or {}
		message_task_parts[message_id][part_id] = true
		task_child_references[child_session_id] = task_child_references[child_session_id] or {}
		local references = task_child_references[child_session_id]
		if not references[key] or references[key].parent ~= parent_session_id then
			task_reference_sequence = task_reference_sequence + 1
			references[key] = { parent = parent_session_id, sequence = task_reference_sequence }
		end
		local reference = references[key]
		local part = sync.get_part(message_id, part_id)
		-- Direct/legacy task bindings remain explicit; native projections always
		-- carry callID and must establish provenance before overriding native ancestry.
		reference.callID = part and part.callID
		reference.explicit = reference.explicit or explicit or not reference.callID
		reference.genuine = reference.genuine or reference.explicit
		changed = refresh_task_child_owner(child_session_id) or changed
		if not task_reference_can_own(child_session_id, parent_session_id, reference) then
			-- Copied launches remain navigable, but never acquire their source's child.
			task_child_pending[child_session_id] = true
		else
			local existing_owner = store.task_child_owner[child_session_id]
			local existing = existing_owner and references[existing_owner]
			local claim = reference.genuine or (not reference.retired and task_reference_can_replace(child_session_id, reference, existing))
			-- Distinct genuine calls replay in write order; copied call IDs do not.
			if claim and (not existing or existing.parent == parent_session_id or new_reference or explicit
				or (reference.genuine and reference.callID and reference.callID ~= existing.callID)) then
				if require("opencode.state").get_session_parent_id(child_session_id) then reference.genuine = true end
				if reference.genuine then
					task_reference_sequence = task_reference_sequence + 1
					reference.sequence, reference.retired = task_reference_sequence, nil
				end
				if existing_owner and existing_owner ~= key then bump_task_reference_revision(existing_owner) end
				if store.task_child_parent[child_session_id] ~= parent_session_id or existing_owner ~= key then changed = true end
				store.task_child_parent[child_session_id] = parent_session_id
				store.task_child_owner[child_session_id] = key
			else task_child_pending[child_session_id] = true end
		end

		if changed then
			hooks.bump_part_revision(message_id, part_id, parent_session_id)
		end
		return changed
	end

	---@param part table|nil
	---@param previous_part table|nil
	function T.index(part, previous_part)
		if type(part) ~= "table" then
			return
		end

		local message_id = part.messageID
		local part_id = part.id

		if part.type ~= "tool" or part.tool ~= "task" then
			T.clear(message_id, part_id)
			return
		end

		local child_session_id = T.resolve_child_session_id(part)
		if not child_session_id or child_session_id == "" then
			T.clear(message_id, part_id)
			return
		end

		local parent_session_id = part.sessionID or hooks.find_message_session_id(message_id)
		if not parent_session_id or parent_session_id == "" then
			T.clear(message_id, part_id)
			return
		end

		local key = hooks.part_key(message_id, part_id)
		if not key then
			return
		end

		local previous_state = previous_part and type(previous_part.state) == "table" and previous_part.state or {}
		-- A copied settled history row is not a launch. An already-running native
		-- call acquiring its first child ID is; retain task-first precedence for it.
		local launched = part.callID and previous_part and previous_part.callID == part.callID
			and previous_part.type == "tool" and previous_part.tool == "task"
			and previous_part.sessionID == part.sessionID
			and (previous_state.status == "running" or previous_state.status == "streaming")
			and not T.resolve_child_session_id(previous_part)
		record_task_child_index(parent_session_id, message_id, part_id, child_session_id, launched)
	end

	---@param message_id string|nil
	function T.clear_message(message_id)
		if not message_id then
			return
		end
		hooks.forget_native(message_id)
		for part_id in pairs(vim.deepcopy(message_task_parts[message_id] or {})) do
			T.clear(message_id, part_id)
		end
	end

	---@param child_session_id string|nil
	---@return string|nil
	function T.get_task_parent_session(child_session_id)
		if not child_session_id or child_session_id == "" then
			return nil
		end
		refresh_task_child_owner(child_session_id)
		return store.task_child_parent[child_session_id]
	end

	---@param message_id string|nil
	---@param part_id string|nil
	---@return string|nil
	function T.get_task_child_session(message_id, part_id)
		local key = hooks.part_key(message_id, part_id)
		return key and store.task_part_child[key] or nil
	end

	---@param child_session_id string|nil
	---@return string|nil message_id
	---@return string|nil part_id
	function T.get_task_child_owner(child_session_id)
		if not child_session_id or child_session_id == "" then
			return nil, nil
		end
		refresh_task_child_owner(child_session_id)
		local key = store.task_child_owner[child_session_id]
		if not key then
			return nil, nil
		end
		local message_id, part_id = key:match("^(.-)%z(.+)$")
		return message_id, part_id
	end

	---@param tool_part table|nil
	---@return string|nil
	function T.get_task_child_session_for_part(tool_part)
		if type(tool_part) ~= "table" then
			return nil
		end
		return T.get_task_child_session(tool_part.messageID, tool_part.id) or T.resolve_child_session_id(tool_part)
	end

	---@param parent_session_id string|nil
	---@return string[] child_session_ids
	function T.get_task_child_sessions(parent_session_id)
		if not parent_session_id or parent_session_id == "" then
			return {}
		end
		local children = {}
		for child_session_id in pairs(task_child_references) do
			if T.get_task_parent_session(child_session_id) == parent_session_id then
				table.insert(children, child_session_id)
			end
		end
		table.sort(children)
		return children
	end

	-- The pre-index metadata fallback must use the same provenance rules as indexing.
	function T.task_reference_can_own(parent_session_id, child_session_id)
		return task_reference_can_own(child_session_id, parent_session_id)
	end

	---Collect a session and its confirmed native/task descendants, depth-first.
	---Must run before any clearing: clear_session() drops the child->parent index.
	---@param session_id string|nil
	---@return string[] session_ids Root first, then descendants.
	function T.collect_session_tree(session_id)
		if not session_id or session_id == "" then return {} end
		local children, task_parents = {}, {}
		local function add_child(parent, id)
			if not parent then return end
			children[parent] = children[parent] or {}
			table.insert(children[parent], id)
		end
		for id, references in pairs(task_child_references) do
			local parent = T.get_task_parent_session(id)
			local reference = references[store.task_child_owner[id]]
			-- Settled history alone is provisional, even before fork metadata arrives.
			-- Keep navigation, but require confirmation before irreversible cleanup.
			if parent and reference and reference.genuine then
				task_parents[id] = parent
				add_child(parent, id)
			end
		end
		local state = require("opencode.state")
		for _, id in ipairs(state.get_session_ids()) do
			-- Only a confirmed task owner overrides native ancestry (task-first).
			if not task_parents[id] then add_child(state.get_session_parent_id(id), id) end
		end
		local ids = {}
		local visited = {}
		local function visit(id)
			if not id or id == "" or visited[id] then
				return
			end
			visited[id] = true
			table.insert(ids, id)
			local child_ids = children[id] or {}
			table.sort(child_ids)
			for _, child_id in ipairs(child_ids) do
				visit(child_id)
			end
		end
		visit(session_id)
		return ids
	end

	---Clear all data for a session and every native/task descendant.
	---@param session_id string|nil
	function T.clear_session_tree(session_id)
		for _, id in ipairs(T.collect_session_tree(session_id)) do
			sync.clear_session(id)
		end
	end

	---@param parent_session_id string
	---@param message_id string
	---@param part_id string
	---@param child_session_id string
	---@return boolean changed
	function T.record_task_child_session(parent_session_id, message_id, part_id, child_session_id)
		-- Explicit late resolution can establish a genuine task conflict, but cannot
		-- turn an already indexed navigation-only copy into an ownership claim.
		local key = hooks.part_key(message_id, part_id)
		return record_task_child_index(parent_session_id, message_id, part_id, child_session_id,
			not (key and store.task_part_child[key]))
	end

	---Whether parent owns child through the task index, native ancestry, or a
	---genuinely pre-index task part (moved from events/util.lua).
	---@param parent_session_id string|nil
	---@param child_session_id string|nil
	---@return boolean
	function T.session_owns_task_child(parent_session_id, child_session_id)
		if not parent_session_id or parent_session_id == "" or not child_session_id or child_session_id == "" then
			return false
		end

		local indexed_parent = T.get_task_parent_session(child_session_id)
		if indexed_parent then
			return indexed_parent == parent_session_id
		end

		local ok_state, state = pcall(require, "opencode.state")
		if ok_state and type(state.get_session_record) == "function" then
			local record = state.get_session_record(child_session_id)
			local record_parent = type(record) == "table" and record.parentID or nil
			if record_parent then
				return record_parent == parent_session_id
			end
		end

		for _, message in ipairs(sync.get_messages(parent_session_id) or {}) do
			for _, part in ipairs(sync.get_message_tools(message.id) or {}) do
				-- An indexed navigation reference without an owner was deliberately
				-- classified as copied/ambiguous. Only genuinely pre-index parts fall back.
				if part.type == "tool" and part.tool == "task"
					and not T.get_task_child_session(message.id, part.id)
					and task_reference_can_own(child_session_id, parent_session_id)
					and T.get_task_child_session_for_part(part) == child_session_id then
					return true
				end
			end
		end

		return false
	end

	---Forget private provenance; sync.clear_all resets the store-owned indexes.
	function T.reset()
		task_child_references, task_child_pending, task_reference_sequence = {}, {}, 0
		message_task_parts = {}
	end

	return T
end

return M
