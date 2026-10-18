describe("tab label presentation", function()
	local label = require("opencode.ui.chat.tab_label")

	it("normalizes controls before measuring a single-line title", function()
		assert.equals("hello world  %", label.title("hello\nworld\t\r%"))
		assert.equals("a b c", label.title("a\0b\127c"))
		assert.equals("", label.title(nil))
	end)

	it("truncates Unicode titles by display cells", function()
		assert.equals("界界...", label.title("界界界界", 7))
		assert.equals("Комиссия по сим...", label.title("Комиссия по символу maker taker"))
		local title = label.title(string.rep("é", 30))
		assert.is_true(vim.fn.strdisplaywidth(title) <= 18)
		assert.equals("éé...", label.title(string.rep("é", 10), 5))
		assert.equals("界é...", label.title("界é界é界é", 6))
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
end)
