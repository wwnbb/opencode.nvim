local tree = require("opencode.ui.chat.widget_tree")

describe("widget trees", function()
	it("targets the deepest visible node and resolves its owning root", function()
		local leaf = { start_line = 4, end_line = 6 }
		local nodes = { root = { start_line = 1, end_line = 10, children = {
			child = { start_line = 2, end_line = 8, children = { leaf = leaf } }, hidden = {},
		} } }
		assert.equals("root", tree.at_line(nodes, 1))
		assert.equals("child", tree.at_line(nodes, 3))
		local hit_id, hit, owner = tree.at_line(nodes, 5)
		assert.equals("leaf", hit_id)
		assert.equals(leaf, hit)
		assert.equals("root", owner)
		assert.is_nil(tree.at_line(nodes, 11))
		local found, root = tree.find(nodes, "leaf")
		assert.equals(leaf, found)
		assert.equals("root", root)
		local expansions = { root = true, child = true, leaf = true, hidden = true, other = true }
		tree.collapse(nodes.root.children, expansions)
		assert.same({ root = true, other = true }, expansions)
	end)

	it("composes relative child positions and highlights without mutating renderer output", function()
		local rendered = { lines = { "header", "body" }, highlights = { { line = 1, end_line = 2, hl_group = "Normal" } },
			children = { nested = { start_line = 1, end_line = 1 } } }
		local result = { lines = { "parent" }, highlights = {} }
		tree.append(result, { id = "child" }, rendered)
		tree.append(result, { id = "hidden" })
		assert.equals(1, result.children.child.start_line)
		assert.equals(2, result.highlights[1].line)
		assert.equals(3, result.highlights[1].end_line)
		assert.equals(1, rendered.highlights[1].line)
		local positions = tree.positions(result.children, 10, 7)
		assert.equals(11, positions.child.start_line)
		assert.equals(12, positions.child.children.nested.start_line)
		assert.equals(7, positions.child.children.nested.render_generation)
		assert.is_nil(positions.hidden.start_line)
		assert.equals(1, result.children.child.start_line)
	end)
end)
