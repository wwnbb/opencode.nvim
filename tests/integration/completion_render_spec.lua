-- Exercise Neovim's actual line-grid renderer: extmark shape alone cannot
-- establish whether a source suffix stays after a ghost insertion.
describe("ghost completion rendered cells", function()
	it("lays out suffix text, Unicode, tabs, and multiline previews correctly", function()
		local stdin, stdout, stderr = vim.uv.new_pipe(false), vim.uv.new_pipe(false), vim.uv.new_pipe(false)
		local unpacker = vim.mpack.Unpacker()
		local responses, grids, errors = {}, {}, {}
		local sequence, exited = 0, false
		local process
		process = assert(vim.uv.spawn(vim.v.progpath, {
			args = { "--embed", "--headless", "--noplugin", "-u", "NONE", "-i", "NONE", "-n" },
			stdio = { stdin, stdout, stderr },
		}, function()
			exited = true
			if process and not process:is_closing() then process:close() end
		end))

		local function redraw(changes)
			for _, change in ipairs(changes) do
				for index = 2, #change do
					local args = change[index]
					if change[1] == "grid_resize" then
						local grid = {}
						for row = 1, args[3] do
							grid[row] = {}
							for col = 1, args[2] do grid[row][col] = " " end
						end
						grids[args[1]] = grid
					elseif change[1] == "grid_clear" then
						for _, row in ipairs(grids[args[1]]) do
							for col = 1, #row do row[col] = " " end
						end
					elseif change[1] == "grid_line" then
						local row, col = grids[args[1]][args[2] + 1], args[3] + 1
						for _, cell in ipairs(args[4]) do
							for _ = 1, cell[3] or 1 do row[col] = cell[1]; col = col + 1 end
						end
					end
				end
			end
		end
		stdout:read_start(function(err, data)
			if err then errors[#errors + 1] = err end
			if not data then return end
			local offset = 1
			while offset <= #data do
				local message
				message, offset = unpacker(data, offset)
				if message then
					if message[1] == 1 then responses[message[2]] = message end
					if message[1] == 2 and message[2] == "redraw" then redraw(message[3]) end
				end
			end
		end)
		stderr:read_start(function(err, data)
			if err or data then errors[#errors + 1] = err or data end
		end)

		local function request(method, args)
			sequence = sequence + 1
			local id = sequence
			stdin:write(vim.mpack.encode({ 0, id, method, args }))
			assert.is_true(vim.wait(3000, function() return responses[id] ~= nil or exited end, 5), "RPC timeout")
			local response = assert(responses[id], table.concat(errors, "\n"))
			assert.equals(vim.NIL, response[3], vim.inspect(response[3]))
			return response[4]
		end
		local function row(index)
			return grids[1] and table.concat(grids[1][index]):gsub(" +$", "")
		end
		local ok, err = pcall(function()
			request("nvim_ui_attach", { 70, 16, { rgb = true, ext_linegrid = true } })
			request("nvim_exec_lua", { [[
				vim.opt.runtimepath:append(...)
				vim.o.number, vim.o.relativenumber, vim.o.ruler = false, false, false
				vim.o.signcolumn, vim.o.foldcolumn, vim.o.tabstop = "no", "0", 4
				_G.completion_ui = require("opencode.ui.completion")
				completion_ui.setup({ enabled = true, keymaps = { trigger = false, accept = false } })
				_G.preview = function(source, col, suggestion)
					vim.api.nvim_buf_set_lines(0, 0, -1, false, { source, "after" })
					assert(completion_ui.show({ id = 1, bufnr = vim.api.nvim_get_current_buf(),
						winid = vim.api.nvim_get_current_win(), row = 0, col = col,
						changedtick = vim.api.nvim_buf_get_changedtick(0) }, suggestion))
					vim.cmd("redraw!")
				end
			]], { vim.fn.getcwd() } })
			request("nvim_exec_lua", { "preview(...)", { "local café = ()", #"local café = (", "résultat" } })
			assert.is_true(vim.wait(1000, function() return row(1) == "local café = (résultat)" end, 5))
			assert.equals("after", row(2))
			request("nvim_exec_lua", { "preview(...)", { "\tcall()", #"\tcall(", "世界" } })
			assert.is_true(vim.wait(1000, function() return row(1) == "    call(世界)" end, 5))
			request("nvim_exec_lua", { "preview(...)", {
				"class Example", #"class Example", ":\n\tdef run(self):\n\t\treturn 1",
			} })
			assert.is_true(vim.wait(1000, function() return row(1) == "class Example:" and row(4) == "after" end, 5))
			assert.equals("    def run(self):", row(2))
			assert.equals("        return 1", row(3))
			request("nvim_exec_lua", { "completion_ui.clear(); vim.cmd('redraw!')", {} })
			assert.is_true(vim.wait(1000, function() return row(1) == "class Example" and row(2) == "after" end, 5))
		end)
		if not exited then
			stdin:write(vim.mpack.encode({ 2, "nvim_command", { "qa!" } }))
			if not vim.wait(1000, function() return exited end, 5) then process:kill("sigterm") end
		end
		for _, pipe in ipairs({ stdin, stdout, stderr }) do
			if not pipe:is_closing() then pipe:close() end
		end
		if not ok then error(err) end
	end)
end)
