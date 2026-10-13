local context = require("opencode.context")

describe("prompt context placeholders", function()
	local buffers, original, original_win, diagnostic_ns, selection_option, virtualedit_option
	local function buffer(lines, name)
		local buf = vim.api.nvim_create_buf(true, false)
		buffers[#buffers + 1] = buf
		if name then vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. name) end
		vim.bo[buf].filetype = "lua"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		return buf
	end
	local function capture(lines)
		local buf = buffer(lines or { "local unsaved = true", "print(unsaved)" }, ".lua")
		vim.api.nvim_set_current_buf(buf)
		return assert(context.capture()), buf
	end
	local function expanded(text, snapshot, opts)
		return assert(context.expand(text, opts or {}, snapshot)).text
	end
	before_each(function()
		buffers, original, original_win = {}, vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
		selection_option, virtualedit_option = vim.o.selection, vim.wo.virtualedit
		diagnostic_ns = vim.api.nvim_create_namespace("opencode-context-test")
		context.clear()
		vim.fn.setqflist({}, "r")
		vim.cmd("delmarks A-Z0-9")
	end)
	after_each(function()
		vim.cmd("silent! normal! \027")
		vim.api.nvim_set_current_win(original_win)
		vim.o.selection, vim.wo.virtualedit = selection_option, virtualedit_option
		for _, win in ipairs(vim.api.nvim_list_wins()) do if win ~= original_win then pcall(vim.api.nvim_win_close, win, true) end end
		vim.api.nvim_set_current_buf(original)
		for _, buf in ipairs(buffers) do if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end end
		vim.diagnostic.reset(diagnostic_ns)
		vim.fn.setqflist({}, "r")
		vim.cmd("delmarks A-Z0-9")
		context.clear()
	end)

	it("lists all seven contexts and filters menu entries", function()
		local names = {}; for _, item in ipairs(context.items()) do names[#names + 1] = item.name end
		assert.same({ "this", "buffer", "buffers", "diagnostics", "marks", "quickfix", "visible" }, names)
		assert.equals("this", context.items("thi")[1].name)
		assert.equals(2, #context.items("@buffer"))
	end)

	it("freezes unsaved buffers and captures cursor location without stale Visual marks", function()
		local snap, buf = capture({ "first", "second unsaved" })
		vim.api.nvim_win_set_cursor(0, { 2, 3 })
		vim.api.nvim_buf_set_mark(buf, "<", 1, 0, {})
		vim.api.nvim_buf_set_mark(buf, ">", 1, 3, {})
		snap = assert(context.capture())
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed after opening" })
		vim.api.nvim_buf_delete(buf, { force = true })
		assert.is_truthy(expanded("@buffer", snap):find("second unsaved", 1, true))
		local this = expanded("@this", snap)
		assert.is_truthy(this:find("cursor column 4", 1, true))
		assert.is_truthy(this:find("second unsaved", 1, true))
		assert.is_nil(this:find("first", 1, true))
	end)

	it("uses an explicit inclusive range and rejects invalid ranges", function()
		capture({ "one", "two", "three" })
		local snap = assert(context.capture({ range = { 2, 3 } }))
		local output = expanded("@this", snap)
		assert.is_truthy(output:find("two\nthree", 1, true))
		assert.is_nil(output:find("one", 1, true))
		for _, range in ipairs({ { 0, 2 }, { 3, 2 }, { 1, 4 }, { 1.5, 2 }, { "1", 2 } }) do
			local value, err = context.capture({ range = range })
			assert.is_nil(value); assert.is_truthy(err:find("range", 1, true))
		end
		assert.is_nil(context.capture({ range = false }))
		assert.same({ 2, 3 }, snap.range)
	end)

	it("captures only active characterwise, linewise and blockwise selections", function()
		capture({ "abc猫xyz", "defuvw", "ghirst" })
		vim.api.nvim_win_set_cursor(0, { 1, 3 })
		vim.cmd("normal! vj")
		local output = expanded("@this", assert(context.capture()))
		assert.is_truthy(output:find("猫xyz\ndefu", 1, true))
		vim.cmd("normal! \027")
		vim.api.nvim_win_set_cursor(0, { 1, 0 }); vim.cmd("normal! Vj")
		output = expanded("@this", assert(context.capture()))
		assert.is_truthy(output:find("abc猫xyz\ndefuvw", 1, true))
		vim.cmd("normal! \027")
		vim.api.nvim_win_set_cursor(0, { 2, 1 }); vim.cmd("normal! \022jl")
		output = expanded("@this", assert(context.capture()))
		assert.is_truthy(output:find("ef\nhi", 1, true))
	end)

	it("captures blockwise virtual columns across tabs and wide characters", function()
		capture({ "abcXYZ", "\tZ", "猫bcdef" })
		vim.bo.tabstop = 4
		vim.api.nvim_win_set_cursor(0, { 1, 2 }); vim.cmd("normal! \022jjl")
		local expected = table.concat(vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = "\022" }), "\n")
		local snap = assert(context.capture())
		assert.is_truthy(expanded("@this", snap):find(expected, 1, true))
	end)

	it("matches native Visual regions for exclusive edges, tabs and partial wide characters", function()
		local _, buf = capture()
		for _, lines in ipairs({ { "abcd", "defg", "hijk" }, { "猫XY", "abcd", "x" }, { "\tA", "ab猫XYZ", "a\tb" } }) do
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines); vim.bo.tabstop = 4
			for _, selection in ipairs({ "inclusive", "exclusive" }) do
				vim.o.selection = selection
				for _, virtual in ipairs({ "", "block", "all" }) do
					vim.wo.virtualedit = virtual
					for _, motion in ipairs({ "jll", "jjlll", "j0" }) do
						for _, mode in ipairs({ "v", "\022" }) do
							vim.cmd("normal! \027"); vim.api.nvim_win_set_cursor(0, { 1, 0 }); vim.cmd("normal! " .. mode .. motion)
							local expected = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
							local snap = assert(context.capture())
							assert.same(expected, snap.values.this.blocks[1].lines)
						end
					end
				end
			end
			vim.cmd("normal! \027")
		end
	end)

	it("orders loaded listed buffers with source first and includes unnamed buffers", function()
		local hidden = buffer({ "hidden secret" }, ".txt"); vim.bo[hidden].buflisted = false
		local special = buffer({ "special secret" }, ".txt"); vim.bo[special].buftype = "nofile"
		local other = buffer({ "other unsaved" }, ".lua")
		local source = buffer({ "unnamed unsaved" })
		vim.api.nvim_set_current_buf(source)
		local output = expanded("@buffers", assert(context.capture()))
		assert.is_truthy(output:find("[Buffer " .. source .. "]", 1, true))
		assert.is_true(output:find("unnamed unsaved", 1, true) < output:find("other unsaved", 1, true))
		assert.is_truthy(output:find(vim.api.nvim_buf_get_name(other), 1, true))
		assert.is_nil(output:find("hidden secret", 1, true)); assert.is_nil(output:find("special secret", 1, true))
	end)

	it("filters diagnostics by overlap with selected lines", function()
		local _, buf = capture({ "one", "two", "three", "four" })
		vim.diagnostic.set(diagnostic_ns, buf, {
			{ lnum = 0, col = 0, end_lnum = 2, end_col = 1, message = "overlap", severity = vim.diagnostic.severity.WARN },
			{ lnum = 0, col = 0, end_lnum = 1, end_col = 0, message = "exclusive endpoint", severity = vim.diagnostic.severity.INFO },
			{ lnum = 3, col = 0, message = "outside", severity = vim.diagnostic.severity.ERROR },
		})
		local output = expanded("@diagnostics", assert(context.capture({ range = { 2, 2 } })))
		assert.is_truthy(output:find("[WARN] overlap", 1, true)); assert.is_nil(output:find("outside", 1, true))
		assert.is_nil(output:find("exclusive endpoint", 1, true))
		assert.is_truthy(expanded("@diagnostics", assert(context.capture())):find("outside", 1, true))
	end)

	it("freezes global marks and quickfix metadata without loading other files", function()
		local _, buf = capture({ "marked unsaved line" })
		vim.api.nvim_buf_set_mark(buf, "A", 1, 2, {})
		vim.fn.setqflist({ { bufnr = buf, lnum = 1, col = 3, type = "E", text = "quickfix message" } }, "r")
		local snap = assert(context.capture())
		vim.fn.setqflist({}, "r"); vim.cmd("delmarks A")
		assert.is_truthy(expanded("@marks", snap):find("'A", 1, true))
		assert.is_truthy(expanded("@marks", snap):find("marked unsaved line", 1, true))
		assert.is_truthy(expanded("@quickfix", snap):find(":1:3 [E] quickfix message", 1, true))
	end)

	it("captures all ordinary windows but omits floats and folded interiors", function()
		local _, buf = capture({ "fold start", "fold secret", "fold end", "visible after fold" })
		vim.wo.foldmethod = "manual"; vim.cmd("1,3fold")
		local other = buffer({ "other window text" }, ".lua")
		vim.cmd("vsplit"); vim.api.nvim_set_current_buf(other)
		local floating = buffer({ "float secret" }, ".lua")
		vim.api.nvim_open_win(floating, false, { relative = "editor", width = 10, height = 1, row = 1, col = 1 })
		vim.api.nvim_set_current_win(original_win)
		assert.equals(buf, vim.api.nvim_get_current_buf())
		local output = expanded("@visible", assert(context.capture()))
		assert.is_truthy(output:find("fold start", 1, true)); assert.is_truthy(output:find("visible after fold", 1, true))
		assert.is_truthy(output:find("other window text", 1, true))
		assert.is_nil(output:find("fold secret", 1, true)); assert.is_nil(output:find("fold end", 1, true))
		assert.is_nil(output:find("float secret", 1, true))
	end)

	it("labels empty lists and allows global contexts with no editor source", function()
		local special = buffer({ "not editor text" }); vim.bo[special].buftype = "nofile"
		vim.api.nvim_set_current_buf(special); context.clear()
		local snap = assert(context.capture())
		assert.equals("No quickfix entries.", expanded("@quickfix", snap))
		assert.equals("No global marks.", expanded("@marks", snap))
		local value, err = context.expand("@buffer", {}, snap)
		assert.is_nil(value); assert.is_truthy(err:find("No source editor buffer", 1, true))
	end)

	it("recognizes exact tokens, escapes literals, and does not expand inserted text", function()
		local snap = capture({ "literal @diagnostics" })
		for _, text in ipairs({ "user@buffer", "@buffer.lua", "dir/@buffer", "@buffers_more", "@buffer/path", "猫@buffer", "\\@buffer" }) do
			assert.is_false(context.has(text), text)
		end
		assert.is_true(context.has("(@buffer), @this."))
		assert.equals("@buffer", expanded("\\@buffer", nil))
		local output = expanded("@buffer", snap)
		assert.is_truthy(output:find("literal @diagnostics", 1, true))
	end)

	it("protects mention ranges and shifts byte offsets after replacements", function()
		local snap = capture({ "猫🙂" })
		local text = "@this @buffer @quickfix"
		local opts = { parts = {
			{ type = "agent", name = "buffer", source = { value = "@buffer", start = 6, ["end"] = 13 } },
			{ type = "skill", id = "quickfix", source = { value = "@quickfix", start = 14, ["end"] = 23 } },
		} }
		local original_opts = vim.deepcopy(opts)
		local output = assert(context.expand(text, opts, snap))
		assert.is_truthy(output.text:find("@buffer @quickfix", 1, true))
		for _, part in ipairs(output.options.parts) do
			assert.equals(part.source.value, output.text:sub(part.source.start + 1, part.source["end"]))
		end
		assert.same(original_opts, opts)
		assert.is_false(context.has("@buffer", { parts = { { type = "agent", source = { value = "@buffer", start = 0, ["end"] = 7 } } } }))
	end)

	it("keeps a closing code fence separate from inline suffixes and their mentions", function()
		local snap = capture({ "local value = 1" })
		local text = "Explain @buffer please @build"
		local start = assert(text:find("@build", 1, true)) - 1
		local output = assert(context.expand(text, { parts = {
			{ type = "agent", name = "build", source = { value = "@build", start = start, ["end"] = start + 6 } },
		} }, snap))
		assert.is_truthy(output.text:find("local value = 1\n```\n please @build", 1, true))
		local source = output.options.parts[1].source
		assert.equals("@build", output.text:sub(source.start + 1, source["end"]))
		assert.is_nil(expanded("@buffer\nnext", snap):find("```\n\nnext", 1, true))
	end)

	it("resolves moved file markers in original text and ignores injected markers", function()
		local snap = capture({ "[Image 1] [Image 2]" })
		local text = "@this moved [Image 1]"
		local opts = { parts = {
			{ type = "file", source = { text = { value = "[Image 1]", start = 0, ["end"] = 9 } } },
			{ type = "file", source = { text = { value = "[Image 2]", start = 0, ["end"] = 9 } } },
		} }
		local output = assert(context.expand(text, opts, snap))
		local position = output.options.parts[1].source.text
		assert.equals("[Image 1]", output.text:sub(position.start + 1, position["end"]))
		assert.is_true(position.start > output.text:find("moved", 1, true))
		assert.is_nil(output.options.parts[2].source)
	end)

	it("removes only automatic context when an unprotected placeholder expands", function()
		local snap = capture()
		local automatic = { type = "text", text = "auto", _editor_context = {} }
		local manual = { type = "text", text = "manual" }
		local opts = { context = { automatic, manual } }
		assert.same({ manual }, assert(context.expand("@this", opts, snap)).options.context)
		assert.same(opts.context, assert(context.expand("literal", opts, snap)).options.context)
	end)

	it("shares a byte budget across tokens, truncates on lines and preserves fences", function()
		capture({ "猫🙂", "```", string.rep("large", 500), "must not appear" })
		local snap = assert(context.capture({ max_bytes = 160 }))
		local output = expanded("@buffer\n@buffer", snap)
		assert.is_truthy(output:find("猫🙂", 1, true))
		assert.is_nil(output:find("large", 1, true)); assert.is_nil(output:find("must not appear", 1, true))
		assert.is_truthy(output:find("````lua\n猫🙂\n```\n````", 1, true))
		assert.is_truthy(output:find("[Context truncated: byte limit]", 1, true))
		assert.is_true(#output <= 160 + 2 * (#"[Context truncated: byte limit]" + 1) + 1)
	end)

	it("bounds buffer reads instead of copying an entire oversized buffer", function()
		local lines = {}; for i = 1, 5000 do lines[i] = string.rep("x", 80) end
		capture(lines)
		local original_read, reads, largest = vim.api.nvim_buf_get_lines, 0, 0
		vim.api.nvim_buf_get_lines = function(buf, first, final, strict)
			reads = reads + 1; largest = math.max(largest, final - first)
			return original_read(buf, first, final, strict)
		end
		local ok, snap = pcall(context.capture, { max_bytes = 200 })
		vim.api.nvim_buf_get_lines = original_read
		assert.is_true(ok, snap); assert.equals(1, largest); assert.is_true(reads < 20)
	end)

	it("jumps folded interiors and retains every fitting block before truncation", function()
		local lines = { "fold start" }; for _ = 1, 4999 do lines[#lines + 1] = "hidden" end
		lines[#lines + 1] = "visible end"
		capture(lines)
		vim.wo.foldmethod = "manual"; vim.cmd("1,5000fold")
		local original_fold, calls = vim.fn.foldclosed, 0
		vim.fn.foldclosed = function(row) calls = calls + 1; return original_fold(row) end
		local ok, snap = pcall(context.capture, { max_bytes = 200 })
		vim.fn.foldclosed = original_fold
		assert.is_true(ok, snap); assert.is_true(calls < 10)
		local output = expanded("@visible", snap)
		assert.is_truthy(output:find("visible end", 1, true))
		vim.fn.setqflist({ { text = "one" }, { text = "two" }, { text = string.rep("x", 200) } }, "r")
		output = expanded("@quickfix", assert(context.capture({ max_bytes = 80 })))
		assert.is_truthy(output:find("one", 1, true)); assert.is_truthy(output:find("two", 1, true))
		assert.is_truthy(output:find("[Context truncated: byte limit]", 1, true))
	end)

	it("preserves the active selection across leaving the editor window", function()
		local _, buf = capture({ "abcXYZ", "\tZ", "猫bcdef" })
		vim.bo.tabstop = 4
		vim.api.nvim_win_set_cursor(0, { 1, 2 }); vim.cmd("normal! \022jjl")
		context.observe()
		vim.cmd("normal! \027")
		local utility = buffer({ "utility" }); vim.bo[utility].buftype = "nofile"
		vim.api.nvim_set_current_buf(utility)
		local output = expanded("@this", assert(context.capture()))
		assert.is_truthy(output:find("cX\n  \nbc", 1, true))
		assert.equals(utility, vim.api.nvim_get_current_buf())
		assert.is_true(vim.api.nvim_buf_is_loaded(buf))
	end)
end)
