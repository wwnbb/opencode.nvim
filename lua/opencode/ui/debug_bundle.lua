-- A support snapshot built from an allowlist, never config, messages or logs.
local M = {}

local function identifier(value)
	if type(value) ~= "string" or #value > 200 or value == "" then return nil end
	if value:find("[^%w_./:%-]") or value:find("://", 1, true) then return nil end
	return value
end

local function revision()
	local source = debug.getinfo(1, "S").source:sub(2)
	local root = source:match("^(.*)/lua/opencode/ui/debug_bundle%.lua$")
	if not root or vim.fn.executable("git") ~= 1 then return "unknown" end
	local ok, result = pcall(function()
		return vim.system({ "git", "-C", root, "rev-parse", "--short", "HEAD" }, { text = true }):wait(1000)
	end)
	local sha = ok and result.code == 0 and vim.trim(result.stdout or "") or nil
	return sha and sha:match("^%x+$") and sha or "unknown"
end

function M.collect()
	local state, selectors = require("opencode.state"), require("opencode.selectors")
	local os_info, nvim = vim.uv.os_uname(), vim.version()
	local session = state.get_session()
	local model = selectors.current_model() or {}
	local agent = selectors.current_agent() or {}
	local server = state.get_server_info()
	return {
		plugin = { name = "opencode.nvim", version = identifier((package.loaded.opencode or {}).version) or "unknown",
			revision = revision(), minimum_server = "2.0.11" },
		os = { system = identifier(os_info.sysname), release = identifier(os_info.release), machine = identifier(os_info.machine) },
		neovim = { major = nvim.major, minor = nvim.minor, patch = nvim.patch, prerelease = nvim.prerelease == true },
		server = { version = identifier(server.version), connected = state.is_connected(), managed = state.is_server_managed() },
		session = { id = identifier(session.id), status = identifier(state.get_session_status(session.id).type),
			locked = require("opencode.session.lock").is_locked(session.id) },
		model = { provider = identifier(model.providerID), id = identifier(model.modelID),
			agent = identifier(agent.name), variant = identifier(require("opencode.local").variant.current()) },
	}
end

function M.show()
	local payload = vim.json.encode(M.collect())
	local lines = { "Support snapshot (no credentials, endpoints, history or logs)", "", payload, "", "y: copy JSON    q/Esc: close" }
	local float = require("opencode.ui.float")
	local popup = float.create_centered_popup({ title = " Debug Bundle ", width = 90, height = 12 })
	popup:mount()
	popup:render(lines)
	vim.bo[popup.bufnr].modifiable = false
	vim.wo[popup.winid].wrap = true
	float.setup_close_keymaps(popup.bufnr, function() popup:close() end)
	vim.keymap.set("n", "y", function()
		if popup.closed or not vim.api.nvim_buf_is_valid(popup.bufnr) then return end
		vim.fn.setreg('"', payload)
		pcall(vim.fn.setreg, "+", payload)
		vim.notify("Debug bundle copied", vim.log.levels.INFO)
	end, { buffer = popup.bufnr, silent = true })
	return popup
end

function M.register(palette)
	palette.register({ id = "action.debug_bundle", title = "Debug Bundle", category = "actions",
		slash = { name = "debug" }, run = M.show, on_select = function(ctx) return ctx.run() end })
end

return M
