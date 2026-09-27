local owner = require("opencode.question.state")
local widget = require("opencode.ui.question_widget")
local function fixture(name)
	return vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/interactions/" .. name .. ".json"), "\n")).data
end

describe("native typed forms", function()
	before_each(function() owner.clear_all() end)
	after_each(function() owner.clear_all() end)
	local function tab(item, key)
		for i, q in ipairs(item.questions) do if q.key == key then owner.set_tab(item.request_id, i); return i end end
		error("No visible field: " .. key)
	end
	it("round trips option values, numbers, false and hidden defaults from a real form", function()
		local form = fixture("form-created")
		local item = owner.add_form(form)
		tab(item, "target"); owner.select_option(form.id, 2)
		tab(item, "checks"); owner.toggle_multi_select(form.id, 1)
		owner.set_custom_input(form.id, tab(item, "ratio"), "0")
		assert.same(fixture("form-detail").state.answer, owner.get_answers(form.id))
		assert.is_true(owner.validate_form(form.id))
		assert.is_true(owner.begin_submission(form.id, "reply"))
		assert.is_false(owner.begin_submission(form.id, "reply"))
		local before = owner.get_question(form.id)
		owner.add_form(form)
		assert.equals(before, owner.get_question(form.id))
		assert.is_true(before.submitting)
		owner.mark_answered(form.id, owner.get_answers(form.id))
		assert.equals("Same", item.display_answers[1][1])
		assert.same(false, item.answers.confirm)
		assert.is_false(owner.restore_submission(form.id))
	end)

	it("preserves drafts and focus by key across conditional visibility", function()
		local item = owner.add_form(fixture("form-created"))
		local id = item.request_id
		tab(item, "confirm"); owner.select_option(id, 1)
		owner.set_custom_input(id, tab(item, "note"), "keep draft")
		tab(item, "confirm"); owner.select_option(id, 2)
		assert.equals("confirm", item.questions[item.current_tab].key)
		assert.is_nil(owner.get_answers(id).note)
		tab(item, "confirm"); owner.select_option(id, 1)
		assert.equals("keep draft", owner.get_answers(id).note)
		assert.equals("keep draft", item.form_selections.note.custom_input)
	end)

	it("keeps invalid numeric input and server validation errors editable", function()
		local item = owner.add_form({ id = "f", sessionID = "s", title = "Count", fields = {
			{ key = "count", type = "integer", required = true, minimum = 0, maximum = 4 } } })
		for _, value in ipairs({ "2.5", "abc", "-1", "5" }) do
			owner.set_custom_input("f", 1, value)
			assert.is_false(owner.begin_submission("f", "reply"))
			assert.is_not_nil(item.field_errors.count)
			assert.equals(value, item.selections[1].custom_input)
		end
		owner.set_custom_input("f", 1, "0")
		assert.is_true(owner.begin_submission("f", "reply"))
		owner.set_form_error("f", { message = "Server rejected value" })
		assert.is_false(item.submitting)
		assert.equals("0", item.selections[1].custom_input)
		local lines = widget.get_lines_for_question("f", { questions = item.questions }, item, "pending")
		assert.is_truthy(table.concat(lines, "\n"):find("Server rejected value", 1, true))
	end)

	it("waits for external completion and retains unknown types for diagnostics", function()
		local item = owner.add_form({ id = "f", sessionID = "s", title = "Auth", fields = {
			{ key = "external", type = "external", url = "https://example.com/auth" },
			{ key = "unknown", type = "future", required = true },
		} })
		assert.is_false(owner.begin_submission("f", "reply"))
		assert.is_nil(owner.get_answers("f").external)
		assert.equals("future", item.form.fields[2].type)
		local lines = widget.get_lines_for_question("f", { questions = item.questions }, item, "pending")
		assert.is_truthy(table.concat(lines, "\n"):find("open link", 1, true))
		owner.apply_form_detail(vim.tbl_extend("force", item.form, { state = { status = "answered", answer = { external = "done" } } }))
		assert.equals("answered", item.status)
	end)

	it("adopts another client's exact answer and prevents late errors reopening it", function()
		local form = fixture("form-created")
		local item = owner.add_form(form)
		local detail = fixture("form-detail")
		owner.apply_form_detail(detail)
		owner.set_form_error(form.id, { message = "late timeout" })
		assert.equals("answered", item.status)
		assert.same(detail.state.answer, item.answers)
		assert.is_nil(item.server_error)
	end)
	it("preserves several custom multiselect defaults and submits hidden-only forms", function()
		owner.add_form({ id = "multi", sessionID = "s", fields = {
			{ key = "values", type = "multiselect", custom = true, default = { "one", "two" }, options = {} },
		} })
		assert.same({ values = { "one", "two" } }, owner.get_answers("multi"))
		local hidden = owner.add_form({ id = "hidden", sessionID = "s", fields = {
			{ key = "ok", type = "boolean", required = true, hidden = true, default = false },
		} })
		assert.same({ ok = false }, owner.get_answers("hidden"))
		local lines = widget.get_lines_for_question("hidden", { questions = {} }, hidden, "pending")
		assert.is_truthy(table.concat(lines, "\n"):find("Enter to submit", 1, true))
		assert.is_true(owner.begin_submission("hidden", "reply"))
	end)
	it("reports an unknown required field as unsupported", function()
		local item = owner.add_form({ id = "unknown", sessionID = "s", fields = { { key = "new", type = "future", required = true } } })
		assert.is_false(owner.validate_form("unknown"))
		assert.equals("Unsupported field type: future", item.field_errors.new)
	end)

end)
