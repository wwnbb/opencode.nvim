-- Unit checks for opencode input history ownership.
-- Run with: ./tests/run.sh unit

describe("opencode input history", function()
	it("loads, deduplicates, persists, and clears history", function()
vim.opt.runtimepath:append(vim.fn.getcwd())

local history = require("opencode.ui.input.history")

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_entries(expected, message)
	assert_eq(vim.inspect(history.entries()), vim.inspect(expected), message)
end

local history_file = vim.fn.tempname()
history.configure({
	history_file = history_file,
	max_history = 2,
})
history.clear()

history.add("one")
history.add("two")
history.add("three")
assert_entries({ "two", "three" }, "max_history should trim old entries")

history.add("three")
assert_entries({ "two", "three" }, "most recent duplicate should not be added")

local pending_parts = {
	{
		type = "file",
		filename = "original.png",
		source = {
			type = "file",
			path = "original.png",
			text = { value = "[Image 1]" },
		},
	},
}

history.set_pending("draft", pending_parts)
pending_parts[1].filename = "mutated.png"

local pending_copy = history.get_pending_parts()
assert_eq(pending_copy[1].filename, "original.png", "pending parts should copy input tables")

pending_copy[1].filename = "copy-mutated.png"
assert_eq(history.get_pending_parts()[1].filename, "original.png", "pending parts should copy output tables")

history.clear()
os.remove(history_file)

print("input history checks passed")
	end)
end)

describe("skill staging draft ownership", function()
	local input = require("opencode.ui.input")
	local history = require("opencode.ui.input.history")
	local app_state = require("opencode.state")
	local old_session, old_config, history_file
	before_each(function()
		old_session, old_config = app_state.get_session, app_state.get_config
		app_state.get_session = function() return { id = "session-a" } end
		history_file = vim.fn.tempname()
		app_state.get_config = function() return { input = { history_file = history_file } } end
		history.configure({ history_file = history_file })
		history.clear()
	end)
	after_each(function()
		input.close(false)
		history.clear()
		app_state.get_session = old_session
		app_state.get_config = old_config
		os.remove(history_file)
	end)

	it("appends visible markers and merges deduplicated skills without replacing other draft parts", function()
		local original = {
			{ type = "file", uri = "file:///tmp/reference.txt", source = { text = { value = "reference" } } },
			{ type = "agent", name = "reviewer" },
			{ type = "skill", id = "existing", _marker = "@existing", _session_id = "session-a" },
		}
		history.set_pending("Review reference @existing ", original)
		local selected = { { type = "skill", id = "existing" }, { type = "skill", id = "new", name = "New skill" },
			{ type = "skill", id = "new", name = "Duplicate" } }
		assert.is_true(input.stage_skills(selected, "session-a"))
		assert.is_false(input.is_visible())
		assert.equals("Review reference @existing @new ", input.get_pending_text())
		local parts = history.get_pending_parts()
		assert.equals(4, #parts)
		assert.same(original[1], parts[1])
		assert.same(original[2], parts[2])
		assert.equals("New skill", parts[4].name)
		assert.equals("session-a", parts[4]._session_id)
		assert.equals("@new", parts[4]._marker)
		assert.is_nil(selected[2]._marker)
		selected[2].name = "Mutated caller"
		parts[4].name = "Mutated copy"
		assert.equals("New skill", history.get_pending_parts()[4].name)
		assert.is_true(input.stage_skills({ { type = "skill", id = "new" } }, "session-a"))
		assert.equals("Review reference @existing @new ", input.get_pending_text())
		assert.equals(4, #history.get_pending_parts())
	end)

	it("rejects stale session selections and malformed references without changing the draft", function()
		history.set_pending("Existing task", { { type = "file", uri = "file:///tmp/file" } })
		for _, selection in ipairs({
			{ parts = { { type = "skill", id = "new" } }, session = "session-b" },
			{ parts = { { type = "skill", id = "new", _session_id = "session-b" } }, session = "session-a" },
			{ parts = { { type = "skill", id = "new" }, { type = "skill", id = vim.NIL } }, session = "session-a" },
		}) do
			local previous = history.get_pending_parts()
			local ok, err = input.stage_skills(selection.parts, selection.session)
			assert.is_false(ok)
			assert.equals("string", type(err))
			assert.equals("Existing task", input.get_pending_text())
			assert.same(previous, history.get_pending_parts())
		end
	end)

	it("reattaches a removed marker and keeps catalog identity distinct from a restored UI identity", function()
		history.set_pending("Task", {
			{ type = "skill", id = "ui-old", skillID = "catalog-old", _marker = "@catalog-old", _session_id = "session-a" },
		})
		assert.is_true(input.stage_skills({ { type = "skill", id = "ui-new", skillID = "catalog-old" } }, "session-a"))
		assert.equals("Task @catalog-old ", input.get_pending_text())
		local parts = history.get_pending_parts()
		assert.equals(1, #parts)
		assert.equals("catalog-old", parts[1].skillID)
		assert.equals("ui-new", parts[1].id)
	end)

	it("retains skill markers beside punctuation but rejects longer identifiers", function()
		for _, prompt in ipairs({ "Use @review-id, please", "Use (@review-id).", "Use [@review-id]!" }) do
			local sent
			input.show({ text = prompt, parts = { { type = "skill", id = "review-id", _marker = "@review-id", _session_id = "session-a" } },
				on_send = function(text, parts) sent = { text = text, parts = parts } end })
			assert.is_true(input.stage_skills({ { type = "skill", id = "review-id" } }, "session-a"))
			assert.equals(prompt, input.get_pending_text())
			local info = vim.api.nvim_win_get_buf(input.get_winids()[2])
			assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(info, 0, -1, false)):find("Skill", 1, true))
			vim.fn.maparg("<C-g>", "n", false, true).callback()
			assert.equals(1, #sent.parts)
			assert.equals("@review-id", sent.parts[1].source.text.value)
			assert.equals("@review-id", prompt:sub(sent.parts[1].source.text.start + 1, sent.parts[1].source.text["end"]))
		end
		for _, prompt in ipairs({ "Use @review-id-suffix", "Use @review-id.other", "Use @review-id/path" }) do
			local sent
			input.show({ text = prompt, parts = { { type = "skill", id = "review-id", _marker = "@review-id", _session_id = "session-a" } },
				on_send = function(_, parts) sent = parts end })
			vim.fn.maparg("<C-g>", "n", false, true).callback()
			assert.same({}, sent)
		end
	end)

	it("removes deleted agent mentions after closing and reopening a draft", function()
		local sent
		local function receive(_, parts) sent = parts end
		input.show({ text = "Ask @explore please", parts = { { type = "agent", name = "explore",
			source = { start = 4, ["end"] = 12, value = "@explore" } } }, on_send = receive })
		input.close()
		input.show({ on_send = receive })
		local buffer = vim.api.nvim_win_get_buf(input.get_winids()[1])
		vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Ask please" })
		vim.fn.maparg("<C-g>", "n", false, true).callback()
		assert.same({}, sent)
	end)

	it("persists real skill references in history without inferring them from plain mention text", function()
		history.add("Plain @review-id")
		local selected = { { type = "skill", id = "review-id", _session_id = "session-a",
			source = { text = { start = 4, ["end"] = 14, value = "@review-id" } } },
			{ type = "file", url = "data:image/png;base64,DO_NOT_PERSIST" }, { type = "agent", name = "explore" } }
		history.add("Use @review-id", selected)
		selected[1].id = "mutated-caller"
		assert.same({ "Plain @review-id", "Use @review-id" }, history.entries())
		local saved = table.concat(vim.fn.readfile(history_file))
		assert.is_nil(saved:find("DO_NOT_PERSIST", 1, true))
		assert.is_nil(saved:find("session-a", 1, true))
		local other_file = history_file .. ".empty"
		history.configure({ history_file = other_file })
		history.configure({ history_file = history_file })
		history.load()
		local text, parts = history.previous()
		assert.equals("Use @review-id", text)
		assert.equals(1, #parts)
		assert.equals("review-id", parts[1].id)
		parts[1].id = "mutated-copy"
		local plain, plain_parts = history.previous()
		assert.equals("Plain @review-id", plain)
		assert.same({}, plain_parts)
		local _, reloaded = history.next()
		assert.equals("review-id", reloaded[1].id)
		os.remove(other_file)
	end)

	it("releases a captured cursor after reopening a cancelled picker draft", function()
		input.show({ text = "Before after\nLast line" })
		local win = input.get_winids()[1]
		vim.api.nvim_win_set_cursor(win, { 1, 7 })
		input.capture_draft_cursor()
		local parent = vim.api.nvim_list_wins()[1]
		vim.api.nvim_set_current_win(parent)
		assert.is_true(vim.wait(100, function() return not input.is_visible() end, 5))
		input.show()
		win = input.get_winids()[1]
		assert.same({ 1, 7 }, vim.api.nvim_win_get_cursor(win))
		vim.api.nvim_win_set_cursor(win, { 2, 4 })
		vim.api.nvim_set_current_win(parent)
		assert.is_true(vim.wait(100, function() return not input.is_visible() end, 5))
		assert.is_true(input.stage_skills({ { type = "skill", id = "review-id" } }, "session-a"))
		input.show()
		assert.equals("Before after\nLast @review-id  line", input.get_pending_text())
		assert.same({ 2, #"Last @review-id " }, vim.api.nvim_win_get_cursor(input.get_winids()[1]))
	end)
end)
