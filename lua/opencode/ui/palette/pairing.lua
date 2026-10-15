local M = {}
local actions = require("opencode.actions")
local pending = require("opencode.session.pending")
local revision = 0

-- Pairing uses /auth/connect at the advertised origin, as the native TUI does.
local function origin(url)
	if type(url) ~= "string" or url:find("[%z%c%s]") then return end
	local scheme, authority = url:match("^(https?://)([^/?#]+)")
	if scheme and not authority:find("@", 1, true) then return scheme .. authority end
end

local function report(err)
	local message = (err.status == 404 or err.status == 405 or err.status == 501 or err.status == 503) and "This server does not support pairing" or tostring(err.message or err)
	if err.status == 503 then message = "Server pairing is temporarily unavailable" .. (err.message and (": " .. err.message) or "") end
	vim.notify("Could not pair server: " .. message, vim.log.levels.ERROR)
end

function M.show()
	revision = revision + 1
	local current_revision, token = revision, pending.token()
	local function current() return current_revision == revision and pending.is_current(token) end
	actions.get_server_info(function(err, info)
		if not current() then return end
		if err then report(err); return end
		local origins, seen = {}, {}
		for _, url in ipairs(info.urls) do
			local value = origin(url)
			if value and not seen[value] then origins[#origins + 1], seen[value] = value, true end
		end
		if #origins == 0 then report({ message = "Server did not advertise an HTTP(S) connection URL" }); return end
		local issued, issued_wall = (vim.uv or vim.loop).now(), os.time()
		actions.pair_server(function(pair_err, pairing)
			if not current() then return end
			if pair_err then report(pair_err); return end
			local expires = issued + pairing.expires_in * 1000
			local function available(ctx)
				if not current() then return false end
				if (vim.uv or vim.loop).now() >= expires then
					ctx.close(); vim.notify("Pairing link expired. Run /pair again.", vim.log.levels.WARN); return false
				end
				return true
			end
			local items = {}
			for _, value in ipairs(origins) do
				local url = value .. "/auth/connect/" .. pairing.code
				items[#items + 1] = { label = url, value = url }
			end
			require("opencode.ui.menu").open({ title = " Pair Server ", width = 90, sort = false, items = items, close_on_select = false,
				message = "Links work once and expire at " .. os.date("%H:%M:%S", issued_wall + pairing.expires_in) .. ".",
				confirm_label = "open selected link",
				on_select = function(item, ctx)
					if not available(ctx) then return end
					local _, open_err = vim.ui.open(item.value)
					if open_err then report({ message = tostring(open_err) }) end
				end,
				keymap_scope = "pairing_menu",
				keys = { { action = "copy", label = "copy link", handler = function(ctx, item)
					if not available(ctx) then return end
					vim.fn.setreg('"', item.value)
					local copied, result = pcall(vim.fn.setreg, "+", item.value)
					local read, value = false, nil
					if copied and result == 0 then read, value = pcall(vim.fn.getreg, "+") end
					vim.notify(read and value == item.value and "Pairing link copied" or "Pairing link is in the unnamed register", vim.log.levels.INFO)
				end } } })
		end)
	end)
end

function M.register(palette)
	palette.register({ id = "system.pair", title = "Pair Server", description = "Create single-use connection links with copy and open actions",
		category = "system", slash = { name = "pair" }, on_select = function(context) return context.run() end, run = M.show })
end

return M
