local M = {}
local recovery = {}
local deleted = {}

function M.clear()
	for _, entry in pairs(recovery) do
		if entry.timer then pcall(entry.timer.stop, entry.timer); pcall(entry.timer.close, entry.timer) end
	end
	recovery, deleted = {}, {}
end

function M.setup(events)
	local sync = require("opencode.sync")
	local state = require("opencode.state")
	local sessions = require("opencode.session")
	local pending = require("opencode.session.pending")
	local client = require("opencode.client")
	local function changed(sid, kind)
		events.emit("sync_changed", { session_id = sid, kind = kind or "message", action = "v2" })
	end
	local function reconcile(sid, complete)
		if not sid or deleted[sid] then return end
		if recovery[sid] then recovery[sid].again = true; recovery[sid].complete = recovery[sid].complete or complete; return end
		local entry, token = { complete = complete }, pending.token(sid)
		recovery[sid] = entry
		entry.timer = vim.defer_fn(function()
			entry.timer = nil
			if not pending.is_current(token) or recovery[sid] ~= entry then return end
			local snapshot = sync.capture_session_snapshot(sid)
			local complete_read = entry.complete
			local session_snapshot = state.get_session_record(sid)
			local inbox_snapshot = pending.list(sid)
			local function load(cb)
				if complete_read then client.get_all_messages(sid, cb) else client.get_messages(sid, { limit = 100 }, cb) end
			end
			client.get_session(sid, function(err, info)
				if not err and pending.is_current(token) and vim.deep_equal(session_snapshot, state.get_session_record(sid)) then
					sessions.remember(info, { touch = false }); changed(sid, "session")
				end
			end)
			local history_done, inbox_done, history_err, inbox_err, messages, items
			local function finish_recovery()
				if not history_done or not inbox_done then return end
				if not pending.is_current(token) or recovery[sid] ~= entry then return end
				local delivered, queued = {}, {}
				if not history_err then
					pending.reconcile_history(sid, messages)
					for _, message in ipairs(messages) do
						local info = message.info
						if info and info.role == "user" then
							delivered[info.id] = true
						end
					end
				end
				if not inbox_err then
					for _, item in ipairs(items) do
						queued[item.id] = true
						if not delivered[item.id] and vim.deep_equal(inbox_snapshot[item.id], pending.get(sid, item.id)) then pending.admit(item) end
					end
				end
				-- History excludes pending inbox entries. Keep them visible during a
				-- complete history replacement, including in a fresh Neovim client.
				local pending_messages = {}
				for id, record in pairs(pending.list(sid)) do
					if complete_read and not history_err and not inbox_err and not delivered[id] and not queued[id]
						and vim.deep_equal(inbox_snapshot[id], record)
						and (record.status == "queued" or record.status == "accepted") then
						-- The two reads are not atomic: delivery can fall between
						-- them. Absence alone proves neither cancellation nor failure.
						pending.update(sid, id, { delivery_missing = true })
					end
					if record.status ~= "delivered" and record.status ~= "cancelled" then
						local item = record.inbox
						local payload = item and item.type == "user" and item.payload or record.payload
						if payload then
							local native = vim.deepcopy(payload)
							local old = sync.get_message(sid, id)
							native.id, native.type = id, "user"
							native.delivery, native.resume = nil, nil
							native.time = old and old.time or (item and item.time)
							local projected = require("opencode.protocol.v2.messages").project(sid, native)
							projected.info.provisional = true
							pending_messages[#pending_messages + 1] = projected
						end
					end
				end
				if not history_err then
					vim.list_extend(messages, pending_messages)
					sync.handle_session_messages(sid, messages, { snapshot = snapshot, reconcile = complete_read, complete = complete_read })
					sessions.set_message_cache(sid, sync.get_messages(sid), { reason = "v2_reconcile" })
				elseif #pending_messages > 0 then sync.handle_session_messages(sid, pending_messages) end
				if not history_err or not inbox_err then changed(sid) end
				local again = entry.again
				recovery[sid] = nil
				if again then reconcile(sid, entry.complete) end
			end
			load(function(err, data)
				history_err, messages, history_done = err, data, true
				finish_recovery()
			end)
			client.get_inbox(sid, function(err, data)
				inbox_err, items, inbox_done = err, data, true
				finish_recovery()
			end)
		end, 100)
	end
	events.on("v2_reconcile", function(data) reconcile(data and data.session_id, data and data.complete) end)
	events.on("session.closed", function(data)
		for _, id in ipairs(data.session_ids or { data.session_id }) do
			if id then
				pending.clear_session(id); recovery[id] = nil
				if data.reason == "session_deleted" then deleted[id] = true end
			end
		end
	end)
	events.on("disconnected", function()
		pending.invalidate()
		M.clear()
	end)
	events.on("connected", function()
		sessions.refresh_status()
		for _, info in ipairs(state.get_active_sessions()) do
			local sid, token = info.id, pending.token(info.id)
			local snapshot = state.get_session_record(sid)
			reconcile(sid, true)
			client.get_session(sid, function(err, current)
				if not err and pending.is_current(token) and vim.deep_equal(snapshot, state.get_session_record(sid)) then sessions.remember(current, { touch = false }) end
			end)
		end
	end)
	events.on("v2_event", function(event)
		local data, kind = event.data, event.type
		local sid = data.sessionID
		if sid and deleted[sid] then return end
		if kind == "server.connected" then events.emit("server_connected", {}); return end
		if kind == "session.deleted" then
			deleted[sid] = true
			pending.clear_session(sid)
			recovery[sid] = nil
			sessions.handle_deleted(sid, { reason = "session_deleted" })
			return
		end
		if kind == "session.created" or kind == "session.renamed" or kind == "session.agent.selected"
			or kind == "session.model.selected" or kind == "session.moved" or kind == "session.usage.updated"
			or kind == "session.permissions" or kind == "session.viewed" or kind == "session.forked" then
			local info = vim.deepcopy(data)
			info.id, info.sessionID = sid, nil
			if info.location then info.directory = info.location.directory end
			info.time = { updated = event.created }
			if kind == "session.created" then info.time.created = event.created end
			sessions.remember(info, { touch = false })
			if kind == "session.renamed" and state.get_session().id == sid then
				sessions.set_active(sid, info.title, { reason = "session_renamed", preserve_cache = true, runtime = state.is_runtime_session(sid) })
			end
			changed(sid, "session")
		end
		if kind:match("^session%.revert%.") then
			sessions.remember({ id = sid, revert = data.revert or vim.NIL }, { touch = false })
			changed(sid, "session")
		end
		local effect = sync.handle_v2_event(event)
		if effect.revert_to then
			for id in pairs(pending.list(sid)) do
				if id >= effect.revert_to then pending.update(sid, id, { status = "cancelled" }) end
			end
		end
		if effect.inbox then pending.admit(effect.inbox) end
		if kind == "session.inbox.delivery.changed" then
			local item = pending.get(sid, data.inboxID)
			if item and item.inbox then
				item.inbox.delivery = data.delivery; pending.admit(item.inbox)
			else reconcile(sid) end
			changed(sid, "inbox")
		end
		if effect.delivered then pending.update(sid, effect.delivered, { status = "delivered" }) end
		if effect.delivered or effect.inbox then changed(sid, "inbox") end
		if effect.cancelled then pending.update(sid, effect.cancelled, { status = "cancelled" }) end
		if effect.status then sessions.set_session_status(sid, effect.status, { reason = kind }) end
		if effect.changed then
			local content_kind = kind:match("^session%.(text)%.delta$") or kind:match("^session%.(reasoning)%.delta$")
			if content_kind and type(data.delta) == "string" then
				events.emit("sync_changed", { kind = "part", action = "updated", session_id = sid,
					message_id = data.assistantMessageID, part_id = require("opencode.protocol.v2.messages").part_id(sid, data.assistantMessageID, content_kind, data.ordinal or 0),
					field = "text", delta = data.delta })
			else changed(sid) end
		end
		if effect.reconcile then reconcile(sid) end
		if kind:match("^session%.revert%.") or kind:match("^session%.compaction%.") or kind:match("^session%.shell%.")
			or kind == "session.skill.activated" then reconcile(sid) end
		if kind:match("%.updated$") or kind == "mcp.status.changed" or kind == "mcp.resources.changed" or kind == "credential.switched" then
			events.emit("catalog_invalidated", { type = kind, location = event.location })
		end
		-- Interactions retain the complete native envelope for their own adapters.
		if kind:match("^permission%.") or kind:match("^form%.") or kind:match("^rpc%.") then
			events.emit("v2_interaction", event)
		end
	end)
end

return M
