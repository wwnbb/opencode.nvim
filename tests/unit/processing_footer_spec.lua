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
	it("keeps the last footer complete and animated while background subagents work", function()
		local last = { id = "last", role = "assistant", agent = "coder", modelID = "m", providerID = "p",
			time = { created = 1, completed = 2 }, finish = "stop", tokens = { input = 1 } }
		local messages = { { id = "u", role = "user", time = { created = 0 } }, last }
		assert.is_nil(derive("idle", messages))
		local presentation = derive("idle", messages, { delegated = { working = true } })
		assert.equals(last, presentation.message)
		assert.equals(last, presentation.source_message)
		assert.is_true(presentation.animated)
		assert.is_true(presentation.delegated)
		-- Subagents that only wait for the user keep the footer, without a spinner.
		assert.is_false(derive("idle", messages, { delegated = { working = false } }).animated)
		assert.is_false(derive("idle", messages, { delegated = { working = true }, waiting_for_interaction = true }).animated)
		-- An unsettled history falls back to the metadata projection.
		presentation = derive("idle", { { id = "u", role = "user" } }, { delegated = { working = true } })
		assert.equals(fallback, presentation.source_message)
		assert.equals("fallback", presentation.message.agent)
		-- The session's own execution still decides when it is processing.
		assert.is_nil(derive("busy", messages, { delegated = { working = true } }))
	end)
end)
