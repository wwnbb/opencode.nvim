local M = {}

local util = require("opencode.events.util")

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
				timestamp = timestamp,
			})

			-- Stop the spinner so user can interact with the question
			local spinner_ok, spinner = pcall(require, "opencode.ui.spinner")
			if spinner_ok and spinner.is_active() then
				spinner.stop()
				logger.debug("Stopped spinner for question interaction")
			end

			-- Add to chat as a special message
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.add_question_message then
				chat.add_question_message(request_id, questions, "pending", {
					message_id = message_id,
					source_session_id = session_id,
					timestamp = timestamp,
				})
			end

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

			-- Update chat UI
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.update_question_status then
				chat.update_question_status(request_id, "answered", data.answers)
			end

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

			-- Update chat UI
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.update_question_status then
				chat.update_question_status(request_id, "rejected")
			end

			logger.debug("Question rejected", { request_id = request_id:sub(1, 10) })
		end)
	end)

	-- Clear questions on session change (skip when navigating into child sessions)
	events.on("session_change", function()
		local chat_ok, chat = pcall(require, "opencode.ui.chat")
		local is_navigating = chat_ok and chat.is_navigating and chat.is_navigating()
		if not is_navigating then
			question_state.clear_all()
		end
	end)
end

return M
