-- Fresh Neovim, recorded complete native HTTP DTOs, no server connection.
local fixture = vim.json.decode(table.concat(vim.fn.readfile(assert(vim.env.OPENCODE_V2_COLD_FIXTURE)), "\n"))
local history = assert(fixture.history)
local sid = assert(history[1].info.sessionID)
local native = {}
for _, item in ipairs(history) do native[#native + 1] = assert(item.info._v2) end
local projected = require("opencode.protocol.v2.messages").page(sid, native)
for index, item in ipairs(projected) do assert(vim.deep_equal(item.parts, history[index].parts), "Cold native parts differ from HTTP projection") end
local app, chat, sync = require("opencode"), require("opencode.ui.chat"), require("opencode.sync")
app.setup({ server = { auto_start = false, use_shell_env = false }, lualine = { enabled = false },
	session = { default_agent = "build", default_model = { providerID = "opencode", modelID = "mimo-v2.5-free" } } })
sync.handle_agents({ { id = "build", name = "build" } })
sync.handle_providers({ { id = "opencode", name = "OpenCode Zen", models = { ["mimo-v2.5-free"] = { name = "MiMo V2.5 Free", limit = { context = 200000 } } } } })
require("opencode.session").remember({ id = sid, title = "Restored tool history", location = { directory = vim.fn.getcwd() }, agent = "build",
	model = { providerID = "opencode", id = "mimo-v2.5-free" } })
require("opencode.session").set_active(sid, "Restored tool history", { preserve_cache = true })
sync.handle_session_messages(sid, projected, { complete = true, reconcile = true })
chat.open(); chat.focus(); chat.do_render()
local text = table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n")
for _, expected in ipairs({ "No matches found.", "ripgrep failed", "Tool execution interrupted", "blocked-search.fifo" }) do
	assert(text:find(expected, 1, true), "Cold history lost tool result: " .. expected)
end
local win = chat.get_winid()
vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(chat.get_bufnr()), 0 })
vim.cmd("normal! zb"); vim.cmd("redraw")
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.rpcnotify(1, "opencode_screenshot", "cold-tool-history") end
vim.fn.writefile({ vim.json.encode({ native_parts_match = true, completed_error_interrupted_tools_visible = true, rendered = text }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close()
print("Fresh Neovim restored native completed/error/interrupted tool history")
