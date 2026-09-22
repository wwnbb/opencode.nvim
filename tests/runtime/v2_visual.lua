-- Shared pre/post-migration renderer fixture: common UI data, no network/model.
if vim.env.OPENCODE_V2_BASELINE then vim.opt.runtimepath:prepend(vim.env.OPENCODE_V2_BASELINE) end
local app, chat, sync = require("opencode"), require("opencode.ui.chat"), require("opencode.sync")
local session = require("opencode.session")
vim.o.columns, vim.o.lines = 120, 40
app.setup({ server = { auto_start = false }, session = { default_agent = "build", default_model = { providerID = "fixture", modelID = "model" } },
	chat = { width = 80, height = 24, close_on_focus_lost = false }, lualine = { enabled = false } })
sync.handle_agents({ { id = "build", name = "build" } })
sync.handle_providers({ { id = "fixture", name = "Fixture", models = { model = { name = "Fixture Model", limit = { context = 200000 } } } } })
session.remember({ id = "visual", title = "Render fixture", directory = vim.fn.getcwd(), agent = "build", model = { providerID = "fixture", id = "model" } })
session.set_active("visual", "Render fixture", { preserve_cache = true })
local messages = {}
for index = 1, 80 do
	local id = string.format("msg_%04d", index)
	local role = index % 2 == 1 and "user" or "assistant"
	local text = role == "user" and "Inspect the parser and preserve Unicode: Привет, Neovim."
		or string.rep("Streaming text keeps widget identity and readable wrapping. ", 12)
	messages[#messages + 1] = { info = { id = id, sessionID = "visual", role = role, agent = "build", providerID = "fixture", modelID = "model",
		time = { created = 1000, completed = role == "assistant" and 1200 or nil }, tokens = { input = 1234, output = 64 }, cost = 0 },
		parts = { { id = id .. "_text", messageID = id, sessionID = "visual", type = "text", text = text } } }
end
sync.handle_session_messages("visual", messages)
chat.open(); chat.focus(); chat.do_render()
local metrics = { renders = 30, messages = #messages, characters_per_answer = #messages[80].parts[1].text, samples_ms = {} }
for _ = 1, 5 do chat.render() end
for _ = 1, metrics.renders do
	local start = vim.uv.hrtime(); chat.render(); metrics.samples_ms[#metrics.samples_ms + 1] = (vim.uv.hrtime() - start) / 1e6
end
table.sort(metrics.samples_ms)
metrics.median_ms = metrics.samples_ms[math.floor(#metrics.samples_ms / 2)]
metrics.p95_ms = metrics.samples_ms[math.floor(#metrics.samples_ms * 0.95)]
for _, layout in ipairs({ "vertical", "horizontal", "float" }) do
	chat.close(); chat.setup({ layout = layout }); chat.open(); chat.focus(); chat.do_render()
	vim.api.nvim_win_set_cursor(require("opencode.ui.chat.state").state.winid, { vim.api.nvim_buf_line_count(chat.get_bufnr()), 0 })
	vim.cmd("normal! zb"); vim.cmd("redraw")
	if vim.env.OPENCODE_V2_ATTACHED_UI then vim.rpcnotify(1, "opencode_screenshot", "layout-" .. layout) end
end
local input = require("opencode.ui.input")
chat.focus_input()
vim.wait(100, function() return false end, 10)
vim.cmd("redraw")
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.rpcnotify(1, "opencode_screenshot", "input-focus") end
assert(input.is_visible(), "Input did not open")
vim.fn.writefile({ vim.json.encode(metrics) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close()
print("Renderer layouts, input focus and baseline timings captured")
