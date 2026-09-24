describe("native v2 form recovery across sessions", function()
	local state = require("opencode.state")
	local sync = require("opencode.sync")
	local forms = require("opencode.question.state")
	local pending = require("opencode.session.pending")
	local client = require("opencode.client")
	local bus = require("opencode.events.bus")
	local original_list_permissions, original_list_questions
	local requests

	local function form(id, session_id)
		return {
			id = id,
			sessionID = session_id,
			title = "Continue?",
			fields = { { key = "ok", type = "boolean", required = true } },
		}
	end

	before_each(function()
		state.reset(); sync.clear_all(); forms.clear_all(); pending.clear_all(); bus.clear()
		state.upsert_session({ id = "root", directory = "/tmp/opencode-form-root" })
		state.upsert_session({ id = "background", directory = "/tmp/opencode-form-background" })
		state.set_session("root", "Root")
		sync.record_task_child_session("root", "parent-message", "task-part", "child")
		requests = { forms = {}, permissions = {} }
		original_list_permissions, original_list_questions = client.list_permissions, client.list_questions
		client.list_permissions = function(opts, callback) requests.permissions[opts.session_id] = callback end
		client.list_questions = function(opts, callback) requests.forms[opts.session_id] = callback end
		require("opencode.events.handlers.interactions_v2").setup(bus)
	end)

	after_each(function()
		client.list_permissions, client.list_questions = original_list_permissions, original_list_questions
		bus.clear(); pending.clear_all(); forms.clear_all(); sync.clear_all(); state.reset()
	end)

	it("recovers forms for open roots and known child sessions", function()
		bus.emit("connected")
		assert.is_function(requests.forms.root)
		assert.is_function(requests.forms.background)
		assert.is_function(requests.forms.child)
		requests.forms.root(nil, { form("root-form", "root"), form("foreign-form", "foreign") })
		requests.forms.background(nil, { form("background-form", "background") })
		requests.forms.child(nil, { form("child-form", "child") })
		assert.is_truthy(forms.get_question("root-form"))
		assert.is_truthy(forms.get_question("background-form"))
		assert.is_truthy(forms.get_question("child-form"))
		assert.is_nil(forms.get_question("foreign-form"))
	end)

	it("does not restore a replied form from an older pending snapshot", function()
		bus.emit("connected")
		bus.emit("v2_interaction", {
			id = "reply-event", type = "form.replied", data = { id = "form", sessionID = "root", answer = { ok = true } },
		})
		requests.forms.root(nil, { form("form", "root") })
		assert.is_nil(forms.get_question("form"))
	end)
end)
