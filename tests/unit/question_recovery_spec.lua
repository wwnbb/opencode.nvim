describe("opencode question recovery", function()
	local state = require("opencode.state")
	local sync = require("opencode.sync")
	local questions = require("opencode.question.state")
	local client = require("opencode.client")
	local bus = require("opencode.events.bus")
	local original_list, original_messages, requests
	local directory = "/tmp/opencode-question-recovery"
	local prompt = { { question = "Continue?", options = { { label = "Yes" } } } }

	local function request(id, session_id, call_id)
		return {
			id = id, sessionID = session_id or "root", messageID = "message", callID = call_id or id,
			questions = vim.deepcopy(prompt),
		}
	end

	local function wait_for(predicate)
		assert.is_true(vim.wait(500, predicate, 5))
	end

	local function recover(event)
		bus.emit(event, {})
		wait_for(function() return #requests > 0 end)
	end

	before_each(function()
		state.reset()
		sync.clear_all()
		questions.clear_all()
		bus.clear()
		state.upsert_session({ id = "root", directory = directory })
		state.set_session("root", "Root")
		requests = {}
		original_list, original_messages = client.list_questions, client.get_messages
		client.list_questions = function(opts, callback)
			table.insert(requests, { directory = opts.directory, callback = callback })
		end
		require("opencode.events.handlers.question").setup(bus)
	end)

	after_each(function()
		client.list_questions, client.get_messages = original_list, original_messages
		questions.clear_all()
		sync.clear_all()
		state.reset()
		bus.clear()
		bus.clear_history()
	end)

	it("recovers questions in all open projects on reconnect, including known children", function()
		state.upsert_session({ id = "background", directory = directory .. "/other" })
		state.set_session("background", "Background")
		state.set_session("root", "Root")
		sync.record_task_child_session("root", "parent-message", "task-part", "child")
		recover("connected")
		assert.equals(2, #requests)
		for _, fetch in ipairs(requests) do
			if fetch.directory == state.normalize_directory(directory) then
				fetch.callback(nil, {
					request("root-question"), request("child-question", "child"),
					request("foreign-question", "unopened"), { id = "missing-session", questions = prompt },
				})
			else
				assert.equals(state.normalize_directory(directory .. "/other"), fetch.directory)
				fetch.callback(nil, { request("background-question", "background") })
			end
		end
		wait_for(function() return questions.get_question_count() == 3 end)
		assert.is_true(questions.has_question("root-question"))
		assert.is_true(questions.has_question("child-question"))
		assert.is_true(questions.has_question("background-question"))
		assert.is_false(questions.has_question("foreign-question"))
		assert.is_false(questions.has_question("missing-session"))
	end)

	it("recovers an already waiting question when switching to HTTP-loaded history", function()
		client.get_messages = function(session_id, _, callback)
			callback(nil, { {
				info = { id = "waiting-message", sessionID = session_id, role = "assistant", time = { created = 1 } },
				parts = { {
					id = "waiting-part", type = "tool", tool = "question", callID = "waiting-call",
					state = { status = "running", input = { questions = prompt } },
				} },
			} })
		end
		require("opencode.session").switch_to({ id = "waiting", directory = directory })
		wait_for(function() return #requests == 1 and sync.get_part("waiting-message", "waiting-part") ~= nil end)
		requests[1].callback(nil, { request("waiting-question", "waiting", "waiting-call") })
		wait_for(function() return questions.has_question("waiting-question") end)
	end)

	it("matches concurrent calls by call ID even with identical message IDs and questions", function()
		bus.emit("tool_update", {
			tool_name = "question", status = "running", session_id = "root", message_id = "message",
			call_id = "second-call", input = { questions = prompt },
		})
		wait_for(function() return #requests == 1 end)
		requests[1].callback(nil, { request("first", "root", "first-call"), request("second", "root", "second-call") })
		wait_for(function() return questions.has_question("second") end)
		assert.is_false(questions.has_question("first"))
	end)

	it("still recovers legacy questions without tool identity using session and content", function()
		bus.emit("tool_update", {
			tool_name = "question", status = "running", session_id = "root", message_id = "message",
			call_id = "legacy-call", input = { questions = prompt },
		})
		wait_for(function() return #requests == 1 end)
		requests[1].callback(nil, { { id = "legacy", sessionID = "root", questions = prompt } })
		wait_for(function() return questions.has_question("legacy") end)
		assert.equals("legacy-call", questions.get_question("legacy").call_id)
	end)

	it("preserves user selections and resolved status when a recovery response arrives later", function()
		questions.add_question("existing", "root", prompt)
		questions.select_option("existing", 1)
		recover("connected")
		requests[1].callback(nil, { request("existing") })
		wait_for(function() return questions.get_question("existing").call_id == "existing" end)
		assert.same({ { "Yes" } }, questions.get_answers("existing"))
		questions.mark_answered("existing", { { "Yes" } })
		requests[1].callback(nil, { request("existing") })
		vim.wait(20)
		assert.equals("answered", questions.get_question("existing").status)
	end)

	it("ignores recovery responses after transient state reset", function()
		recover("connected")
		questions.clear_all()
		requests[1].callback(nil, { request("stale") })
		vim.wait(20)
		assert.is_false(questions.has_question("stale"))
	end)

	it("cancels queued recovery when transient state is reset before dispatch", function()
		bus.emit("connected", {})
		questions.clear_all()
		vim.wait(20)
		assert.equals(0, #requests)
	end)

	for _, event in ipairs({ "question_replied", "question_rejected" }) do
		it("does not resurrect a question resolved by " .. event .. " during recovery", function()
			recover("connected")
			bus.emit(event, { requestID = "resolved-elsewhere", answers = { { "Yes" } } })
			requests[1].callback(nil, { request("resolved-elsewhere"), request("still-pending") })
			wait_for(function() return questions.has_question("still-pending") end)
			assert.is_false(questions.has_question("resolved-elsewhere"))
			assert.equals(1, bus.listener_count(event))
		end)
	end

	it("ignores a closed session without discarding another open session's questions", function()
		state.upsert_session({ id = "keep", directory = directory })
		state.set_session("keep", "Keep")
		recover("connected")
		state.close_runtime_session("root")
		requests[1].callback(nil, { request("closed-question"), request("keep-question", "keep") })
		wait_for(function() return questions.has_question("keep-question") end)
		assert.is_false(questions.has_question("closed-question"))
	end)

	it("preserves existing questions when reconciliation fails", function()
		questions.add_question("existing", "root", prompt)
		recover("connected")
		requests[1].callback({ message = "offline" })
		vim.wait(20)
		assert.is_true(questions.has_question("existing"))
	end)
end)
