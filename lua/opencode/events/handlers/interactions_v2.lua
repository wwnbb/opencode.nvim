local M = {}

function M.setup(events)
	local permissions = require("opencode.permission.state")
	local forms = require("opencode.question.state")
	local pending = require("opencode.session.pending")
	local state = require("opencode.state")
	local util = require("opencode.events.util")
	local client = require("opencode.client")
	local terminal, revision = {}, 0
	local function key(kind, id) return kind .. ":" .. id end
	local function relevant(sid)
		return sid and (state.get_session().id == sid or util.runtime_root_for_session(sid))
	end
	local function changed(kind, id, sid, action)
		events.emit("interaction_changed", { kind = kind, id = id, session_id = sid, action = action })
	end
	local function add_permission(data, location, created)
		if not relevant(data.sessionID) or terminal[key("permission", data.id)] then return end
		data = vim.deepcopy(data)
		data._location, data.time = location, { created = created }
		local request = require("opencode.events.handlers.permission_flow.request").decode(data)
		if request then
			require("opencode.events.handlers.permission_flow.non_edit").handle(events, request, state.get_session(), require("opencode.logger"))
		end
	end
	local function add_form(data, location, created)
		if not relevant(data.sessionID) or terminal[key("form", data.id)] then return end
		forms.add_form(data, { location = location, timestamp = created and created / 1000 })
		changed("question", data.id, data.sessionID, "pending")
	end
	local function recover(sid)
		if not relevant(sid) then return end
		local token, rev = pending.token(sid), revision
		local pg, fg = permissions.get_generation(), forms.get_generation()
		local function current() return pending.is_current(token) and rev == revision and relevant(sid) end
		client.list_permissions({ session_id = sid }, function(err, list)
			if err or not current() or pg ~= permissions.get_generation() then return end
			local present = {}
			for _, data in ipairs(list) do
				if data.sessionID == sid then present[data.id] = true; add_permission(data) end
			end
			for _, item in ipairs(permissions.get_all_active()) do
				if item.session_id == sid and item.protocol == "v2" and not present[item.permission_id] then
					local id = item.permission_id
					client.get_permission(sid, id, function(detail_err)
						if current() and pg == permissions.get_generation() and detail_err and detail_err.status == 404 then
							terminal[key("permission", id)] = true
							permissions.mark_unavailable(id)
							changed("permission", id, sid, "unavailable")
						end
					end)
				end
			end
		end)
		client.list_questions({ session_id = sid }, function(err, list)
			if err or not current() or fg ~= forms.get_generation() then return end
			local present = {}
			for _, form in ipairs(list) do
				if form.sessionID == sid then present[form.id] = true; add_form(form) end
			end
			for _, item in ipairs(forms.get_all_active()) do
				if item.session_id == sid and item.protocol == "v2" and (not present[item.request_id] or item.submitting or item.server_error) then
					local id = item.request_id
					client.get_form(sid, id, function(detail_err, detail)
						if not current() or fg ~= forms.get_generation() or terminal[key("form", id)] then return end
						if not detail_err then
							forms.apply_form_detail(detail)
							if detail.state.status ~= "pending" then terminal[key("form", id)] = true end
							changed("question", id, sid, detail.state.status)
						elseif detail_err.status == 404 then
							forms.mark_rejected(id)
							terminal[key("form", id)] = true
							changed("question", id, sid, "unavailable")
						end
					end)
				end
			end
		end)
	end
	local function recover_all()
		local visited = {}
		local function visit(sid)
			if sid and not visited[sid] then visited[sid] = true; recover(sid) end
		end
		visit(state.get_session().id)
		for _, info in ipairs(state.get_active_sessions()) do
			for _, sid in ipairs(require("opencode.sync").collect_session_tree(info.id)) do visit(sid) end
		end
		for _, info in ipairs(permissions.get_all_active()) do visit(info.session_id) end
		for _, info in ipairs(forms.get_all_active()) do visit(info.session_id) end
	end
	for _, kind in ipairs({ "connected", "session.selected" }) do events.on(kind, recover_all) end
	events.on("interaction_reconcile", function(data) recover(data.session_id) end)
	events.on("disconnected", function() revision = revision + 1 end)
	events.on("v2_interaction", function(event)
		local data, kind = event.data, event.type
		if kind == "permission.asked" then add_permission(data, event.location, event.created)
		elseif kind == "permission.replied" then
			terminal[key("permission", data.requestID)] = true
			require("opencode.events.handlers.permission_flow.lifecycle").handle_permission_replied(events, data, require("opencode.logger"))
		elseif kind == "form.created" then add_form(data.form, event.location, event.created)
		elseif kind == "form.replied" or kind == "form.cancelled" then
			terminal[key("form", data.id)] = true
			if kind == "form.replied" then forms.mark_answered(data.id, data.answer)
			else forms.mark_rejected(data.id) end
			changed("question", data.id, data.sessionID, kind == "form.replied" and "answered" or "rejected")
		end
	end)
end

return M
