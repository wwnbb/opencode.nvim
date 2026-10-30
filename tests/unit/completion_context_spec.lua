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
	local function file(prompt) return prompt:match('<file path="[^"]*" language="[^"]*">\n(.-)</file>\n') end
	local function related(prompt)
		local found = {}
		for path, start, body in prompt:gmatch('<related path="([^"]*)" start_line="(%d+)">\n(.-)</related>\n') do
			found[#found + 1] = { path = path, start_line = tonumber(start), body = body }
		end
		return found
	end
	local function has(prompt, text) return prompt:find(text, 1, true) ~= nil end
	before_each(function() buffers = {}; original_buf = vim.api.nvim_get_current_buf() end)
	local diagnostic_ns = vim.api.nvim_create_namespace("opencode_completion_context_test")
	after_each(function()
		vim.api.nvim_set_current_buf(original_buf)
		for _, buf in ipairs(buffers) do
			vim.diagnostic.reset(diagnostic_ns, buf)
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)
	it("builds relative paths below the filesystem root", function()
		assert.equals("tmp/main.lua", context.relative("/tmp/main.lua", "/"))
		assert.equals("", context.relative("/", "/"))
		assert.equals("main.lua", context.relative("/tmp/project/main.lua", "/tmp/project"))
		assert.equals("/tmp/project-other/main.lua", context.relative("/tmp/project-other/main.lua", "/tmp/project"))
	end)
	it("keeps a root working directory in captured editor context", function()
		local buf = buffer("/tmp/opencode-completion-context/main.lua", { "value" })
		vim.api.nvim_set_current_buf(buf)
		local old_mode, old_cwd, old_root = vim.api.nvim_get_mode, vim.fn.getcwd, vim.fs.root
		vim.api.nvim_get_mode = function() return { mode = "i" } end
		vim.fn.getcwd = function() return "/" end
		vim.fs.root = function() return nil end
		local ok, snap = pcall(context.capture)
		vim.api.nvim_get_mode, vim.fn.getcwd, vim.fs.root = old_mode, old_cwd, old_root
		assert.is_true(ok)
		assert.equals("/", snap.root)
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
		local prompt = assert(context.build(snap, defaults.merge().completion))
		assert.is_true(has(prompt, "Output a single line without a newline."))
		assert.equals('local before = true\nprint("При<|cursor|>вет")\nreturn value\n', file(prompt))
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
		local found = related(prompt)
		assert.equals(2, #found)
		assert.same({ path = "util/helper.lua", start_line = 1, body = "return { unsaved = true }\n" }, found[1])
		assert.equals("sibling.lua", found[2].path)
		assert.is_true(prompt:find("<related path=", 1, true) < prompt:find("<file path=", 1, true))
		assert.is_nil(prompt:find("secret", 1, true))
		local opts = defaults.merge().completion
		opts.context.max_bytes = #prompt
		assert.equals(prompt, context.build(snapshot(buf, 1, #"local result = "), opts))
	end)
	it("includes non-overlapping file header and obeys total serialized byte budget", function()
		local content = { "local dependency = require('library')" }
		for i = 2, 250 do content[i] = string.rep("é", 25) .. i end
		content[220] = "call()"
		local buf = buffer("/tmp/opencode-completion-context/big.lua", content)
		local opts = defaults.merge({ completion = { context = { before_lines = 3, after_lines = 3, header_lines = 2, max_bytes = 1800 } } }).completion
		local prompt = assert(context.build(snapshot(buf, 219, 5), opts, "previous"))
		assert.is_true(#prompt <= 1800)
		assert.is_true(has(prompt, "<previous_suggestion>\nprevious\n</previous_suggestion>\n"))
		local source = file(prompt)
		assert.equals(content[1] .. "\n" .. content[2] .. "\n...\n", source:sub(1, #content[1] + #content[2] + 6))
		assert.is_true(has(source, content[219] .. "\ncall(<|cursor|>)\n" .. content[221] .. "\n"))
	end)
	it("marks omitted source only between a header and distant lines before the cursor", function()
		local buf = buffer("/tmp/opencode-completion-context/gap.lua", { "a", "b", "c", "d", "e", "f" })
		local function source(before_lines)
			local opts = defaults.merge({ completion = { context = { before_lines = before_lines, after_lines = 0, header_lines = 2 } } }).completion
			return file(assert(context.build(snapshot(buf, 5, 0), opts)))
		end
		assert.equals("a\nb\n...\nd\ne\n<|cursor|>f\n", source(2))
		assert.equals("a\nb\nc\nd\ne\n<|cursor|>f\n", source(3))
	end)
	it("never cuts UTF-8 or exceeds a small budget when source lines are huge", function()
		local buf = buffer("/tmp/opencode-completion-context/huge.lua", { string.rep("é", 2000), "x", string.rep("z", 4000) })
		local opts = defaults.merge({ completion = { context = { max_bytes = 1024 } } }).completion
		local prompt = assert(context.build(snapshot(buf, 1, 1), opts))
		assert.is_true(#prompt <= 1024)
		assert.equals("x<|cursor|>\n", file(prompt))
		local result, err = context.build(snapshot(buf, 0, 2), opts)
		assert.is_nil(result)
		assert.matches("budget", err)
	end)
	it("keeps the explicit instruction within the prompt budget instead of dropping it", function()
		local buf = buffer("/tmp/opencode-completion-context/prompt.lua", { "local value = " })
		local snap = snapshot(buf, 0, #"local value = ")
		local opts = defaults.merge().completion
		local instruction = 'return "é🙂" with a \\ separator'
		local prompt = assert(context.build(snap, opts, nil, instruction))
		assert.is_true(has(prompt, "<request>\n" .. instruction .. "\n</request>\n"))
		assert.equals("local value = <|cursor|>\n", file(prompt))
		opts.context.max_bytes = #prompt
		assert.equals(prompt, context.build(snap, opts, nil, instruction))
		opts.context.max_bytes = #prompt - 1
		local result, err = context.build(snap, opts, nil, instruction)
		assert.is_nil(result)
		assert.matches("instruction exceed", err, 1, true)
		assert.is_false(has(assert(context.build(snap, defaults.merge().completion)), "<request>"))
	end)
	it("allows opting out of related files and rejects invalid numeric configuration", function()
		local buf = buffer("/tmp/opencode-completion-context/a.lua", { "x" })
		buffer("/tmp/opencode-completion-context/b.lua", { "related" })
		local opts = defaults.merge({ completion = { context = { max_related_buffers = 0 } } }).completion
		assert.same({}, related(assert(context.build(snapshot(buf, 0, 1), opts))))
		for _, invalid in ipairs({ { timeout_ms = -1 }, { max_lines = -1 }, { context = { max_bytes = 10 } },
			{ keymaps = { trigger = "<Tab>" } }, { keymaps = { trigger = "<C-i>", accept = "<Tab>" } } }) do
			assert.is_false(pcall(defaults.merge, { completion = invalid }))
		end
	end)
	it("includes cursor-line diagnostics and mentions them only when present", function()
		local buf = buffer("/tmp/opencode-completion-context/lint.lua", { "local a = 1", "print(missing)", "return a" })
		local snap = snapshot(buf, 1, #"print(")
		local opts = defaults.merge().completion
		local clean = assert(context.build(snap, opts))
		assert.is_false(has(clean, "diagnostics"))
		vim.diagnostic.set(diagnostic_ns, buf, {
			{ lnum = 0, col = 0, severity = 1, message = "Above cursor" },
			{ lnum = 1, col = 6, end_lnum = 1, end_col = 13, severity = 2, source = "lua_ls", code = "undefined-global",
				message = "Undefined global `missing`." },
			{ lnum = 1, col = 0, severity = 1, message = "Error first" },
			{ lnum = 2, col = 0, severity = 1, message = "Below cursor" },
		}, { virtual_text = false, signs = false, underline = false })
		local prompt = assert(context.build(snap, opts))
		assert.is_true(has(prompt, "<diagnostics> are the editor's linter/LSP messages"))
		assert.is_true(has(prompt, "<diagnostics>\nline 2:1 ERROR: Error first\n"
			.. "line 2:7 WARN lua_ls undefined-global: Undefined global `missing`.\n</diagnostics>\n"))
		assert.is_true(has(file(prompt), "print(<|cursor|>missing)\n"))
		opts.context.max_bytes = #clean
		local fitted = assert(context.build(snap, opts))
		assert.equals(clean, fitted)
	end)
end)
