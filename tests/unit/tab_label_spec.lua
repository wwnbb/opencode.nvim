describe("tab label presentation", function()
	local label = require("opencode.ui.chat.tab_label")

	it("normalizes controls before measuring a single-line title", function()
		assert.equals("hello world  %", label.title("hello\nworld\t\r%"))
		assert.equals("a b c", label.title("a\0b\127c"))
		assert.equals("", label.title(nil))
	end)

	it("truncates Unicode titles by display cells", function()
		assert.equals("界界界…", label.title("界界界界", 7))
		assert.equals("Комиссия по симво…", label.title("Комиссия по символу maker taker"))
		local title = label.title(string.rep("é", 30))
		assert.is_true(vim.fn.strdisplaywidth(title) <= 18)
		assert.equals("éééé…", label.title(string.rep("é", 10), 5))
		assert.equals("界é界…", label.title("界é界é界é", 6))
	end)

	it("uses Waiting > Running > Error > Unread > Idle across sessions", function()
		local function session(status)
			return {
				is_waiting = function() return status == "Waiting" end,
				is_busy = function() return status == "Running" end,
				is_error = function() return status == "Error" end,
				is_unread = function() return status == "Unread" end,
			}
		end
		local sessions = { session("Idle") }
		assert.equals("Idle", label.status({}))
		assert.equals("Idle", label.status(sessions))
		for _, status in ipairs({ "Unread", "Error", "Running", "Waiting" }) do
			sessions[#sessions + 1] = session(status)
			assert.equals(status, label.status(sessions))
		end
		local icon, highlight = label.icon("Unread", { unread = "U" })
		assert.equals("U", icon)
		assert.equals("Waiting", highlight)
	end)

	it("presents a native failed idle outcome as Error without changing its raw status", function()
		local status = require("opencode.session.status")
		local raw = { type = "idle", outcome = "failed" }
		local session = require("opencode.session.view").from_record({ id = "native-failure", time = { idle = 2, viewed = 1 } }, { status = raw })
		assert.equals("Error", label.status({ session }))
		assert.equals("error", session:status_label())
		assert.equals("error", status.session_status_to_global(raw))
		assert.equals("idle", session:status_type())
		assert.same(raw, session.status)
		for _, outcome in ipairs({ "succeeded", "interrupted" }) do
			assert.is_false(status.is_error({ type = "idle", outcome = outcome }))
		end
		assert.is_false(status.is_error({ type = "busy", outcome = "failed" }))
	end)

	it("fits the largest centered window of tabs into the available width", function()
		assert.equals(5, label.max_tabs({ max_tabs = "AUTO" }, 5))
		assert.equals(5, label.max_tabs({ auto_fit = true, max_tabs = 2 }, 5))
		assert.equals(3, label.max_tabs({}, 5))
		assert.equals(2, label.max_tabs({ max_tabs = 4 }, 2))
		assert.equals(1, label.max_tabs({ max_tabs = 0 }, 5))
		assert.equals(1, label.window_start(3, 3, 2))
		assert.equals(1, label.window_start(6, 3, nil))
		assert.equals(2, label.window_start(6, 3, 3))
		assert.equals(4, label.window_start(6, 3, 6))
		local measured = label.widths({ "aa", "bbb", "c" }, " | ", vim.fn.strwidth)
		assert.same({ 0, 2, 5, 6 }, measured.prefix)
		assert.equals(3, measured.separator_width)
		assert.is_nil(measured.contextual)
		assert.is_true(label.widths({ "a\u{0301}b", "\tc" }, "|", vim.fn.strwidth).contextual)
		local function row(first, last) return measured.prefix[last + 1] - measured.prefix[first] + (last - first) * 3 end
		local start = function(visible) return label.window_start(3, visible, 3) end
		assert.same({ 3, 1, 3, true }, { label.fit(3, 3, 12, start, row) })
		assert.same({ 2, 2, 3, true }, { label.fit(3, 3, 7, start, row) })
		assert.same({ 1, 3, 3, false }, { label.fit(3, 3, 0, start, row) })
	end)
end)
