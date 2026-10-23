-- Native session family: ascend parentID links to the root, then load every
-- descendant (paginated by the client) and refresh their statuses, without
-- changing session tabs. The connection policy stays with actions.
local M = {}

local STALE = "Family changed while loading; open it again"

---@param session_id string Session whose family is loaded
---@param token any session.pending token captured when the connection was ready
---@param publish fun(err?: table, family?: table[], root_id?: string) Token-guarded callback
function M.load(session_id, token, publish)
	local pending = require("opencode.session.pending")
	local state, sync, client = require("opencode.state"), require("opencode.sync"), require("opencode.client")
	local sessions = require("opencode.session")
	local ancestors, records, seen, queue, record_tokens, loaded, head = {}, {}, {}, {}, {}, {}, 1
	local root_id
	local function current() return pending.is_current(token) end
	local function fetch(id, done)
		if loaded[id] then
			if not pending.is_current(record_tokens[id]) then publish({ message = STALE }); return end
			done(vim.tbl_deep_extend("force", {}, loaded[id], state.get_session_record(id) or {}))
			return
		end
		local node_token, snapshot = pending.token(id), state.get_session_record(id)
		record_tokens[id] = node_token
		client.get_session(id, function(err, record)
			if not current() then return end
			if not pending.is_current(node_token) then publish({ message = STALE }); return end
			if err then publish(err); return end
			local latest = state.get_session_record(id)
			if vim.deep_equal(snapshot, latest) then sessions.remember(record, { touch = false, reason = "session_family" })
			else record = vim.tbl_deep_extend("force", {}, record, latest or {}) end
			loaded[id] = record
			done(record)
		end)
	end
	local function finish()
		local snapshots = {}
		for _, record in ipairs(records) do
			snapshots[record.id] = { token = pending.token(record.id), revision = state.get_session_status_revision(record.id) }
		end
		client.get_session_statuses(function(err, statuses)
			if not current() then return end
			if err then publish(err); return end
			for id, snapshot in pairs(snapshots) do
				if pending.is_current(record_tokens[id]) and pending.is_current(snapshot.token)
					and state.get_session_status_revision(id) == snapshot.revision then
					local status = require("opencode.session.status").from_active_snapshot(statuses[id],
						state.get_session_status(id), sync.get_messages(id))
					sync.handle_session_status(id, status)
					sessions.set_session_status(id, status, { reason = "session_family" })
				end
			end
			local family = {}
			for _, record in ipairs(records) do
				if pending.is_current(record_tokens[record.id]) then family[#family + 1] = record end
			end
			publish(nil, family, root_id)
		end)
	end
	local function walk()
		if not current() then return end
		local id = queue[head]
		if not id then finish(); return end
		head = head + 1
		if seen[id] then walk(); return end
		seen[id] = true
		fetch(id, function(record)
			records[#records + 1] = record
			client.get_session_children(id, function(err, children)
				if not current() then return end
				if not pending.is_current(record_tokens[id]) then publish({ message = STALE }); return end
				if err then publish(err); return end
				for _, child in ipairs(children) do if not seen[child.id] then queue[#queue + 1] = child.id end end
				walk()
			end)
		end)
	end
	local function ascend(id)
		if ancestors[id] then publish({ message = "Session family has a parent cycle" }); return end
		ancestors[id] = true
		fetch(id, function(record)
			if type(record.parentID) == "string" and record.parentID ~= "" then ascend(record.parentID)
			else root_id = id; queue[1] = id; walk() end
		end)
	end
	ascend(session_id)
end

return M
