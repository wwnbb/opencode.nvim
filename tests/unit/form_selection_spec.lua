describe("form option selection", function()
	local forms = require("opencode.question.forms")

	local function item_for(fields)
		local item = { questions = {}, current_tab = 1, status = "pending" }
		forms.init(item, { title = "T", fields = fields })
		return item
	end

	it("selects a single choice, dropping a custom answer", function()
		local item = item_for({ { key = "s", type = "string", options = { { label = "A", value = "a" }, { label = "B", value = "b" } },
			custom = true } })
		assert.is_true(forms.set_custom_input(item, 1, "mine"))
		assert.is_true(item.selections[1].custom_present)
		assert.is_true(forms.select(item, 2))
		assert.same({ 2 }, item.selections[1].selected_indices)
		assert.is_false(item.selections[1].custom_present)
		assert.is_true(item.selections[1].is_answered)
		assert.is_false(forms.select(item, 3))
		assert.is_false(forms.select(item, 0))
		assert.is_false(forms.toggle(item, 1))
	end)

	it("toggles multi-select options and the saved custom answer", function()
		local item = item_for({ { key = "m", type = "multiselect", custom = true, required = true,
			options = { { label = "X", value = "x" }, { label = "Y", value = "y" } } } })
		local selection = item.selections[1]
		assert.is_false(selection.is_answered)
		assert.is_true(forms.toggle(item, 2))
		assert.is_true(forms.toggle(item, 1))
		assert.same({ 2, 1 }, selection.selected_indices)
		assert.is_true(forms.toggle(item, 2))
		assert.same({ 1 }, selection.selected_indices)
		assert.is_true(forms.toggle(item, 1))
		assert.is_false(selection.is_answered)
		assert.is_false(forms.toggle(item, 0))
		selection.custom_input = "z"
		assert.is_true(forms.toggle(item, 0))
		assert.is_true(selection.custom_present)
		assert.is_true(selection.is_answered)
		assert.is_false(forms.toggle(item, 3))
		assert.is_true(forms.select(item, 2))
		assert.same({ 2 }, selection.selected_indices)
		assert.is_true(selection.custom_present)
	end)

	it("refuses option selection on external steps", function()
		local item = item_for({ { key = "e", type = "external", url = "https://example.com" } })
		assert.is_false(forms.select(item, 1))
		assert.is_false(forms.toggle(item, 1))
	end)

	it("sets a whole selection with the single and multi answer rules", function()
		local item = item_for({ { key = "s", type = "string", options = { { label = "A", value = "a" } }, required = true } })
		item.selections[1].custom_present = true
		assert.is_true(forms.set_selection(item, 1, {}))
		assert.is_true(item.selections[1].custom_present)
		assert.is_true(forms.set_selection(item, 1, { 1 }))
		assert.is_false(item.selections[1].custom_present)
		assert.is_true(item.selections[1].is_answered)
		assert.is_false(forms.set_selection(item, 2, { 1 }))
	end)
end)
