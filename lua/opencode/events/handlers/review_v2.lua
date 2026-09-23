local M = {}
function M.setup(events)
	local state = require("opencode.state")
	local edits = require("opencode.edit.state")
	local pending = require("opencode.session.pending")
	local client = require("opencode.client")
	local util = require("opencode.events.util")
	local function relevant(sid) return sid and (state.get_session().id == sid or util.runtime_root_for_session(sid)) end
	local function changed(record)
		events.emit("interaction_changed", { kind = "edit", action = record.status, id = record.reviewID, session_id = record.sessionID })
	end
	local review_terminal = {}
	local function upsert(record)
		if type(record) ~= "table" or record.protocolVersion ~= 2 or not relevant(record.sessionID) then return end
		if record.status == "pending" and review_terminal[record.reviewID] then return end
		if record.status == "cancelled" or record.status == "settled" or record.status == "decided" then review_terminal[record.reviewID] = true end
		if not edits.get_edit(record.reviewID) then
			if record.status ~= "pending" then return end
			edits.add_edit(record.reviewID, record.sessionID, record.files, {
				transport = "review_rpc", review_id = record.reviewID, revision = record.revision,
				location = record.location, native_review = record, data = record, metadata = record.metadata,
				message_id = record.messageID, call_id = record.callID, timestamp = record.created / 1000,
			})
			events.emit("edit_pending", { permission_id = record.reviewID, session_id = record.sessionID, file_count = #record.files })
			if state.is_danger_mode_enabled() then
				require("opencode.review").accept_all(record.reviewID, function(err)
					if err then vim.notify("OpenCode review failed: " .. (err.message or "unknown error"), vim.log.levels.ERROR) end
					changed(record)
				end)
			end
		end
		edits.set_review_record(record)
		changed(record)
	end
	local policy_busy, policy_terminal = {}, {}
	local capability_notices = {}
	local function policy(record)
		if type(record) ~= "table" or record.protocolVersion ~= 2 or not relevant(record.sessionID) then return end
		local id, sid = record.gateID, record.sessionID
		if record.status ~= "pending" then policy_terminal[id] = true; policy_busy[id] = nil; return end
		if policy_terminal[id] or policy_busy[id] then return end
		local token = pending.token(sid)
		policy_busy[id] = token
		local function current() return pending.is_current(token) and policy_busy[id] == token and not policy_terminal[id] end
		local function finish(err)
			if not current() then return end
			policy_busy[id] = nil
			if err then vim.notify("OpenCode tool permission: " .. (err.message or "request failed"), vim.log.levels.ERROR) end
		end
		local function confirm(denied)
			client.review_rpc("policyConfirm", { sessionID = sid, gateID = id, denied = denied }, record.location.directory,
				function(err, result)
					if not current() then return end
					finish(err)
					if not err and result.status ~= "pending" then policy_terminal[id] = true end
				end)
		end
		-- Reconnect must not recreate an already pending native permission.
		client.get_permission(sid, record.request.id, function(err)
			if not current() then return end
			if not err then finish(); return end
			if err.status ~= 404 then finish(err); return end
			client.create_permission(sid, record.request, function(create_err, result)
				if not current() then return end
				if create_err then finish(create_err); return end
				if result.effect == "ask" then finish() else confirm(result.effect == "deny") end
			end)
		end)
	end
	events.on("disconnected", function() policy_busy = {} end)
	local function recover(sid)
		if not relevant(sid) then return end
		local directory = state.get_session_directory(sid)
		if type(directory) ~= "string" or directory == "" then return end
		local token = pending.token(sid)
		client.review_rpc("capabilities", vim.empty_dict(), directory, function(err, capability)
			if not pending.is_current(token) then return end
			if err or type(capability) ~= "table" or capability.protocolVersion ~= 2 or capability.review ~= true or capability.todo ~= true then
				if not capability_notices[directory] then
					capability_notices[directory] = true
					vim.notify("OpenCode: bundled server plugin unavailable or outdated. Run scripts/install-tools.sh for this server's config, then reconnect. File review and persistent todos require plugin 2.0.11-3; history remains readable.", vim.log.levels.WARN)
				end
				return
			end
			capability_notices[directory] = nil
			client.review_rpc("policyList", { sessionID = sid }, directory, function(policy_err, records)
				if policy_err or not pending.is_current(token) then return end
				for _, record in ipairs(records) do policy(record) end
			end)
			client.review_rpc("reviewList", { sessionID = sid }, directory, function(list_err, result)
				if list_err or not pending.is_current(token) then return end
				local present = {}
				for _, record in ipairs(result.reviews) do present[record.reviewID] = true; upsert(record) end
				for _, item in ipairs(edits.get_all_active()) do
					if item.transport == "review_rpc" and item.session_id == sid and not present[item.review_id] then
						client.review_rpc("reviewGet", { sessionID = sid, reviewID = item.review_id }, item.location.directory, function(detail_err, record)
							if not pending.is_current(token) then return end
							if not detail_err then upsert(record)
							elseif detail_err.code == "RpcError" and detail_err.rpc_type == "not_found" then
								local cancelled = vim.deepcopy(item.native_review)
								cancelled.status = "cancelled"
								upsert(cancelled)
							end
						end)
					end
				end
			end)
		end)
	end
	for _, kind in ipairs({ "connected", "session_change" }) do
		events.on(kind, function()
			local seen = {}
			for _, info in ipairs(state.get_active_sessions()) do
				for _, sid in ipairs(require("opencode.sync").collect_session_tree(info.id)) do
					if not seen[sid] then seen[sid] = true; recover(sid) end
				end
			end
		end)
	end
	events.on("review_reconcile", function(data) recover(data.session_id) end)
	events.on("v2_interaction", function(event)
		if event.type:match("^rpc%.opencode_nvim%.review") then upsert(event.data.review) end
		if event.type:match("^rpc%.opencode_nvim%.policy") then policy(event.data.policy) end
	end)
end
return M
