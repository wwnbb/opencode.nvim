-- Unit checks for opencode input history ownership.
-- Run with: ./tests/run.sh unit

describe("opencode input history", function()
	it("loads, deduplicates, persists, and clears history", function()

local history = require("opencode.ui.input.history")

local history_file = vim.fn.tempname()
history.configure({
	history_file = history_file,
	max_history = 2,
})
history.clear()

history.add("one")
history.add("two")
history.add("three")
assert.same({ "two", "three" }, history.entries(), "max_history should trim old entries")

history.add("three")
assert.same({ "two", "three" }, history.entries(), "most recent duplicate should not be added")

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
assert.equals("original.png", pending_copy[1].filename, "pending parts should copy input tables")

pending_copy[1].filename = "copy-mutated.png"
assert.equals("original.png", history.get_pending_parts()[1].filename, "pending parts should copy output tables")

history.clear()
os.remove(history_file)

	end)
end)

describe("complete prompt history and session drafts", function()
	local input = require("opencode.ui.input")
	local history = require("opencode.ui.input.history")
	local app_state = require("opencode.state")
	local requests = require("opencode.protocol.v2.requests")
	local original_get_session, original_get_config, original_clipboard_read, history_file, active_session, restore_session

	local function reload_history()
		local other_file = history_file .. ".other"
		history.configure({ history_file = other_file })
		history.configure({ history_file = history_file })
		history.load()
	end

	local function source(text, marker)
		local first, last = assert(text:find(marker, 1, true))
		return { text = { start = first - 1, ["end"] = last, value = marker } }
	end

	local function bytes()
		local file = assert(io.open(history_file, "rb"))
		local content = file:read("*a")
		file:close()
		return content
	end

	before_each(function()
		original_get_session, original_get_config = app_state.get_session, app_state.get_config
		original_clipboard_read = require("opencode.clipboard").read
		restore_session = nil
		active_session = "session-a"
		app_state.get_session = function() return { id = active_session } end
		history_file = vim.fn.tempname()
		app_state.get_config = function() return { input = { history_file = history_file } } end
		history.configure({ history_file = history_file, max_history = 100 })
		history.clear()
	end)

	after_each(function()
		input.close(false)
		require("opencode.clipboard").read = original_clipboard_read
		history.clear()
		app_state.get_session, app_state.get_config = original_get_session, original_get_config
		if restore_session then app_state.set_session(restore_session.id, restore_session.name, { runtime = false }) end
		os.remove(history_file)
		os.remove(history_file .. ".other")
	end)

	it("preserves corrupt, unsupported, and malformed history instead of overwriting it", function()
		for _, original in ipairs({ "{broken", "null", '{"version":2,"entries":"broken"}',
			'{"version":2,"entries":{"unknown":"preserve"}}', '{"unknown":"preserve"}', '{"version":3,"entries":[]}' }) do
			vim.fn.writefile({ original }, history_file, "b")
			reload_history()
			history.add("New prompt")
			assert.equals(original, bytes())
		end
	end)

	it("loads existing history before adding through the history API", function()
		history.add("Keep this prompt")
		history.configure({ history_file = history_file .. ".other" })
		history.configure({ history_file = history_file })
		history.add("New prompt")
		assert.same({ "Keep this prompt", "New prompt" }, history.entries())
	end)

	it("preserves an existing history file when encoding fails", function()
		history.add("Keep this prompt")
		local original = bytes()
		local encode = vim.json.encode
		vim.json.encode = function() error("encoding failed") end
		local ok = pcall(history.add, "New prompt")
		vim.json.encode = encode
		assert.is_true(ok)
		assert.equals(original, bytes())
	end)

	it("preserves unreadable history when loading fails", function()
		history.add("Keep this prompt")
		local original, open = bytes(), io.open
		io.open = function(path, mode)
			if path == history_file and (mode == "r" or mode == "rb") then return nil, "permission denied" end
			return open(path, mode)
		end
		local ok = pcall(reload_history)
		io.open = open
		assert.is_true(ok)
		history.add("New prompt")
		assert.equals(original, bytes())
	end)

	it("loads legacy text and skill entries, then writes a versioned history", function()
		vim.fn.writefile({ vim.json.encode({
			"Legacy plain prompt",
			{ text = "Use @review-id", skills = { { type = "skill", id = "review-id", _marker = "@review-id" } } },
		}) }, history_file)
		reload_history()
		local skill_text, skill_parts = history.previous()
		assert.equals("Use @review-id", skill_text)
		assert.equals("review-id", skill_parts[1].id)
		local plain_text, plain_parts = history.previous()
		assert.equals("Legacy plain prompt", plain_text)
		assert.same({}, plain_parts)

		history.add("echo hello", {}, "shell")
		local saved = vim.json.decode(table.concat(vim.fn.readfile(history_file), "\n"))
		assert.equals(2, saved.version)
		assert.equals(3, #saved.entries)
		reload_history()
		local text, parts, mode = history.previous()
		assert.equals("echo hello", text)
		assert.same({}, parts)
		assert.equals("shell", mode)
		local migrated_text, migrated_parts = history.previous()
		assert.equals("Use @review-id", migrated_text)
		assert.equals("review-id", migrated_parts[1].id)
		local migrated_plain, migrated_plain_parts = history.previous()
		assert.equals("Legacy plain prompt", migrated_plain)
		assert.same({}, migrated_plain_parts)
	end)

	it("resends a recalled image, agent, and skill with the same native payload", function()
		local text = "Review [Image 1] with @explore and @review-id"
		local parts = {
			{ type = "file", url = "data:image/png;base64,AAEC", mime = "image/png", filename = "picture.png",
				source = source(text, "[Image 1]"), _marker = "[Image 1]" },
			{ type = "agent", name = "explore", source = source(text, "@explore") },
			{ type = "skill", id = "review-id", source = source(text, "@review-id"), _session_id = "session-a" },
		}
		local original, original_error = requests.prompt(text, { parts = parts }, "original")
		assert.is_nil(original_error)
		history.add(text, parts, "normal")
		reload_history()
		local recalled_text, recalled_parts, recalled_mode = history.previous()
		local recalled, recalled_error = requests.prompt(recalled_text, { parts = recalled_parts }, "recalled")
		assert.is_nil(recalled_error)
		assert.equals("normal", recalled_mode)
		assert.same(original.files, recalled.files)
		assert.same(original.agents, recalled.agents)
		assert.same(original.skills, recalled.skills)
		assert.is_nil(table.concat(vim.fn.readfile(history_file), "\n"):find("session-a", 1, true))

		reload_history()
		local resent
		input.show({ text = "", on_send = function(sent_text, sent_parts)
			resent = requests.prompt(sent_text, { parts = sent_parts }, "resent")
		end })
		local previous = vim.fn.maparg("<Up>", "i", false, true)
		assert.is_function(previous.callback)
		previous.callback()
		assert.is_true(vim.wait(100, function() return input.get_pending_text() == text end, 5))
		vim.fn.maparg("<C-g>", "n", false, true).callback()
		assert.is_not_nil(resent)
		assert.same(original.files, resent.files)
		assert.same(original.agents, resent.agents)
		assert.same(original.skills, resent.skills)
	end)

	it("keeps new image markers distinct after recalling a filtered attachment", function()
		local pasted, sent = 0, {}
		require("opencode.clipboard").read = function()
			pasted = pasted + 1
			return { mime = "image/png", data = vim.base64.encode(tostring(pasted)), filename = pasted .. ".png" }
		end
		input.show({ text = "", close_on_send = false, on_send = function(text, parts)
			sent[#sent + 1] = { text = text, parts = parts }
		end })
		assert.is_true(input.paste_clipboard())
		assert.is_true(input.paste_clipboard())
		input.set_pending_draft("[Image 2]", input.get_pending_parts())
		vim.fn.maparg("<C-g>", "n", false, true).callback()
		assert.equals(1, #sent[1].parts)
		assert.equals("2.png", sent[1].parts[1].filename)

		vim.fn.maparg("<Up>", "i", false, true).callback()
		assert.is_true(vim.wait(100, function() return input.get_pending_text() == "[Image 2]" end, 5))
		assert.is_true(input.paste_clipboard())
		local parts = input.get_pending_parts()
		assert.equals("[Image 2]", parts[1]._marker)
		assert.equals("[Image 3]", parts[2]._marker)
		input.set_pending_draft("[Image 3]", parts)
		vim.fn.maparg("<C-g>", "n", false, true).callback()
		assert.equals(1, #sent[2].parts)
		assert.equals("3.png", sent[2].parts[1].filename)
	end)

	it("keeps unsent text and attachment-only drafts when history navigation is pressed", function()
		history.add("Older prompt")
		for _, draft in ipairs({ { text = "Unsent draft", parts = {} },
			{ text = "", parts = { { type = "file", url = "data:image/png;base64,Yg==" } } },
		}) do
			input.show({ text = draft.text, parts = draft.parts })
			for _, key in ipairs({ "<Up>", "<Down>" }) do
				vim.fn.maparg(key, "i", false, true).callback()
				vim.wait(30)
				assert.equals(draft.text, input.get_pending_text())
				assert.same(draft.parts, input.get_pending_parts())
			end
			input.close(false)
		end
	end)

	it("protects edits to recalled history while allowing unchanged entries to move", function()
		history.add("Oldest prompt")
		history.add("Newest prompt")
		input.show({ text = "" })
		local function move(key, expected)
			vim.fn.maparg(key, "i", false, true).callback()
			vim.wait(30)
			assert.equals(expected, input.get_pending_text())
		end
		move("<Up>", "Newest prompt")
		move("<Up>", "Oldest prompt")
		move("<Down>", "Newest prompt")
		local buffer = vim.api.nvim_win_get_buf(input.get_winids()[1])
		vim.api.nvim_buf_set_text(buffer, 0, 0, 0, 0, { "Edited " })
		move("<Up>", "Edited Newest prompt")
		move("<Down>", "Edited Newest prompt")
		input.set_pending_draft("Newest prompt", { { type = "file", url = "data:image/png;base64,Yg==" } })
		move("<Up>", "Newest prompt")
		move("<Down>", "Newest prompt")
		assert.equals(1, #input.get_pending_parts())
		input.set_pending_text("")
		move("<Down>", "")
		move("<Up>", "Newest prompt")
	end)

	it("keeps an attachment-only prompt in history", function()
		local file = { type = "file", url = "data:image/png;base64,AQID", filename = "only.png" }
		history.add("", { file }, "normal")
		reload_history()
		local text, parts = history.previous()
		assert.equals("", text)
		local body, err = requests.prompt(text, { parts = parts }, "attachment-only")
		assert.is_nil(err)
		assert.equals(file.url, body.files[1].uri)
	end)

	it("restores independent text, parts, mode, and cursor after repeated A/B switches", function()
		local a_text = "Alpha [Image 1]\nsecond line"
		local a_file = { type = "file", url = "data:image/png;base64,AAEC", _marker = "[Image 1]",
			source = source(a_text, "[Image 1]") }
		input.show({ text = a_text, parts = { a_file } })
		vim.api.nvim_win_set_cursor(input.get_winids()[1], { 2, 3 })
		input.close()
		history.set_pending_mode("shell", "session-a")
		assert.equals(#"Alpha [Image 1]\n" + 3, history.get_pending_cursor("session-a"))

		active_session = "session-b"
		input.show()
		assert.equals("", input.get_pending_text())
		assert.same({}, input.get_pending_parts())
		local b_text = "Beta @explore"
		input.set_pending_draft(b_text, { { type = "agent", name = "explore", source = source(b_text, "@explore") } })
		vim.api.nvim_win_set_cursor(input.get_winids()[1], { 1, 5 })
		input.close()
		assert.equals(5, history.get_pending_cursor("session-b"))

		for _ = 1, 2 do
			active_session = "session-a"
			input.show()
			assert.equals(a_text, input.get_pending_text())
			assert.equals(a_file.url, input.get_pending_parts()[1].url)
			assert.same({ 2, 3 }, vim.api.nvim_win_get_cursor(input.get_winids()[1]))
			assert.equals("shell", history.get_pending_mode())
			input.close()

			active_session = "session-b"
			input.show()
			assert.equals(b_text, input.get_pending_text())
			assert.equals("explore", input.get_pending_parts()[1].name)
			assert.same({ 1, 5 }, vim.api.nvim_win_get_cursor(input.get_winids()[1]))
			assert.equals("normal", history.get_pending_mode())
			input.close()
		end
	end)

	it("opens a temporary review comment without borrowing the session draft cursor", function()
		history.set_pending("review note", {}, "session-a")
		history.set_pending_cursor(4, "session-a")

		input.show({ text = "review note", persist_pending = false, add_history = false })
		assert.is_true(input.is_visible())
		assert.same({ 1, #"review note" }, vim.api.nvim_win_get_cursor(input.get_winids()[1]))
		input.close(false)
		assert.equals(4, history.get_pending_cursor("session-a"))

		history.set_pending("", {}, "session-a")
		history.set_pending_cursor(0, "session-a")
		input.show({ text = "", persist_pending = false, add_history = false })
		assert.is_true(input.is_visible())
	end)

	it("restores a saved draft cursor without an in-memory cursor capture", function()
		input.set_pending_text("Saved draft")
		history.set_pending_cursor(5, "session-a")

		input.show()
		assert.same({ 1, 5 }, vim.api.nvim_win_get_cursor(input.get_winids()[1]))
	end)

	it("drops deferred send and history keys after the same composer switches sessions", function()
		restore_session = original_get_session()
		app_state.get_session = original_get_session
		history.add("Historical prompt")
		for _, key in ipairs({ "<C-g>", "<Up>" }) do
			app_state.set_session("session-a", "A", { runtime = false })
			local next_text = key == "<C-g>" and "Other session draft" or ""
			history.set_pending(next_text, {}, "session-b")
			local sent, queued = {}, {}
			input.show({ text = "Original draft", close_on_send = false, on_send = function(text) sent[#sent + 1] = text end })
			local composer = input.get_winids()[1]
			local bufnr = vim.api.nvim_win_get_buf(composer)
			local schedule = vim.schedule
			vim.schedule = function(callback) queued[#queued + 1] = callback end
			local ok, err = pcall(vim.fn.maparg(key, "i", false, true).callback)
			vim.schedule = schedule
			assert.is_true(ok, err)
			assert.equals(1, #queued)
			app_state.set_session("session-b", "B", { runtime = false })
			assert.equals(bufnr, vim.api.nvim_win_get_buf(composer))
			queued[1]()
			assert.same({}, sent)
			assert.equals(next_text, input.get_pending_text())
			if key == "<C-g>" then
				vim.fn.maparg(key, "n", false, true).callback()
				assert.same({ next_text }, sent)
			end
			input.close(false)
		end
	end)

	it("swaps an open composer on session changes and sends only the active draft", function()
		restore_session = original_get_session()
		app_state.get_session = original_get_session
		app_state.set_session("session-a", "A", { runtime = false })
		local a_text = "Alpha [Image 1]\nsecond line"
		local a_file = { type = "file", url = "data:image/png;base64,AAEC", _marker = "[Image 1]",
			source = source(a_text, "[Image 1]") }
		local b_text = "Beta @explore"
		local b_agent = { type = "agent", name = "explore", source = source(b_text, "@explore") }
		history.set_pending(b_text, { b_agent }, "session-b")
		history.set_pending_cursor(5, "session-b")

		local sent
		input.show({ text = a_text, parts = { a_file }, on_send = function(text, parts)
			sent = { session_id = app_state.get_session().id, text = text, parts = parts }
		end })
		local composer = input.get_winids()[1]
		vim.api.nvim_win_set_cursor(composer, { 2, 3 })
		app_state.set_session("session-b", "B", { runtime = false })
		assert.is_true(input.is_visible())
		assert.equals(b_text, input.get_pending_text())
		assert.equals("explore", input.get_pending_parts()[1].name)
		assert.same({ 1, 5 }, vim.api.nvim_win_get_cursor(composer))

		app_state.set_session("session-a", "A", { runtime = false })
		assert.equals(a_text, input.get_pending_text())
		assert.equals(a_file.url, input.get_pending_parts()[1].url)
		assert.same({ 2, 3 }, vim.api.nvim_win_get_cursor(composer))
		app_state.set_session("session-b", "B", { runtime = false })
		assert.equals(b_text, input.get_pending_text())
		assert.same({ 1, 5 }, vim.api.nvim_win_get_cursor(composer))

		vim.fn.maparg("<C-g>", "n", false, true).callback()
		assert.equals("session-b", sent.session_id)
		assert.equals(b_text, sent.text)
		local body, err = requests.prompt(sent.text, { parts = sent.parts }, "active-draft")
		assert.is_nil(err)
		assert.is_nil(body.files)
		assert.equals("explore", body.agents[1].name)
		assert.equals(a_text, history.get_pending("session-a"))
		assert.equals(a_file.url, history.get_pending_parts("session-a")[1].url)
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

	it("persists complete prompt parts without inferring them from plain mention text", function()
		history.add("Plain @review-id")
		local selected = { { type = "skill", id = "review-id", _session_id = "session-a",
			source = { text = { start = 4, ["end"] = 14, value = "@review-id" } } },
			{ type = "file", url = "data:image/png;base64,PERSIST_FILE" }, { type = "agent", name = "explore" } }
		history.add("Use @review-id", selected)
		selected[1].id = "mutated-caller"
		assert.same({ "Plain @review-id", "Use @review-id" }, history.entries())
		local saved = table.concat(vim.fn.readfile(history_file))
		assert.is_truthy(saved:find("PERSIST_FILE", 1, true))
		assert.is_nil(saved:find("session-a", 1, true))
		local decoded = vim.json.decode(saved)
		assert.equals(2, decoded.version)
		local other_file = history_file .. ".empty"
		history.configure({ history_file = other_file })
		history.configure({ history_file = history_file })
		history.load()
		local text, parts = history.previous()
		assert.equals("Use @review-id", text)
		assert.equals(3, #parts)
		assert.equals("review-id", parts[1].id)
		assert.equals("data:image/png;base64,PERSIST_FILE", parts[2].url)
		assert.equals("explore", parts[3].name)
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
