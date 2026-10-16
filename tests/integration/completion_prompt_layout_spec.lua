describe("completion prompt layout", function()
	local client, grids
	local function wait_for(predicate)
		local deadline = vim.uv.hrtime() + 1000000000
		repeat
			if predicate() then return true end
			vim.wait(5, function() return false end, 5)
		until vim.uv.hrtime() >= deadline
		return false
	end

	local function screen_row(row)
		return grids[1] and grids[1][row] and table.concat(grids[1][row]) or ""
	end

	local function measure()
		return client.lua([[
			vim.cmd('redraw!')
			local input = prompt.input.winid
			local border = vim.api.nvim_win_get_config(input).win
			local floats = {}
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				local cfg = vim.api.nvim_win_get_config(win)
				if cfg.relative ~= '' then
					floats[#floats + 1] = { position = vim.api.nvim_win_get_position(win), width = cfg.width, height = cfg.height }
				end
			end
			return { anchor = anchor, position = vim.api.nvim_win_get_position(input),
				border = vim.api.nvim_win_get_position(border), height = vim.api.nvim_win_get_height(input),
				width = vim.api.nvim_win_get_width(input), floats = floats,
				screen = { vim.o.columns, vim.o.lines - vim.o.cmdheight } }
		]])
	end

	local function assert_on_screen(result)
		for _, window in ipairs(result.floats) do
			assert.is_true(window.position[1] >= 0)
			assert.is_true(window.position[2] >= 0)
			assert.is_true(window.position[1] + window.height <= result.screen[2])
			assert.is_true(window.position[2] + window.width <= result.screen[1])
		end
	end

	local function rendered_input(result)
		local lines = {}
		for row = 1, result.height do
			local cells = grids[1] and grids[1][result.position[1] + row]
			lines[row] = cells and table.concat(cells, "", result.position[2] + 1,
				result.position[2] + result.width):gsub(" +$", "") or ""
		end
		return lines
	end

	local function open(row, col, split)
		client.lua([[
			local row, col, split = ...
			if split then vim.cmd('vsplit') end
			_G.source = vim.api.nvim_get_current_win()
			_G.source_buf = vim.api.nvim_get_current_buf()
			vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, vim.fn['repeat']({ string.rep('x', 100) }, 30))
			vim.wo.wrap = false
			vim.api.nvim_win_set_cursor(source, { row, col })
			vim.cmd('redraw!')
			_G.anchor = vim.fn.screenpos(source, row, col + 1)
			_G.cancelled = 0
			_G.prompt = require('opencode.ui.completion_prompt').open({ winid = source, title = 'Completion',
				model = { modelID = 'test-model' }, on_submit = function() end,
				on_cancel = function() cancelled = cancelled + 1 end })
		]], { row or 3, col or 4, split == true })
	end

	before_each(function()
		grids = {}
		client = require("tests.helpers.embedded_editor").new({
			on_notification = function(event, changes)
				if event ~= "redraw" then return end
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
			end,
		})
		client.request("nvim_ui_attach", { 80, 24, { rgb = true, ext_linegrid = true } })
		client.lua([[
			require('opencode.state').set_config({ input = { min_height = 1, max_height = 20 } })
			vim.o.showmode, vim.o.ruler = false, false
			vim.wo.number, vim.wo.relativenumber = false, false
			vim.wo.signcolumn = 'no'
		]])
	end)

	after_each(function() client.close() end)

	it("renders the composer directly below the invoking cursor", function()
		open()
		client.feed("instruction")
		local result = measure()
		assert.equals(result.anchor.row, result.border[1])
		assert.equals(result.anchor.col - 1, result.border[2])
		assert_on_screen(result)
		assert.is_true(wait_for(function()
			return screen_row(result.position[1] + 1):find("instruction", 1, true) ~= nil
		end))
		assert.is_true(screen_row(result.position[1] + 3):find("Completion test-model", 1, true) ~= nil)
		assert.is_nil(screen_row(result.position[1] + 3):find("agent", 1, true))
	end)

	it("places both composer surfaces above a cursor near the bottom", function()
		open(20, 4)
		local result = measure()
		assert.is_true(result.border[1] < result.anchor.row - 1)
		for _, window in ipairs(result.floats) do
			assert.is_true(window.position[1] + window.height <= result.anchor.row - 1)
		end
		assert_on_screen(result)
	end)

	it("keeps the right edge within the screen", function()
		open(3, 74)
		local result = measure()
		assert.is_true(result.border[2] < result.anchor.col - 1)
		assert_on_screen(result)
		assert.equals(result.screen[1], result.border[2] + result.width + 2)
	end)

	it("grows with multiline instructions and reflows in a small split", function()
		open(3, 4, true)
		client.feed("one<CR>two<CR>three")
		assert.is_true(wait_for(function() return measure().height == 3 end))
		assert_on_screen(measure())
		client.request("nvim_ui_try_resize", { 40, 12 })
		assert.is_true(wait_for(function() return measure().screen[1] == 40 end))
		local result = measure()
		assert_on_screen(result)
		assert.is_true(result.width <= client.lua("return vim.api.nvim_win_get_width(source)") - 2)
		assert.same({ "one", "two", "three" }, client.lua("return vim.api.nvim_buf_get_lines(prompt.input.bufnr, 0, -1, false)"))
	end)

	it("keeps the first instruction line visible after Enter grows the prompt", function()
		open()
		client.feed("hey")
		assert.is_true(wait_for(function()
			return vim.deep_equal(rendered_input(measure()), { "hey" })
		end))
		client.feed("<CR>")
		assert.is_true(wait_for(function() return measure().height == 2 end))
		assert.same({ "hey", "" }, rendered_input(measure()))
		client.feed("there")
		assert.is_true(wait_for(function()
			return vim.deep_equal(rendered_input(measure()), { "hey", "there" })
		end))
		client.feed(string.rep("<BS>", 6))
		assert.is_true(wait_for(function()
			return vim.deep_equal(rendered_input(measure()), { "hey" })
		end))
	end)

	it("keeps wrapped text visible while growing and shrinking", function()
		open(3, 4, true)
		local width = measure().width
		local first = string.rep("a", width - 1)
		client.feed(first)
		assert.is_true(wait_for(function()
			return vim.deep_equal(rendered_input(measure()), { first })
		end))
		client.feed("BC")
		assert.is_true(wait_for(function() return measure().height == 2 end))
		assert.same({ first .. "B", "C" }, rendered_input(measure()))
		client.feed("<BS><BS>")
		assert.is_true(wait_for(function()
			return vim.deep_equal(rendered_input(measure()), { first })
		end))
	end)

	it("shows the end of a large native paste after growing to its maximum height", function()
		client.lua("require('opencode.state').set_config({ input = { min_height = 1, max_height = 3 } })")
		open()
		local lines = {}
		for row = 1, 8 do lines[row] = "pasted " .. row end
		assert.is_true(client.request("nvim_paste", { table.concat(lines, "\n"), false, -1 }))
		assert.is_true(wait_for(function() return measure().height == 3 end))
		assert.same({ "pasted 6", "pasted 7", "pasted 8" }, rendered_input(measure()))
		assert.same(lines, client.lua("return vim.api.nvim_buf_get_lines(prompt.input.bufnr, 0, -1, false)"))
		client.lua([[
			vim.api.nvim_win_set_cursor(prompt.input.winid, { 4, 0 })
			vim.cmd('normal! zt')
			vim.api.nvim_exec_autocmds('TextChangedI', { buffer = prompt.input.bufnr })
		]])
		assert.is_true(wait_for(function()
			return vim.deep_equal(rendered_input(measure()), { "pasted 4", "pasted 5", "pasted 6" })
		end))
	end)

	it("tears down both surfaces when the source window closes", function()
		open(3, 4, true)
		local prompt_buf = client.lua("return prompt.input.bufnr")
		client.lua("vim.api.nvim_win_close(source, true)")
		assert.is_true(wait_for(function() return client.lua("return cancelled") == 1 end))
		assert.equals(1, client.lua("return #vim.api.nvim_list_wins()"))
		assert.is_false(client.lua("return vim.api.nvim_buf_is_valid(...)", { prompt_buf }))
	end)
end)
