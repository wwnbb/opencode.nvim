describe("opencode processing footer", function()
	local processing_footer

	before_each(function()
		vim.opt.runtimepath:append(vim.fn.getcwd())
		processing_footer = require("opencode.ui.chat.processing_footer")
	end)

	local fallback = {
		role = "assistant",
		agent = "fallback",
		modelID = "fallback-model",
		providerID = "fallback-provider",
	}

	it("derives visibility from authoritative processing status and response gap", function()
		for _, status in ipairs({ "busy", "streaming", "thinking", "retry" }) do
			local presentation = processing_footer.derive({
				status = { type = status },
				messages = {},
				fallback_message = fallback,
			})
			assert(presentation, status .. " should produce a processing footer")
			assert(presentation.animated == true, status .. " should animate without an interaction")
		end

		assert(
			processing_footer.derive({ status = "idle", messages = {}, fallback_message = fallback }) == nil,
			"idle should not produce a processing footer"
		)
		assert(
			processing_footer.derive({
				status = "busy",
				messages = {
					{
						role = "assistant",
						time = { created = 1, completed = 2 },
						finish = "stop",
						agent = "coder",
					},
				},
				fallback_message = fallback,
			}) == nil,
			"a completed final assistant should not get a duplicate processing footer"
		)
	end)

	it("covers tool-call, empty assistant, and user-to-assistant gaps", function()
		local cases = {
			{
				{ role = "user", time = { created = 1 } },
			},
			{
				{ role = "assistant", time = { created = 1 }, agent = "coder" },
			},
			{
				{
					role = "assistant",
					time = { created = 1, completed = 2 },
					finish = "tool-calls",
					agent = "coder",
				},
			},
		}
		for _, messages in ipairs(cases) do
			assert(
				processing_footer.derive({ status = "busy", messages = messages, fallback_message = fallback }),
				"pending response gap should produce a footer"
			)
		end
	end)

	it("uses the newest authoritative metadata and falls back across placeholders", function()
		local previous = {
			id = "previous",
			role = "assistant",
			agent = "coder",
			modelID = "server-model",
			providerID = "server-provider",
			time = { created = 1, completed = 2 },
			finish = "tool-calls",
		}
		local placeholder = {
			id = "placeholder",
			role = "assistant",
			time = { created = 3 },
		}
		local presentation = processing_footer.derive({
			status = "busy",
			messages = { previous, placeholder },
			fallback_message = fallback,
		})
		assert(presentation.source_message == previous, "metadata-free placeholder should reuse server metadata")
		assert(presentation.message.agent == "coder", "processing footer should project the server agent")
		assert(presentation.message.modelID == "server-model", "processing footer should project the server model")
		assert(presentation.message.time == nil, "processing footer should not inherit completed duration")
		assert(presentation.message.finish == nil, "processing footer should not inherit terminal state")

		presentation = processing_footer.derive({
			status = "busy",
			messages = { { role = "user", time = { created = 1 } } },
			fallback_message = fallback,
		})
		assert(presentation.source_message == fallback, "missing assistant metadata should use local fallback")

		presentation = processing_footer.derive({
			status = "busy",
			messages = {
				{
					role = "assistant",
					agent = "old-agent",
					modelID = "old-model",
					time = { created = 1, completed = 2 },
					finish = "stop",
				},
				{ role = "user", time = { created = 3 } },
			},
			fallback_message = fallback,
		})
		assert(presentation.source_message == fallback, "new user turn should not reuse stale assistant metadata")
	end)

	it("keeps the footer visible but static while waiting for interaction", function()
		local presentation = processing_footer.derive({
			status = "busy",
			messages = {},
			waiting_for_interaction = true,
			fallback_message = fallback,
		})
		assert(presentation, "interaction should not hide the processing footer")
		assert(presentation.animated == false, "interaction should pause only the animation")
	end)
end)
