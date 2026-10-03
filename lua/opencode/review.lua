-- Bundled diff review uses the official plugin RPC, never native permissions.
local M = {}
local edits = require("opencode.edit.state")
local pending = require("opencode.session.pending")
local function observed(path)
	local disk, err = require("opencode.artifact.changes").read_disk_bytes(path)
	if not disk then return nil, err end
	if disk.exists and disk.kind ~= "file" then
		return nil, "Path is now a " .. disk.kind .. "; cannot confirm review: " .. path
	end
	return { exists = disk.exists, sha256 = disk.exists and vim.fn.sha256(disk.content) or nil }
end

function M.reply(id, callback)
	local item = edits.get_edit(id)
	if not item or item.transport ~= "review_rpc" or not edits.begin_review_submission(id) then return false end
	local choices = {}
	for _, file in ipairs(item.files) do
		local choice = { fileID = file.file_id, status = file.status, apply = item.apply_mode or "client" }
		if file.status ~= "rejected" and choice.apply == "client" then
			local err
			choice.observed, err = observed(file.filepath)
			if err then
				edits.restore_review_submission(id, { message = err })
				if callback then callback({ message = err }) end
				return false
			end
		end
		choices[#choices + 1] = choice
	end
	local token = pending.token(item.session_id)
	local message = vim.trim(item.message or "")
	require("opencode.client").review_rpc("reviewReply", {
		protocolVersion = 2, sessionID = item.session_id, reviewID = id, revision = item.revision, decisions = choices,
		message = message ~= "" and message or nil,
	}, item.location.directory, function(err, record)
		if not pending.is_current(token) or edits.get_edit(id) ~= item then return end
		if item.status == "sent" then
			if callback then callback(item.cancelled and { message = "Review cancelled" } or nil, item.native_review) end
			return
		end
		if err then
			edits.restore_review_submission(id, err)
			require("opencode.events").emit("review_reconcile", { session_id = item.session_id })
		else edits.set_review_record(record) end
		if callback then callback(err, record) end
	end)
	return true
end

function M.accept_all(id, callback)
	local accepted, err = edits.accept_all(id)
	if not accepted then if callback then callback({ message = tostring(err) }) end; return false end
	return M.reply(id, callback)
end

return M
