local client = require("opencode.client")
local state = require("opencode.state")
local auth = require("opencode.provider.auth")
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
client.setup({ host = host, port = tonumber(port), auth = { username = "opencode", password = "opencode-nvim-test-only" } })
state.set_server_info({ host = host, port = tonumber(port) })
local attempts = {}
for _, method in ipairs({ "test-code", "test-auto", "test-expired", "test-cancel", "test-command", "test-command-cancel" }) do
	local kind = method:find("command", 1, true) and "command" or "oauth"
	local terminal, views, code_sent, cancelled = nil, {}, false, false
	local id = auth.start("groq", { type = kind, id = method }, {}, { directory = directory }, function(view)
		views[#views + 1] = view.status
		if method == "test-code" and view.status == "awaiting_user" and not code_sent then
			code_sent = true; auth.complete(view.id, "public-test-code")
		elseif method:find("cancel", 1, true) and view.attempt_id and not cancelled then
			cancelled = true; auth.cancel(view.id)
		end
		if vim.tbl_contains({ "complete", "failed", "expired", "cancelled" }, view.status) then terminal = view end
	end)
	assert(vim.wait(15000, function() return terminal ~= nil end, 10), "Auth timed out: " .. method)
	local expected = method:find("cancel", 1, true) and "cancelled" or (method == "test-expired" and "expired" or "complete")
	assert(terminal.status == expected, vim.inspect(terminal))
	attempts[method] = { states = views, status = terminal.status, directory = terminal.directory }
	auth.cancel(id)
end
require("opencode.provider.state").clear_attempts()
vim.fn.writefile({ vim.json.encode({ attempts = attempts, version = "2.0.11" }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
print("Native integration attempts passed through Neovim auth owner")
