local context = require("opencode.completion.context")
local defaults = require("opencode.config")

describe("completion editor context", function()
	local buffers, original_buf
	local function buffer(path, content, ft)
		local buf = vim.api.nvim_create_buf(true, false)
		buffers[#buffers + 1] = buf
		vim.api.nvim_buf_set_name(buf, path)
		vim.bo[buf].filetype = ft or "lua"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
		return buf
	end
	local function snapshot(buf, row, col)
		local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
		return { bufnr = buf, row = row, col = col, path = vim.api.nvim_buf_get_name(buf),
			root = "/tmp/opencode-completion-context", filetype = vim.bo[buf].filetype,
			prefix = line:sub(1, col), suffix = line:sub(col + 1) }
	end
	local function decoded(prompt) return vim.json.decode(prompt:match("Context %(JSON%):\n(.*)$")) end
	before_each(function() buffers = {}; original_buf = vim.api.nvim_get_current_buf() end)
	after_each(function()
		vim.api.nvim_set_current_buf(original_buf)
		for _, buf in ipairs(buffers) do vim.api.nvim_buf_delete(buf, { force = true }) end
	end)
	it("captures UTF-8 byte positions and the unsaved source around a hole", function()
		local buf = buffer("/tmp/opencode-completion-context/main.lua", { "local before = true", 'print("Привет")', "return value" })
		vim.api.nvim_set_current_buf(buf)
		vim.api.nvim_win_set_cursor(0, { 2, #('print("При') })
		local old_mode = vim.api.nvim_get_mode
		vim.api.nvim_get_mode = function() return { mode = "i" } end
		local ok, snap = pcall(context.capture)
		vim.api.nvim_get_mode = old_mode
		assert.is_true(ok)
		assert.equals('print("При', snap.prefix)
		assert.equals('вет")', snap.suffix)
		local data = decoded(assert(context.build(snap, defaults.merge().completion)))
		assert.equals(1, data.max_lines)
		assert.same({ "local before = true" }, data.before)
		assert.same({ "return value" }, data.after)
		assert.equals(vim.api.nvim_buf_get_changedtick(buf), snap.changedtick)
	end)
	it("prioritizes referenced open files and excludes unrelated projects and scratch buffers", function()
		local buf = buffer("/tmp/opencode-completion-context/main.lua", { 'local helper = require("util.helper")', "local result = " })
		buffer("/tmp/opencode-completion-context/sibling.lua", { "local sibling = 1" })
		local dependency = buffer("/tmp/opencode-completion-context/util/helper.lua", { "return { unsaved = true }" })
		vim.bo[dependency].readonly = true
		vim.bo[dependency].modifiable = false
		buffer("/tmp/another-completion-project/helper.lua", { "outside_project_secret" })
		local scratch = buffer("/tmp/opencode-completion-context/scratch.lua", { "scratch_secret" })
		vim.bo[scratch].buftype = "nofile"
		local prompt = assert(context.build(snapshot(buf, 1, #"local result = "), defaults.merge().completion))
		local data = decoded(prompt)
		assert.equals("util/helper.lua", data.related[1].path)
		assert.same({ "return { unsaved = true }" }, data.related[1].lines)
		assert.equals("sibling.lua", data.related[2].path)
		assert.is_nil(prompt:find("secret", 1, true))
	end)
	it("includes non-overlapping file header and obeys total serialized byte budget", function()
		local content = { "local dependency = require('library')" }
		for i = 2, 250 do content[i] = string.rep("é", 25) .. i end
		content[220] = "call()"
		local buf = buffer("/tmp/opencode-completion-context/big.lua", content)
		local opts = defaults.merge({ completion = { context = { before_lines = 3, after_lines = 3, header_lines = 2, max_bytes = 1800 } } }).completion
		local prompt = assert(context.build(snapshot(buf, 219, 5), opts, "previous"))
		assert.is_true(#prompt <= 1800)
		local data = decoded(prompt)
		assert.equals("previous", data.previous_suggestion)
		assert.equals(content[1], data.header[1])
		assert.equals(content[219], data.before[#data.before])
		assert.equals(content[221], data.after[1])
	end)
	it("never cuts UTF-8 or exceeds a small budget when source lines are huge", function()
		local buf = buffer("/tmp/opencode-completion-context/huge.lua", { string.rep("é", 2000), "x", string.rep("z", 4000) })
		local opts = defaults.merge({ completion = { context = { max_bytes = 1300 } } }).completion
		local prompt = assert(context.build(snapshot(buf, 1, 1), opts))
		assert.is_true(#prompt <= 1300)
		assert.same({}, decoded(prompt).before)
		local result, err = context.build(snapshot(buf, 0, 2), opts)
		assert.is_nil(result)
		assert.matches("budget", err)
	end)
	it("allows opting out of related files and rejects invalid numeric configuration", function()
		local buf = buffer("/tmp/opencode-completion-context/a.lua", { "x" })
		buffer("/tmp/opencode-completion-context/b.lua", { "related" })
		local opts = defaults.merge({ completion = { context = { max_related_buffers = 0 } } }).completion
		assert.same({}, decoded(context.build(snapshot(buf, 0, 1), opts)).related)
		for _, invalid in ipairs({ { timeout_ms = 0 }, { max_lines = -1 }, { context = { max_bytes = 10 } },
			{ keymaps = { trigger = "<Tab>" } }, { keymaps = { trigger = "<C-i>", accept = "<Tab>" } } }) do
			assert.is_false(pcall(defaults.merge, { completion = invalid }))
		end
	end)
end)
