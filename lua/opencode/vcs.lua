-- Pure validation and paired-hunk projection; never reconstructs full files.
local M = {}

function M.files(value)
	if type(value) ~= "table" or not vim.islist(value) then return nil, "Invalid file diff list" end
	for _, file in ipairs(value) do
		if type(file) ~= "table" or type(file.file) ~= "string" or file.file == "" or type(file.patch) ~= "string"
			or not vim.tbl_contains({ "added", "deleted", "modified" }, file.status) then return nil, "Invalid file diff" end
		for _, key in ipairs({ "additions", "deletions" }) do
			local number = file[key]
			if type(number) ~= "number" or number < 0 or number == math.huge or number % 1 ~= 0 then return nil, "Invalid file diff statistics" end
		end
	end
	return vim.deepcopy(value)
end

function M.project(patch)
	if type(patch) ~= "string" then return nil, "Invalid patch" end
	if patch == "" then return { { before = "No textual patch", after = "No textual patch", kind = "meta" } } end
	local rows, removed, added = {}, {}, {}
	local old_line, new_line, old_count, new_count, used_old, used_new
	local last_entry
	local function flush()
		for index = 1, math.max(#removed, #added) do
			local before, after = removed[index], added[index]
			rows[#rows + 1] = { before = before and before.text or "", after = after and after.text or "",
				before_line = before and before.line, after_line = after and after.line, kind = "change" }
			if (before and before.note) or (after and after.note) then
				rows[#rows + 1] = { before = before and before.note or "", after = after and after.note or "", kind = "meta" }
			end
		end
		removed, added = {}, {}
	end
	local function valid_hunk() return old_count == nil or (used_old == old_count and used_new == new_count) end
	for _, line in ipairs(vim.split(patch, "\n", { plain = true })) do
		local old, count_old, new, count_new = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
		if old then
			if not valid_hunk() then return nil, "Invalid unified diff hunk length" end
			flush()
			old_line, new_line = tonumber(old), tonumber(new)
			old_count, new_count = tonumber(count_old) or 1, tonumber(count_new) or 1
			used_old, used_new, last_entry = 0, 0, nil
			rows[#rows + 1] = { before = line, after = line, kind = "meta", hunk = true }
		elseif line:sub(1, 3) == "@@@" then return nil, "Combined diff needs unified view"
		elseif line:sub(1, 2) == "@@" then return nil, "Invalid unified diff hunk header"
		elseif old_count ~= nil then
			local prefix = line:sub(1, 1)
			if prefix == "-" and used_old < old_count then
				last_entry = { text = line:sub(2), line = old_line }
				removed[#removed + 1] = last_entry
				old_line, used_old = old_line + 1, used_old + 1
			elseif prefix == "+" and used_new < new_count then
				last_entry = { text = line:sub(2), line = new_line }
				added[#added + 1] = last_entry
				new_line, used_new = new_line + 1, used_new + 1
			elseif prefix == " " and used_old < old_count and used_new < new_count then
				flush()
				last_entry = { before = line:sub(2), after = line:sub(2), before_line = old_line, after_line = new_line, kind = "context" }
				rows[#rows + 1] = last_entry
				old_line, new_line = old_line + 1, new_line + 1
				used_old, used_new = used_old + 1, used_new + 1
			elseif line == "\\ No newline at end of file" and last_entry then
				if last_entry.kind == "context" then rows[#rows + 1] = { before = line, after = line, kind = "meta" }
				else last_entry.note = line end
			elseif valid_hunk() then
				flush()
				if prefix == " " or ((prefix == "+" or prefix == "-") and not line:match("^[+-][+-][+-] ")) then return nil, "Invalid unified diff hunk length" end
				if line ~= "" then rows[#rows + 1] = { before = line, after = line, kind = "meta" } end
			else return nil, "Invalid unified diff hunk content" end
		else rows[#rows + 1] = { before = line, after = line, kind = "meta" } end
	end
	if not valid_hunk() then return nil, "Invalid unified diff hunk length" end
	flush()
	return rows
end

return M
