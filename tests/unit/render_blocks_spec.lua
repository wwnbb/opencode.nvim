local render_blocks = require("opencode.ui.chat.render_blocks")
local render_context = require("opencode.ui.chat.render_context")

local function context()
	return render_context.new({ current_session = { id = "blocks-unit" } })
end

local function layout(ctx)
	local blocks = ctx:finish_blocks()
	local result = {}
	for _, block in ipairs(blocks) do result[#result + 1] = { block.key, block.start, block.finish } end
	return result, blocks
end

local function frame_of(ctx, positions)
	local blocks = ctx:finish_blocks()
	return { lines = ctx.raw_lines, nui_lines = ctx.nui_lines, highlights = ctx.content_highlights,
		blocks = blocks, positions = positions }
end

describe("render block recording", function()
	it("gives a separator before a block's first line to the block above", function()
		local ctx = context()
		ctx:begin_block("a")
		ctx:add_raw_line("one")
		ctx:add_raw_line("")
		ctx:begin_block("b")
		ctx:ensure_single_blank_separator() -- trims a's blank and adds it back
		ctx:add_raw_line("two")
		ctx:ensure_single_blank_separator() -- inside b: b already has a line
		ctx:add_raw_line("three")
		ctx:begin_block("c")
		ctx:begin_block("d") -- empty blocks in between do not take the separator
		ctx:ensure_single_blank_separator()
		ctx:add_raw_line("four")
		assert.same({ { "a", 0, 2 }, { "b", 2, 6 }, { "d", 6, 7 } }, (layout(ctx)))
	end)

	it("keeps a leading separator in the first block", function()
		local ctx = context()
		ctx:begin_block("text", "p1")
		ctx:ensure_single_blank_separator()
		ctx:add_raw_line("body")
		assert.same({ { "head", 0, 1 }, { "text:p1", 1, 2 } }, (layout(ctx)))
	end)

	it("moves a blank taken from the block above into the next block", function()
		local ctx = context()
		ctx:begin_block("tool", "row")
		ctx:add_raw_line("→ Read /srv", "tool")
		ctx:add_raw_line("")
		ctx:begin_block("permission", "p")
		assert.is_true(ctx:take_trailing_blank())
		ctx:add_raw_line("✓ Allowed", "tool")
		ctx:add_raw_line("")
		-- The empty head block is dropped.
		assert.same({ { "tool:row", 0, 1 }, { "permission:p", 1, 3 } }, (layout(ctx)))
		assert.equals(0, #select(2, layout(context())))
	end)

	it("drops empty blocks and records highlight ranges", function()
		local ctx = context()
		ctx:begin_block("empty-one")
		ctx:begin_block("x")
		ctx:add_raw_line("line")
		ctx:append_relative_highlights({ { line = 0, col_start = 0, col_end = 2, hl_group = "Comment" } }, 0)
		local result, blocks = layout(ctx)
		assert.same({ { "x", 0, 1 } }, result)
		assert.equals(1, blocks[1].highlight_start)
		assert.equals(1, blocks[1].highlight_finish)
		assert.equals(ctx.syntax_generation, blocks.syntax_generation)
	end)

	it("drops the signature of a block with uncached lines", function()
		local ctx = context()
		ctx:begin_block("user", "u", "cache-key")
		ctx:add_raw_line("prompt")
		ctx:unsign_block()
		local _, blocks = layout(ctx)
		assert.is_nil(blocks[1].signature)
	end)
end)

describe("render block verifier", function()
	local function two_blocks()
		local ctx = context()
		ctx:begin_block("a")
		ctx:add_raw_line("one")
		ctx:add_raw_line("two")
		ctx:begin_block("b")
		ctx:add_raw_line("three")
		return ctx
	end

	it("accepts a consistent frame and reports positions inside their owner", function()
		local frame = frame_of(two_blocks(), {
			questions = { a = { start_line = 0, end_line = 1, highlights = { { line = 1, hl_group = "X" } } } },
		})
		frame.blocks[1].key = "question:a"
		assert.same({}, render_blocks.verify(frame))
	end)

	it("reports highlights that cross a block boundary", function()
		local ctx = two_blocks()
		ctx:append_relative_highlights({ { line = 1, end_line = 2, col_start = 0, col_end = 1, hl_group = "Cross" } }, 0)
		local violations = render_blocks.verify(frame_of(ctx))
		assert.equals(1, #violations)
		assert.is_truthy(violations[1]:find("Cross", 1, true))
	end)

	it("reports widget ranges, widget highlights and children outside one block", function()
		local frame = frame_of(two_blocks(), {
			tools = {
				wide = { start_line = 1, end_line = 2 },
				lit = { start_line = 0, end_line = 0, highlights = { { line = 0, end_line = 2, hl_group = "Wide" } } },
				nested = { start_line = 0, end_line = 0, children = { c = { start_line = 2, end_line = 2 } } },
			},
		})
		local violations = table.concat(render_blocks.verify(frame), "\n")
		assert.is_truthy(violations:find("tools.wide lines 1-2", 1, true))
		assert.is_truthy(violations:find("Wide", 1, true))
		assert.is_truthy(violations:find("tools.nested/c", 1, true))
		assert.is_truthy(violations:find("tools.lit lies in block a, expected tool:lit", 1, true))
	end)

	it("reports duplicate keys, gaps and uncovered lines", function()
		local frame = frame_of(two_blocks())
		frame.blocks[2].key = "a"
		frame.blocks[2].start = 3
		frame.lines[#frame.lines + 1] = "extra"
		local violations = table.concat(render_blocks.verify(frame), "\n")
		assert.is_truthy(violations:find("duplicate key a", 1, true))
		assert.is_truthy(violations:find("starts at 3, expected 2", 1, true))
		assert.is_truthy(violations:find("cover 3 of 4 lines", 1, true))
	end)

	it("reports a spinner footer outside the processing block", function()
		local violations = render_blocks.verify(frame_of(two_blocks(), { spinner_footer = { start_line = 0, end_line = 0 } }))
		assert.equals(1, #violations)
	end)
end)

-- Build a diffable frame from { key, lines, signature?, highlights?, owned? } specs.
local function diff_frame(specs)
	local NuiLine, NuiText = require("nui.line"), require("nui.text")
	local frame = { lines = {}, nui_lines = {}, highlights = {}, blocks = {}, owned = {} }
	for _, spec in ipairs(specs) do
		local block = { key = spec[1], signature = spec.signature, start = #frame.lines,
			highlight_start = #frame.highlights + 1 }
		for _, text in ipairs(spec[2]) do
			local line = NuiLine()
			line:append(NuiText(text, spec.text_hl))
			frame.lines[#frame.lines + 1] = text
			frame.nui_lines[#frame.nui_lines + 1] = line
		end
		for _, hl in ipairs(spec.highlights or {}) do
			frame.highlights[#frame.highlights + 1] = vim.tbl_extend("force", {}, hl, { line = block.start + hl.line })
		end
		block.finish, block.highlight_finish = #frame.lines, #frame.highlights
		frame.owned[block.key] = spec.owned
		frame.blocks[#frame.blocks + 1] = block
	end
	return frame
end

local function spans(runs)
	local result = {}
	for _, run in ipairs(runs) do
		result[#result + 1] = { run.start, run.finish, run.old_start, run.old_finish, run.first, run.last,
			run.marks or false }
	end
	return result
end

describe("render block diff", function()
	it("finds no runs for identical frames and ignores NuiLine identity", function()
		local specs = { { "a", { "one", "two" }, text_hl = "A" }, { "b", { "three" } } }
		assert.same({}, spans(render_blocks.diff(diff_frame(specs), diff_frame(specs))))
	end)

	it("rewrites only the changed block and coalesces adjacent changes", function()
		local old = diff_frame({ { "a", { "1" } }, { "b", { "2" } }, { "c", { "3" } }, { "d", { "4" } } })
		local new = diff_frame({ { "a", { "1" } }, { "b", { "2!", "2b" } }, { "c", { "3!" } }, { "d", { "4" } } })
		assert.same({ { 1, 4, 1, 3, 2, 3, false } }, spans(render_blocks.diff(old, new)))
	end)

	it("handles insertions, removals and reorders as remove plus insert", function()
		local old = diff_frame({ { "a", { "1" } }, { "b", { "2" } }, { "c", { "3" } } })
		local inserted = diff_frame({ { "x", { "0" } }, { "a", { "1" } }, { "b", { "2" } }, { "c", { "3" } }, { "y", { "9" } } })
		assert.same({ { 0, 1, 0, 0, 1, 1, false }, { 4, 5, 3, 3, 5, 5, false } }, spans(render_blocks.diff(old, inserted)))
		local removed = diff_frame({ { "a", { "1" } }, { "c", { "3" } } })
		assert.same({ { 1, 1, 1, 2, nil, nil, false } }, spans(render_blocks.diff(old, removed)))
		local reordered = diff_frame({ { "c", { "3" } }, { "a", { "1" } }, { "b", { "2" } } })
		-- c matches first; a and b come after it in the old frame, so they are reinserted.
		assert.same({ { 0, 0, 0, 2, nil, nil, false }, { 1, 3, 3, 3, 2, 3, false } },
			spans(render_blocks.diff(old, reordered)))
	end)

	it("trusts equal signatures and line counts, never stale dirty blocks", function()
		local old = diff_frame({ { "a", { "1" }, signature = "s" }, { "b", { "2" } } })
		local new = diff_frame({ { "a", { "changed" }, signature = "s" }, { "b", { "2" } } })
		assert.same({}, spans(render_blocks.diff(old, new)))
		local _, mismatches = render_blocks.diff(old, new, { check_signatures = true })
		assert.same({ "a" }, mismatches)
		old.line_count, old.tick = 2, 1
		assert.is_true(render_blocks.replace(old, "b", 3, 2))
		assert.equals(4, old.line_count)
		assert.equals(2, old.tick)
		-- Equal to the stale snapshot, but the buffer holds 3 other lines.
		assert.same({ { 1, 2, 1, 4, 2, 2, false } }, spans(render_blocks.diff(old, diff_frame({ { "a", { "1" }, signature = "s" },
			{ "b", { "2" } } }))))
		assert.is_false(render_blocks.replace(old, "missing", 1, 3))
	end)

	it("rewrites only highlights when lines are equal", function()
		local old = diff_frame({ { "a", { "1" } }, { "b", { "2" }, highlights = { { line = 0, hl_group = "X" } } } })
		local moved = diff_frame({ { "a", { "1" } }, { "b", { "2" }, highlights = { { line = 0, hl_group = "Y" } } } })
		assert.same({ { 1, 2, 1, 2, 2, 2, true } }, spans(render_blocks.diff(old, moved)))
		local text = diff_frame({ { "a", { "1" }, text_hl = "T" }, { "b", { "2" }, highlights = { { line = 0, hl_group = "X" } } } })
		assert.same({ { 0, 1, 0, 1, 1, 1, true } }, spans(render_blocks.diff(old, text)))
		local list = { { line = 0, hl_group = "W" } }
		local owned = diff_frame({ { "a", { "1" }, owned = { { base = 0, highlights = list } } },
			{ "b", { "2" }, highlights = { { line = 0, hl_group = "X" } } } })
		assert.same({ { 0, 1, 0, 1, 1, 1, true } }, spans(render_blocks.diff(old, owned)))
		local shifted = diff_frame({ { "a", { "1" }, owned = { { base = 0, highlights = { { line = 0, hl_group = "W" } } } } },
			{ "b", { "2" }, highlights = { { line = 0, hl_group = "X" } } } })
		assert.same({}, spans(render_blocks.diff(owned, shifted)))
	end)

	it("compares highlights relative to their block after lines move", function()
		local old = diff_frame({ { "a", { "1" } }, { "b", { "2" }, highlights = { { line = 0, col_start = 1, hl_group = "X" } } } })
		local new = diff_frame({ { "z", { "0", "0" } }, { "a", { "1" } },
			{ "b", { "2" }, highlights = { { line = 0, col_start = 1, hl_group = "X" } } } })
		assert.same({ { 0, 2, 0, 0, 1, 1, false } }, spans(render_blocks.diff(old, new)))
	end)

	it("locates in-place ranges inside one block, honoring dirty counts", function()
		local frame = diff_frame({ { "a", { "1", "2" } }, { "b", { "3", "4" } } })
		frame.line_count = 4
		assert.equals("b", render_blocks.applied_block(frame, 2, 4).key)
		assert.is_nil(render_blocks.applied_block(frame, 1, 3))
		assert.is_nil(render_blocks.applied_block(frame, 2, 2))
		render_blocks.replace(frame, "a", 5, 1)
		local block, row, count = render_blocks.applied_block(frame, 5, 7)
		assert.same({ "b", 5, 2 }, { block.key, row, count })
		assert.same({ "a", 0, 5 }, { render_blocks.applied_block(frame, 0, 5).key, 0, 5 })
	end)

	it("groups widget-map highlights by the block holding their position", function()
		local frame = diff_frame({ { "a", { "1", "2" } }, { "b", { "3" } } })
		local list = { { line = 0, hl_group = "W" } }
		local owned = render_blocks.owned_highlights(frame.blocks, {
			{ q = { start_line = 2, highlights = list } },
			{ p = { start_line = 1, highlights = list }, empty = { start_line = 0, highlights = {} } },
		})
		assert.same({ "a", "b" }, (function() local keys = vim.tbl_keys(owned); table.sort(keys); return keys end)())
		assert.equals(1, owned.a[1].base)
		assert.equals(0, owned.b[1].base)
		assert.equals(list, owned.b[1].highlights)
		assert.equals("x", render_blocks.duplicate_key(diff_frame({ { "x", { "1" } }, { "y", { "2" } }, { "x", { "3" } } }).blocks))
	end)
end)
