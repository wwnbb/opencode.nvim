-- Exercise Neovim's actual line-grid renderer: extmark shape alone cannot
-- establish whether a source suffix stays after a ghost insertion.
describe("ghost completion rendered cells", function()
	it("keeps the Insert-mode screen cursor fixed through loading, preview, and dismissal", function()
		local screen_cursor
		local client = require("tests.helpers.embedded_editor").new({
			init = "NONE",
			on_notification = function(event, changes)
				if event ~= "redraw" then return end
				for _, change in ipairs(changes) do
					if change[1] == "grid_cursor_goto" then screen_cursor = change[#change] end
				end
			end,
		})
		local function position()
			local buffer = client.lua("vim.cmd('redraw!'); return position()")
			vim.wait(50, function() return false end, 5)
			return { buffer, screen_cursor }
		end
		local ok, err = pcall(function()
			client.request("nvim_ui_attach", { 70, 16, { rgb = true, ext_linegrid = true } })
			client.lua([[
				vim.opt.runtimepath:append(...)
				vim.o.number, vim.o.relativenumber, vim.o.ruler = false, false, false
				vim.o.showmode = false
				vim.o.signcolumn, vim.o.foldcolumn, vim.o.tabstop = "no", "0", 4
				_G.completion_ui = require("opencode.ui.completion")
				completion_ui.setup({ enabled = true, keymaps = { trigger = false, accept = false } })
				_G.position = function()
					return { vim.api.nvim_win_get_cursor(0),
						vim.api.nvim_buf_get_changedtick(0), vim.bo.modified }
				end
			]], { vim.fn.getcwd() })
			client.feed("i")
			assert.is_true(vim.wait(1000, function() return client.lua("return vim.api.nvim_get_mode().mode") == "i" end, 5))
			for _, case in ipairs({
				{ "    ", 4, "return value" },
				{ "local café = ()", #"local café = (", "résultat" },
				{ "\tcall()", #"\tcall(", "世界" },
				{ "class Example", #"class Example", ":\n\tpass" },
			}) do
				client.lua([[
					local source, col = ...
					vim.api.nvim_buf_set_lines(0, 0, -1, false, { source, "after" })
					vim.api.nvim_win_set_cursor(0, { 1, col })
					vim.bo.modified = false
					_G.snapshot = { bufnr = vim.api.nvim_get_current_buf(), row = 0, col = col }
				]], { case[1], case[2] })
				local before = position()
				assert.is_not_nil(screen_cursor)
				assert.is_true(client.lua("return completion_ui.pending(snapshot)"))
				assert.same(before, position())
				assert.is_true(client.lua("return completion_ui.show(snapshot, ...)", { vim.fn.strcharpart(case[3], 0, 1) }))
				assert.same(before, position())
				assert.is_true(client.lua("return completion_ui.show(snapshot, ...)", { case[3] }))
				assert.same(before, position())
				client.lua("completion_ui.clear()")
				assert.same(before, position())
				assert.same({ case[1], "after" }, client.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"))
			end
		end)
		client.close()
		if not ok then error(err) end
	end)

	it("lays out suffix text, Unicode, tabs, and multiline previews correctly", function()
		local grids = {}

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
		local client = require("tests.helpers.embedded_editor").new({
			init = "NONE",
			on_notification = function(event, changes) if event == "redraw" then redraw(changes) end end,
		})
		local request = client.request
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
		client.close()
		if not ok then error(err) end
	end)
end)
