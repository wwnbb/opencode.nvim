describe("opencode processing footer", function()
	local processing_footer = require("opencode.ui.chat.processing_footer")
	local fallback = { role = "assistant", agent = "fallback", modelID = "fallback-model", providerID = "fallback-provider" }
	local function derive(status, messages, extra)
		return processing_footer.derive(vim.tbl_extend("force",
			{ status = status, messages = messages or {}, fallback_message = fallback }, extra or {}))
	end

	it("derives visibility from processing status and the pending response gap", function()
		for _, status in ipairs({ "busy", "retry" }) do
			assert.is_true(derive({ type = status }).animated)
		end
		assert.is_nil(derive("idle"))
		assert.is_nil(derive("busy", { { role = "assistant", time = { created = 1, completed = 2 }, finish = "stop", agent = "coder" } }))
		for _, message in ipairs({
			{ role = "user", time = { created = 1 } },
			{ role = "assistant", time = { created = 1, completed = 2 }, finish = "tool-calls", agent = "coder" },
		}) do
			assert.is_not_nil(derive("busy", { message }))
		end
	end)

	it("uses the newest authoritative metadata and falls back across placeholders", function()
		local previous = { id = "previous", role = "assistant", agent = "coder", modelID = "server-model",
			providerID = "server-provider", time = { created = 1, completed = 2 }, finish = "tool-calls" }
		local presentation = derive("busy", { previous, { id = "placeholder", role = "assistant", time = { created = 3 } } })
		assert.equals(previous, presentation.source_message)
		assert.equals("coder", presentation.message.agent)
		assert.is_nil(presentation.message.time)
		assert.is_nil(presentation.message.finish)
		presentation = derive("busy", {
			{ role = "assistant", agent = "old-agent", time = { created = 1, completed = 2 }, finish = "stop" },
			{ role = "user", time = { created = 3 } },
		})
		assert.equals(fallback, presentation.source_message)
	end)

	it("keeps the footer visible but static while waiting for interaction", function()
		local presentation = derive("busy", {}, { waiting_for_interaction = true })
		assert.is_not_nil(presentation)
		assert.is_false(presentation.animated)
	end)
end)
