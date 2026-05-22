local M = {}

local util = require("opencode.events.util")

local function stop_spinner_for_current_question(current_session_id, question_session_id, logger)
	if not util.permission_session_is_relevant(current_session_id, question_session_id) then
		return
	end

	local spinner_ok, spinner = pcall(require, "opencode.ui.spinner")
	if spinner_ok and spinner.is_active and spinner.is_active() then
		spinner.stop()
		if logger then
			logger.debug("Stopped spinner for question interaction", {
				session_id = question_session_id,
				current_session_id = current_session_id,
			})
		end
	end
end

function M.setup(events)
	local state = require("opencode.state")
	local question_state = require("opencode.question.state")

	-- Handle question.asked - store question and trigger UI update
	events.on("question_asked", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local logger = require("opencode.logger")
			logger.debug("Question asked event received", { data = data })

			local request_id = data.requestID or data.id
			local session_id = data.sessionID
			local message_id = util.resolve_event_message_id(data)
			local call_id = util.resolve_event_call_id(data)
			local questions = data.questions
			local timestamp = util.event_time_to_seconds(data.time and data.time.created)

			if not request_id or not questions then
				logger.warn(
					"Invalid question data",
					{ data = data, request_id = request_id, has_questions = questions ~= nil }
				)
				return
			end

			local current_session = state.get_session()
			if message_id then
				local ok_sync, sync = pcall(require, "opencode.sync")
				if ok_sync and sync.find_message_session_id then
					session_id = sync.find_message_session_id(message_id) or session_id
				end
			end
			session_id = session_id or (current_session and current_session.id) or ""

			-- Store question state (allow questions from subagent/child sessions)
			question_state.add_question(request_id, session_id, questions, {
				message_id = message_id,
				call_id = call_id,
				timestamp = timestamp,
			})
			events.emit("question_pending", {
				request_id = request_id,
				questions_count = #questions,
				session_id = session_id,
				message_id = message_id,
				call_id = call_id,
			})
			events.emit("interaction_changed", {
				kind = "question",
				action = "pending",
				id = request_id,
				session_id = session_id,
			})

			-- Stop the spinner only when the question belongs to the visible session.
			stop_spinner_for_current_question(current_session and current_session.id, session_id, logger)

			logger.info("Question added", { request_id = request_id:sub(1, 10), count = #questions })
		end)
	end)

	-- Handle question.replied - mark as answered
	events.on("question_replied", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local logger = require("opencode.logger")
			local request_id = data.requestID

			if not request_id then
				return
			end

			-- Mark as answered
			question_state.mark_answered(request_id, data.answers)
			events.emit("question_answered", {
				request_id = request_id,
				answers = data.answers,
			})
			events.emit("interaction_changed", {
				kind = "question",
				action = "answered",
				id = request_id,
			})

			logger.debug("Question answered", { request_id = request_id:sub(1, 10) })
		end)
	end)

	-- Handle question.rejected - mark as rejected
	events.on("question_rejected", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local logger = require("opencode.logger")
			local request_id = data.requestID

			if not request_id then
				return
			end

			-- Mark as rejected
			question_state.mark_rejected(request_id)
			events.emit("interaction_changed", {
				kind = "question",
				action = "rejected",
				id = request_id,
			})

			logger.debug("Question rejected", { request_id = request_id:sub(1, 10) })
		end)
	end)

	-- Clear questions on session change unless the session boundary marks this
	-- as a cache-preserving navigation.
	events.on("session_change", function(data)
		if data and data.preserve_cache then
			return
		end
		local removed = question_state.clear_all()
		for _, request_id in ipairs(removed or {}) do
			events.emit("question_removed", { request_id = request_id })
		end
	end)
end

return M
