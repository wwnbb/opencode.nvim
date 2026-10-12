local owner = require("opencode.question.state")

describe("question selection state", function()
	before_each(function() owner.clear_all() end)
	after_each(function() owner.clear_all() end)

	for _, required in ipairs({ false, true }) do
		it("updates and clears a multiselect with required=" .. tostring(required), function()
			local item = owner.add_form({ id = "multi", sessionID = "s", fields = {
				{ key = "choices", type = "multiselect", required = required,
					options = { { label = "A", value = "a" } } },
			} })
			assert.is_true(owner.update_selection("multi", 1, { 1 }))
			assert.is_true(item.selections[1].is_answered)
			assert.same({ choices = { "a" } }, owner.get_answers("multi"))
			assert.is_true(owner.validate_form("multi"))

			assert.is_true(owner.update_selection("multi", 1, {}))
			assert.is_false(item.selections[1].is_answered)
			assert.same({}, owner.get_answers("multi"))
			assert.equals(not required, owner.validate_form("multi"))
		end)
	end

	it("marks a required single choice answered when updated directly", function()
		owner.add_form({ id = "required", sessionID = "s", fields = {
			{ key = "choice", type = "string", required = true,
				options = { { label = "A", value = "a" } } },
		} })
		assert.equals(0, owner.get_answered_count("required"))
		assert.is_true(owner.update_selection("required", 1, { 1 }))
		assert.equals(1, owner.get_answered_count("required"))
		assert.same({ choice = "a" }, owner.get_answers("required"))
	end)

	it("retains a custom multiselect answer when preset selections are cleared", function()
		local item = owner.add_form({ id = "custom", sessionID = "s", fields = {
			{ key = "choices", type = "multiselect", custom = true,
				options = { { label = "A", value = "a" } } },
		} })
		owner.set_custom_input("custom", 1, "other")
		owner.update_selection("custom", 1, { 1 })
		assert.same({ choices = { "a", "other" } }, owner.get_answers("custom"))
		owner.update_selection("custom", 1, {})
		assert.is_true(item.selections[1].is_answered)
		assert.same({ choices = { "other" } }, owner.get_answers("custom"))
		owner.set_custom_input("custom", 1, "")
		assert.is_false(item.selections[1].is_answered)
		assert.same({}, owner.get_answers("custom"))
	end)

	it("keeps an empty optional single answer and replaces custom input with a preset", function()
		local item = owner.add_form({ id = "single", sessionID = "s", fields = {
			{ key = "choice", type = "string", custom = true,
				options = { { label = "A", value = "a" } } },
		} })
		owner.update_selection("single", 1, {})
		assert.is_true(item.selections[1].is_answered)
		assert.same({}, owner.get_answers("single"))
		owner.set_custom_input("single", 1, "other")
		owner.update_selection("single", 1, { 1 })
		assert.is_false(item.selections[1].custom_present)
		assert.same({ choice = "a" }, owner.get_answers("single"))
	end)
end)
