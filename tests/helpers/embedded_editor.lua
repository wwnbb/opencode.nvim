-- A real child Neovim; feature bootstrap and line-grid interpretation stay local.
local M = {}

function M.new(opts)
	opts = opts or {}
	local stdin, stdout, stderr = vim.uv.new_pipe(false), vim.uv.new_pipe(false), vim.uv.new_pipe(false)
	local unpacker, responses, errors = vim.mpack.Unpacker(), {}, {}
	local sequence, exited, process = 0, false, nil
	process = assert(vim.uv.spawn(vim.v.progpath, {
		args = { "--embed", "--headless", "--noplugin", "-u", opts.init or (vim.fn.getcwd() .. "/tests/minimal_init.lua"), "-i", "NONE", "-n" },
		stdio = { stdin, stdout, stderr },
	}, function()
		exited = true
		if process and not process:is_closing() then process:close() end
	end))
	stdout:read_start(function(err, data)
		if err then errors[#errors + 1] = err end
		if not data then return end
		local offset = 1
		while offset <= #data do
			local message
			message, offset = unpacker(data, offset)
			if message then
				if message[1] == 1 then responses[message[2]] = message end
				if message[1] == 2 and opts.on_notification then opts.on_notification(message[2], message[3]) end
			end
		end
	end)
	stderr:read_start(function(err, data) if err or data then errors[#errors + 1] = err or data end end)
	local client = {}
	function client.request(method, args)
		sequence = sequence + 1
		local id = sequence
		stdin:write(vim.mpack.encode({ 0, id, method, args }))
		assert(vim.wait(3000, function() return responses[id] ~= nil or exited end, 5), "RPC timeout")
		local response = assert(responses[id], table.concat(errors, "\n"))
		assert(response[3] == vim.NIL, vim.inspect(response[3]))
		return response[4]
	end
	function client.lua(code, args) return client.request("nvim_exec_lua", { code, args or {} }) end
	function client.feed(keys)
		client.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(..., true, false, true), 'mt', false)", { keys })
	end
	function client.close()
		if not exited then
			stdin:write(vim.mpack.encode({ 2, "nvim_command", { "qa!" } }))
			if not vim.wait(1000, function() return exited end, 5) then process:kill("sigterm") end
		end
		for _, pipe in ipairs({ stdin, stdout, stderr }) do if not pipe:is_closing() then pipe:close() end end
	end
	return client
end

return M
