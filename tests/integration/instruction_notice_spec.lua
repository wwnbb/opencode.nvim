local chat_surface = require("tests.helpers.chat_surface")
local app = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local chat_state = require("opencode.ui.chat.state")
local state = chat_state.state
local projection = require("opencode.protocol.messages")

describe("native instruction update notices", function()
	local surface
	local session_id = "instruction-notices"
	local catalog = table.concat({
		"The Code Mode tool catalog has changed. The full current tool catalog follows.",
		'<mcp_instructions server="job-search">Use the job search tools.</mcp_instructions>',
		"namespace job_search {",
		'  export function search(input: { query: string, limit?: number }): Promise<{ jobs: Job[] }>',
		'  export function detail(input: { jobID: string }): Promise<Job>',
		"}",
		'const schema = { "type": "object", "properties": { "query": { "type": "string" } } };',
	}, "\n")
	local description = "Instructions updated: core/codemode, mcp/job-search"
	local neighbors = {
		{ id = "msg_01_user", type = "user", text = "Find remote Lua jobs", time = { created = 1 } },
		{ id = "msg_03_answer", type = "assistant", time = { created = 3, completed = 4 },
			content = { { type = "text", text = "Here are the matching jobs." } } },
	}

	before_each(function()
		surface = chat_surface.setup()
		app.set_session(session_id, "Instruction notices")
		app.set_session_status(session_id, { type = "idle" })
	end)

	after_each(function()
		chat_surface.restore(surface)
	end)

	local function render()
		chat.do_render()
		return table.concat(vim.api.nvim_buf_get_lines(surface.bufnr, 0, -1, false), "\n")
	end

	local function contains(text, value)
		assert.is_truthy(text:find(value, 1, true), "missing literal text: " .. value)
	end

	local function absent(text, value)
		assert.is_nil(text:find(value, 1, true), "unexpected raw instruction text: " .. value)
	end

	local function position(id)
		for _, pos in ipairs(state.message_positions) do
			if pos.id == id then return pos end
		end
		error("notice must retain its message range: " .. id)
	end

	local function assert_notice(text, id, expected)
		contains(text, "◈ " .. expected)
		contains(text, neighbors[1].text)
		contains(text, neighbors[2].content[1].text)
		for _, raw in ipairs({ "The Code Mode tool catalog has changed", "mcp_instructions", "namespace job_search", '"properties"' }) do
			absent(text, raw)
		end
		local pos = position(id)
		assert.equals("system", pos.role)
		local rows = vim.api.nvim_buf_get_lines(surface.bufnr, pos.start_line, pos.end_line + 1, false)
		assert.equals(2, #rows, "instruction notices should occupy one compact row and its separator")
		contains(rows[1], expected)
		assert.equals("", rows[2])
		local muted = false
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(surface.bufnr, chat_state.chat_hl_ns,
			{ pos.start_line, 0 }, { pos.end_line, -1 }, { details = true })) do
			muted = muted or mark[4].hl_group == "Comment"
		end
		assert.is_true(muted, "instruction notice must use muted highlighting")
	end

	local function load_history(native)
		sync.clear_session_messages(session_id)
		-- The same projection is used by client.get_messages for native HTTP history.
		local page = projection.page(session_id, { neighbors[1], native, neighbors[2] })
		sync.handle_session_messages(session_id, page)
		return page[2]
	end

	it("shows a compact HTTP history notice while retaining the full native catalog", function()
		local native = { id = "msg_02_notice", type = "system", time = { created = 2 },
			text = catalog, description = description, metadata = { notice = "instructions" } }
		local original = vim.deepcopy(native)
		local projected = load_history(native)
		assert_notice(render(), native.id, description)
		assert.equals(catalog, projected.parts[1].text)
		assert.same(original, projected.info._native)
		assert.same(original, native)
		assert.equals(catalog, sync.get_parts(native.id)[1].text)
		assert_notice(render(), native.id, description)
	end)

	it("renders the same compact notice from an SSE catalog update and cold history", function()
		sync.handle_session_messages(session_id, projection.page(session_id, neighbors))
		local event = { id = "evt_02_notice", type = "session.instructions.updated", created = 2,
			metadata = { instructions = { initial = false } }, data = {
				sessionID = session_id, text = catalog,
				delta = { ["mcp/job-search"] = "catalog-hash", ["core/codemode"] = "guidance-hash" },
			} }
		local original = vim.deepcopy(event)
		assert.is_true(sync.handle_server_event(event).changed)
		local message = sync.get_message(session_id, "msg_02_notice")
		assert.equals(description, message.description)
		assert.equals(catalog, message._native.text)
		assert.equals(catalog, sync.get_parts(message.id)[1].text)
		assert.same(original, event)
		local live = render()
		assert_notice(live, message.id, description)
		local native = vim.deepcopy(message._native)
		local projected = load_history(native)
		local cold = render()
		assert.same(live, cold)
		assert_notice(cold, message.id, description)
		assert.same(native, projected.info._native)
	end)

	it("uses a compact fallback when a system message has no description or delta keys", function()
		local native = { id = "msg_02_notice", type = "system", time = { created = 2 }, text = catalog }
		load_history(native)
		assert_notice(render(), native.id, "Instructions updated")
		sync.clear_session_messages(session_id)
		sync.handle_session_messages(session_id, projection.page(session_id, neighbors))
		sync.handle_server_event({ id = "evt_02_notice", type = "session.instructions.updated", created = 2,
			data = { sessionID = session_id, text = catalog, delta = {} } })
		assert.equals("Instructions updated", sync.get_message(session_id, native.id).description)
		assert_notice(render(), native.id, "Instructions updated")
	end)

	it("keeps identical catalog content in ordinary user, assistant and synthetic messages", function()
		local cases = {
			{ id = "msg_02_catalog", type = "user", text = catalog },
			{ id = "msg_02_catalog", type = "assistant", content = { { type = "text", text = catalog } } },
			{ id = "msg_02_catalog", type = "synthetic", text = catalog },
		}
		for _, native in ipairs(cases) do
			native.time = { created = 2 }
			local projected = load_history(native)
			local text = render()
			contains(text, "The Code Mode tool catalog has changed")
			contains(text, "mcp_instructions")
			contains(text, "namespace job_search")
			absent(text, "◈ Instructions updated")
			assert.equals(catalog, projected.parts[1].text)
		end
	end)
end)
