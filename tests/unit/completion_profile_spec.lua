describe("completion model profiles", function()
	local profile = require("opencode.completion.profile")
	local function config()
		return {
			enabled = true,
			model = { providerID = "openai", modelID = "gpt-5.2" },
			options = { settings = { reasoningEffort = "none" }, body = { max_output_tokens = 256 } },
		}
	end

	it("requires an explicit model and rejects conflicting or invalid options", function()
		local model, err = profile.validate({})
		assert.is_nil(model)
		assert.matches("completion.model", err, 1, true)
		local value = config()
		value.variant = "fast"
		model, err = profile.validate(value)
		assert.is_nil(model)
		assert.matches("not both", err, 1, true)
		value.variant = nil
		value.options = { maxTokens = 10 }
		assert.is_nil(profile.validate(value))
		value.options = { settings = function() end }
		assert.is_nil(profile.validate(value))
		value.options = { headers = { ["X-Test"] = 1 } }
		assert.is_nil(profile.validate(value))
		value.options = { body = { callback = function() end } }
		assert.is_nil(profile.validate(value))
		value.options = { settings = { nan = 0 / 0 } }
		assert.is_nil(profile.validate(value))
		value.options.settings.cycle = value.options
		assert.is_nil(profile.validate(value))
	end)

	it("uses a configured named variant with an external server", function()
		local value = { model = { providerID = "local", id = "coder" }, variant = "fast" }
		assert.same({ providerID = "local", id = "coder", variant = "fast" }, profile.resolve(value, { managed = false }))
		local model, err = profile.validate(config(), { managed = false })
		assert.is_nil(model)
		assert.matches("external server", err, 1, true)
	end)

	it("merges a private variant while preserving existing JSONC config and strings", function()
		local existing = [=[
{
  // A line comment
  "model": "openai/gpt-5.2",
  "instructions": ["https://example.test/*abc*/,}", "escaped \" // still string",],
  "providers": {
    "openai": { /* a block comment */
      "settings": { "baseURL": "http://localhost:1234/v1" },
      "models": {
        "gpt-5.2": { "body": { "store": false }, "variants": [{ "id": "chat", "body": { "foo": [1,2,], }, },], },
        "other": { "variants": [] },
      },
    },
  },
}
]=]
		local overlay, snapshot, err = profile.prepare(config(), existing)
		assert.is_nil(err)
		local decoded = vim.json.decode(overlay)
		assert.equals("openai/gpt-5.2", decoded.model)
		assert.same({ "https://example.test/*abc*/,}", 'escaped " // still string' }, decoded.instructions)
		assert.equals("http://localhost:1234/v1", decoded.providers.openai.settings.baseURL)
		assert.same({}, decoded.providers.openai.models.other.variants)
		local model = decoded.providers.openai.models["gpt-5.2"]
		assert.same({ store = false }, model.body)
		assert.same({ id = "chat", body = { foo = { 1, 2 } } }, model.variants[1])
		assert.same({ id = snapshot.variant, settings = { reasoningEffort = "none" }, body = { max_output_tokens = 256 } }, model.variants[2])
		assert.is_true(profile.is_private_variant(snapshot.variant))
		assert.same({ providerID = "openai", id = "gpt-5.2", variant = snapshot.variant }, profile.resolve(config(), { managed = true, active = snapshot }))
	end)

	it("keeps disabled or absent options from rewriting the environment", function()
		local value = config()
		value.enabled = false
		local overlay, snapshot, err = profile.prepare(value, "{ // unchanged\n}")
		assert.equals("{ // unchanged\n}", overlay)
		assert.is_nil(snapshot)
		assert.is_nil(err)
		assert.is_nil(profile.prepare(nil, nil))
	end)

	it("does not overwrite user variants even if their name collides", function()
		local first, initial = profile.prepare(config())
		local source = vim.json.decode(first)
		source.providers.openai.models["gpt-5.2"].variants[1].body = { unrelated = true }
		local overlay, snapshot = profile.prepare(config(), vim.json.encode(source))
		assert.are_not.equals(initial.variant, snapshot.variant)
		assert.equals(initial.fingerprint, snapshot.fingerprint)
		local variants = vim.json.decode(overlay).providers.openai.models["gpt-5.2"].variants
		assert.same({ unrelated = true }, variants[1].body)
		assert.equals(initial.variant, variants[1].id)
		assert.equals(snapshot.variant, variants[2].id)
	end)

	it("uses stable fingerprints and requires restart after model or options change", function()
		local value = config()
		value.options.settings.temperature = 0.1
		local _, snapshot = profile.prepare(value)
		local reordered = config()
		reordered.options = { body = { max_output_tokens = 256 }, settings = { temperature = 0.1, reasoningEffort = "none" } }
		assert.is_truthy(profile.resolve(reordered, { managed = true, active = snapshot }))
		reordered.options.body.max_output_tokens = 512
		local model, err = profile.resolve(reordered, { managed = true, active = snapshot })
		assert.is_nil(model)
		assert.matches("restart", err, 1, true)
		reordered = vim.deepcopy(value)
		reordered.model.modelID = "other"
		assert.is_nil(profile.resolve(reordered, { managed = true, active = snapshot }))
		assert.is_nil(profile.resolve(value, { managed = true }))
	end)

	it("keeps completion and explanation variants independent on the same model", function()
		local completion = config()
		local explanation = vim.deepcopy(completion)
		local first, completion_snapshot = profile.prepare(completion)
		local combined, explanation_snapshot = profile.prepare(explanation, first, "explanation")
		local variants = vim.json.decode(combined).providers.openai.models["gpt-5.2"].variants
		assert.equals(2, #variants)
		assert.equals(completion_snapshot.variant, variants[1].id)
		assert.equals(explanation_snapshot.variant, variants[2].id)
		assert.are_not.equals(completion_snapshot.variant, explanation_snapshot.variant)
		assert.is_true(profile.is_private_variant(completion_snapshot.variant, "completion"))
		assert.is_true(profile.is_private_variant(explanation_snapshot.variant, "explanation"))
		assert.is_true(profile.is_private_variant(explanation_snapshot.variant))
		assert.is_false(profile.is_private_variant(explanation_snapshot.variant, "completion"))
		assert.equals(completion_snapshot.variant, profile.resolve(completion, { managed = true, active = completion_snapshot }).variant)
		assert.equals(explanation_snapshot.variant, profile.resolve(explanation, { managed = true, active = explanation_snapshot }, "explanation").variant)
		local model, err = profile.resolve(explanation, { managed = true, active = completion_snapshot }, "explanation")
		assert.is_nil(model)
		assert.matches("explanation.options", err, 1, true)
	end)

	it("validates explanation options and preserves the other overlay on failure", function()
		local value = config()
		local first, snapshot = profile.prepare(value)
		local invalid = vim.deepcopy(value)
		invalid.variant = "fast"
		local overlay, active, err = profile.prepare(invalid, first, "explanation")
		assert.equals(first, overlay)
		assert.is_nil(active)
		assert.matches("explanation.variant", err, 1, true)
		assert.equals(snapshot.variant, profile.resolve(value, { managed = true, active = snapshot }).variant)
		local model, external_error = profile.validate(value, { managed = false }, "explanation")
		assert.is_nil(model)
		assert.matches("explanation.options", external_error, 1, true)
		local named = { model = value.model, variant = "brief" }
		assert.same({ providerID = "openai", id = "gpt-5.2", variant = "brief" }, profile.resolve(named, { managed = false }, "explanation"))
	end)

	it("distinguishes nested empty JSON arrays and objects when options change", function()
		local value = config()
		value.options.body.labels = {}
		local _, snapshot = profile.prepare(value)
		value.options.body.labels = vim.empty_dict()
		assert.is_nil(profile.resolve(value, { managed = true, active = snapshot }))
	end)

	it("leaves invalid environment overlays untouched and reports isolated errors", function()
		for _, source in ipairs({ "{ /* unfinished", "not json", "[]", '{"providers":[]}', '{"providers":false}', '{"providers":{"openai":{"models":{"gpt-5.2":{"variants":{}}}}}}' }) do
			local overlay, snapshot, err = profile.prepare(config(), source)
			assert.equals(source, overlay)
			assert.is_nil(snapshot)
			assert.is_string(err)
			local model, resolved_error = profile.resolve(config(), { managed = true, error = err })
			assert.is_nil(model)
			assert.equals(err, resolved_error)
		end
	end)

	it("does not expose generated variants in the chat model catalog", function()
		local _, snapshot = profile.prepare(config())
		local _, explanation_snapshot = profile.prepare(config(), nil, "explanation")
		local providers = { { id = "openai" } }
		local models = { { id = "gpt-5.2", providerID = "openai", enabled = true, variants = {
			{ id = "fast", body = {} }, { id = snapshot.variant }, { id = explanation_snapshot.variant }, { id = "high" },
		} } }
		local result = require("opencode.protocol.v2.catalogs").providers(providers, models)
		local model = result.providers[1].models["gpt-5.2"]
		assert.same({ "fast", "high" }, model.variant_order)
		assert.is_nil(model.variants[snapshot.variant])
		assert.is_nil(model.variants[explanation_snapshot.variant])
		assert.equals(4, #models[1].variants)
	end)
end)
