local owner = require("opencode.question.state")

local function form(id, fields)
	return owner.add_form({ id = id, sessionID = "session", title = "Validation", fields = fields })
end

local function keys(item)
	local result = {}
	for _, question in ipairs(item.questions) do result[#result + 1] = question.key end
	return result
end

describe("v2 form schema validation", function()
	before_each(function() owner.clear_all() end)
	after_each(function() owner.clear_all() end)

	it("matches multiselect conditions against individual selected values", function()
		local item = form("multi-when", {
			{ key = "picks", type = "multiselect", options = {
				{ label = "A", value = "a" }, { label = "B", value = "b" },
			}, default = { "a", "b" } },
			{ key = "includes_a", type = "string", default = "included", when = {
				{ key = "picks", op = "eq", value = "a" },
			} },
			{ key = "excludes_a", type = "string", default = "excluded", when = {
				{ key = "picks", op = "neq", value = "a" },
			} },
		})
		assert.same({ "picks", "includes_a" }, keys(item))
		assert.same({ picks = { "a", "b" }, includes_a = "included" }, owner.get_answers(item.request_id))

		assert.is_true(owner.update_selection(item.request_id, 1, { 2 }))
		assert.same({ "picks", "excludes_a" }, keys(item))
		assert.same({ picks = { "b" }, excludes_a = "excluded" }, owner.get_answers(item.request_id))
	end)

	it("keeps both eq and neq dependents hidden while their reference is unanswered", function()
		local item = form("unanswered-when", {
			{ key = "choice", type = "string", required = true },
			{ key = "equal", type = "string", default = "equal", when = {
				{ key = "choice", op = "eq", value = "a" },
			} },
			{ key = "different", type = "string", default = "different", when = {
				{ key = "choice", op = "neq", value = "a" },
			} },
		})
		assert.same({ "choice" }, keys(item))
		assert.same({}, owner.get_answers(item.request_id))

		assert.is_true(owner.set_custom_input(item.request_id, 1, "a"))
		assert.same({ "choice", "equal" }, keys(item))
		assert.same({ choice = "a", equal = "equal" }, owner.get_answers(item.request_id))

		assert.is_true(owner.set_custom_input(item.request_id, 1, "b"))
		assert.same({ "choice", "different" }, keys(item))
		assert.same({ choice = "b", different = "different" }, owner.get_answers(item.request_id))
	end)

	it("does not turn an untouched optional multiselect into an empty answer", function()
		local item = form("optional-multi", {
			{ key = "choices", type = "multiselect", options = { { label = "A", value = "a" } } },
			{ key = "other", type = "string", default = "shown", when = {
				{ key = "choices", op = "neq", value = "a" },
			} },
		})
		assert.same({ "choices" }, keys(item))
		assert.same({}, owner.get_answers(item.request_id))
		owner.toggle_multi_select(item.request_id, 1)
		assert.same({ choices = { "a" } }, owner.get_answers(item.request_id))
		owner.toggle_multi_select(item.request_id, 1)
		assert.same({}, owner.get_answers(item.request_id))
		assert.same({ "choices" }, keys(item))
	end)

	it("omits an optional custom multiselect when its custom answer is cleared", function()
		local item = form("custom-multi-clear", {
			{ key = "choices", type = "multiselect", custom = true, options = {} },
			{ key = "dependent", type = "string", default = "visible", when = {
				{ key = "choices", op = "neq", value = "a" },
			} },
		})
		owner.set_custom_input(item.request_id, 1, "other")
		assert.same({ choices = { "other" }, dependent = "visible" }, owner.get_answers(item.request_id))
		owner.set_custom_input(item.request_id, 1, "")
		assert.same({}, owner.get_answers(item.request_id))
		assert.same({ "choices" }, keys(item))
	end)

	it("deduplicates a custom multiselect answer matching a selected option", function()
		local item = form("custom-multi-duplicate", {
			{ key = "choices", type = "multiselect", custom = true,
				options = { { label = "A", value = "a" } } },
		})
		owner.toggle_multi_select(item.request_id, 1)
		owner.set_custom_input(item.request_id, 1, "a")
		assert.same({ choices = { "a" } }, owner.get_answers(item.request_id))
	end)

	it("distinguishes an untouched empty default from a cleared optional text answer", function()
		local item = form("optional-text", {
			{ key = "name", type = "string", default = "" },
			{ key = "dependent", type = "string", default = "shown", when = {
				{ key = "name", op = "neq", value = "x" },
			} },
		})
		assert.same({ name = "", dependent = "shown" }, owner.get_answers(item.request_id))
		owner.set_custom_input(item.request_id, 1, "")
		assert.same({}, owner.get_answers(item.request_id))
		assert.same({ "name" }, keys(item))
	end)

	it("projects answers through visible ancestors and retains hidden drafts", function()
		local item = form("conditional-chain", {
			{ key = "mode", type = "string", default = "off", options = {
				{ label = "Off", value = "off" }, { label = "On", value = "on" },
			} },
			{ key = "secret", type = "string", default = "yes", when = {
				{ key = "mode", op = "eq", value = "on" },
			} },
			{ key = "followup", type = "string", default = "saved", when = {
				{ key = "secret", op = "eq", value = "yes" },
			} },
		})
		assert.same({ "mode" }, keys(item))
		assert.same({ mode = "off" }, owner.get_answers(item.request_id))

		assert.is_true(owner.select_option(item.request_id, 2))
		assert.same({ "mode", "secret", "followup" }, keys(item))
		assert.same({ mode = "on", secret = "yes", followup = "saved" }, owner.get_answers(item.request_id))

		assert.is_true(owner.select_option(item.request_id, 1))
		assert.same({ "mode" }, keys(item))
		assert.same({ mode = "off" }, owner.get_answers(item.request_id))
		assert.equals("yes", item.form_selections.secret.custom_input)
	end)

	it("uses an active hidden default without leaking it when its condition closes", function()
		local item = form("hidden-chain", {
			{ key = "mode", type = "boolean", default = true },
			{ key = "hidden", type = "string", hidden = true, default = "token", when = {
				{ key = "mode", op = "eq", value = true },
			} },
			{ key = "dependent", type = "string", default = "visible", when = {
				{ key = "hidden", op = "eq", value = "token" },
			} },
		})
		assert.same({ "mode", "dependent" }, keys(item))
		assert.same({ mode = true, hidden = "token", dependent = "visible" }, owner.get_answers(item.request_id))
		owner.select_option(item.request_id, 2)
		assert.same({ "mode" }, keys(item))
		assert.same({ mode = false }, owner.get_answers(item.request_id))
	end)

	it("validates JavaScript pattern syntax and reports malformed patterns", function()
		local item = form("pattern", { { key = "code", type = "string", required = true,
			pattern = "^[A-Z]{2}-[0-9]{3}$" } })
		owner.set_custom_input(item.request_id, 1, "A-123")
		assert.is_false(owner.validate_form(item.request_id))
		assert.is_not_nil(item.field_errors.code)
		owner.set_custom_input(item.request_id, 1, "AB-123")
		assert.is_true(owner.validate_form(item.request_id))
		local old_ignorecase = vim.o.ignorecase
		vim.o.ignorecase = true
		owner.set_custom_input(item.request_id, 1, "ab-123")
		assert.is_false(owner.validate_form(item.request_id))
		vim.o.ignorecase = old_ignorecase

		local malformed = form("bad-pattern", { { key = "code", type = "string", default = "anything", pattern = "[" } })
		assert.is_false(owner.validate_form(malformed.request_id))
		assert.is_not_nil(malformed.field_errors.code)
		local boundary = form("word-boundary", { { key = "code", type = "string", pattern = "\\bcat\\b" } })
		owner.set_custom_input(boundary.request_id, 1, "concatenate")
		assert.is_false(owner.validate_form(boundary.request_id))
		owner.set_custom_input(boundary.request_id, 1, "cat")
		assert.is_true(owner.validate_form(boundary.request_id))
		local lookahead = form("lookahead", { { key = "code", type = "string", pattern = "^(?=.*[A-Z])(?=.*[0-9]).+$" } })
		owner.set_custom_input(lookahead.request_id, 1, "missing")
		assert.is_false(owner.validate_form(lookahead.request_id))
		owner.set_custom_input(lookahead.request_id, 1, "A1")
		assert.is_true(owner.validate_form(lookahead.request_id))
		local noncapturing = form("noncapturing", { { key = "code", type = "string", pattern = "^(?:cat|dog)$" } })
		owner.set_custom_input(noncapturing.request_id, 1, "cat")
		assert.is_true(owner.validate_form(noncapturing.request_id))
		owner.set_custom_input(noncapturing.request_id, 1, "bird")
		assert.is_false(owner.validate_form(noncapturing.request_id))
	end)

	it("validates email, URI, calendar date, and date-time formats", function()
		local cases = {
			{ format = "email", bad = "name@example", good = "name@example.com" },
			{ format = "uri", bad = "not a URL", good = "https://example.com/path" },
			{ format = "date", bad = "2026-02-30", good = "2024-02-29" },
			{ format = "date-time", bad = "not-a-date", good = "2024-02-29T12:30:00Z" },
		}
		for _, case in ipairs(cases) do
			local item = form("format-" .. case.format, { { key = "value", type = "string", required = true, format = case.format } })
			owner.set_custom_input(item.request_id, 1, case.bad)
			assert.is_false(owner.validate_form(item.request_id), case.format .. " should reject an invalid value")
			assert.is_not_nil(item.field_errors.value)
			owner.set_custom_input(item.request_id, 1, case.good)
			assert.is_true(owner.validate_form(item.request_id), case.format .. " should accept a valid value")
		end
		local email = owner.get_question("format-email")
		owner.set_custom_input(email.request_id, 1, "a" .. vim.fn.nr2char(0x00A0) .. "b@example.com")
		assert.is_false(owner.validate_form(email.request_id))
		local uri = owner.get_question("format-uri")
		for _, value in ipairs({ "http://%", "http://[invalid", "https://example.com:bad", "http://user@" }) do
			owner.set_custom_input(uri.request_id, 1, value)
			assert.is_false(owner.validate_form(uri.request_id), value)
		end
		local date_time = owner.get_question("format-date-time")
		for _, value in ipairs({ "2024", "2024-02", "2024-02-30T12:00:00Z", "2024-02-29T12:30:00+02:00" }) do
			owner.set_custom_input(date_time.request_id, 1, value)
			assert.is_true(owner.validate_form(date_time.request_id), value)
		end
	end)

	it("rejects unlisted option defaults unless custom answers are allowed", function()
		local options = { { label = "Known", value = "known" } }
		local single = form("single-options", { { key = "choice", type = "string", options = options, default = "rogue" } })
		assert.is_false(owner.validate_form(single.request_id))
		assert.is_not_nil(single.field_errors.choice)

		local multi = form("multi-options", { { key = "choices", type = "multiselect", options = options,
			default = { "known", "rogue" } } })
		assert.is_false(owner.validate_form(multi.request_id))
		assert.is_not_nil(multi.field_errors.choices)

		local custom_single = form("custom-single", { { key = "choice", type = "string", options = options,
			custom = true, default = "rogue" } })
		assert.is_true(owner.validate_form(custom_single.request_id))
		local custom_multi = form("custom-multi", { { key = "choices", type = "multiselect", options = options,
			custom = true, default = { "known", "rogue" } } })
		assert.is_true(owner.validate_form(custom_multi.request_id))
	end)

	it("rejects an empty required multiselect even when minItems is zero", function()
		local item = form("required-multi", { { key = "choices", type = "multiselect", required = true,
			minItems = 0, options = { { label = "Known", value = "known" } }, default = {} } })
		assert.same({ choices = {} }, owner.get_answers(item.request_id))
		assert.is_false(owner.validate_form(item.request_id))
		assert.is_not_nil(item.field_errors.choices)
	end)
end)
