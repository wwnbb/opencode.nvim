-- Rendered widget trees. Roots own buffer replacement and highlights; children
-- retain their own identity, expansion state and cursor ranges.
local M = {}

function M.find(nodes, id)
	for key, node in pairs(nodes or {}) do
		if key == id then return node, key end
		local child = M.find(node.children, id)
		if child then return child, key end
	end
end

function M.at_line(nodes, line, predicate)
	for id, node in pairs(nodes or {}) do
		if node.start_line and line >= node.start_line and line <= node.end_line then
			local child_id, child = M.at_line(node.children, line, predicate)
			if child then return child_id, child end
			if not predicate or predicate(node, id) then return id, node end
		end
	end
end

-- Positions are relative to the containing node, including nested children.
function M.positions(nodes, base_line, generation)
	local result = {}
	for id, node in pairs(nodes or {}) do
		local pos = vim.tbl_extend("force", {}, node)
		if node.start_line then
			pos.start_line = base_line + node.start_line
			pos.end_line = base_line + node.end_line
			pos.children = M.positions(node.children, pos.start_line, generation)
		end
		pos.render_generation = generation
		result[id] = pos
	end
	return result
end

function M.collapse(nodes, expansions)
	for id, node in pairs(nodes or {}) do
		expansions[id] = nil
		M.collapse(node.children, expansions)
	end
end

-- Compose a child renderer without giving it its parent's state or accumulator.
function M.append(result, node, rendered)
	result.children = result.children or {}
	result.children[node.id] = node
	if not rendered then return end
	local offset = #result.lines
	node.start_line = offset
	vim.list_extend(result.lines, rendered.lines)
	node.end_line = #result.lines - 1
	node.children = rendered.children
	for _, hl in ipairs(rendered.highlights or {}) do
		local shifted = vim.tbl_extend("force", {}, hl)
		shifted.line = offset + (hl.line or 0)
		if hl.end_line then shifted.end_line = offset + hl.end_line end
		result.highlights[#result.highlights + 1] = shifted
	end
end

return M
