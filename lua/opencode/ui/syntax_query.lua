-- Optional purity inspection for query memoization. Unrecognized runtimes and
-- extension handlers keep the ordinary capture path; no global API is patched.
local M = {}
local plans = setmetatable({}, { __mode = "k" })
local provenance = setmetatable({}, { __mode = "k" })
local identities = setmetatable({}, { __mode = "k" })
local next_identity, next_signature = 0, 0
local pure = {
	["eq?"] = true, ["any-eq?"] = true,
	["lua-match?"] = true, ["any-lua-match?"] = true,
	["contains?"] = true, ["any-contains?"] = true,
	["any-of?"] = true, ["has-ancestor?"] = true, ["has-parent?"] = true,
	["set!"] = true, ["offset!"] = true, ["gsub!"] = true, ["trim!"] = true,
}

local function identity(value)
	local id = identities[value]
	if not id then
		next_identity = next_identity + 1
		id = next_identity
		identities[value] = id
	end
	return id
end

local function info(fn)
	if type(fn) ~= "function" then return nil end
	if provenance[fn] then return provenance[fn] end
	if not debug or type(debug.getinfo) ~= "function" then return nil end
	local ok, value = pcall(debug.getinfo, fn, "S")
	if not ok or type(value) ~= "table" or type(value.source) ~= "string"
		or type(value.linedefined) ~= "number" or type(value.lastlinedefined) ~= "number" then return nil end
	-- A function's source and definition range cannot change with its upvalues.
	-- Keep only immutable fields, rather than the introspector's returned table.
	local result = { source = value.source, linedefined = value.linedefined, lastlinedefined = value.lastlinedefined }
	provenance[fn] = result
	return result
end

local function registry(fn, name)
	if not debug or type(debug.getupvalue) ~= "function" then return nil end
	for index = 1, 100 do
		local ok, key, value = pcall(debug.getupvalue, fn, index)
		if not ok or key == nil then return nil end
		if key == name then return type(value) == "table" and value or nil end
	end
end

local function runtime_source(source)
	if type(source) ~= "string" or source:sub(1, 1) ~= "@" then return false end
	local expected = (vim.env.VIMRUNTIME or "") .. "/lua/vim/treesitter/query.lua"
	if source:sub(2) == expected then return true end
	local uv = vim.uv or vim.loop
	return uv and uv.fs_realpath(source:sub(2)) ~= nil
		and uv.fs_realpath(source:sub(2)) == uv.fs_realpath(expected)
end

local function sequence(value, auxiliary)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local length = #value
	for key in pairs(value) do
		if key ~= auxiliary and (type(key) ~= "number" or key < 1 or key > length or key % 1 ~= 0) then return false end
	end
	for index = 1, length do if rawget(value, index) == nil then return false end end
	return true
end

-- Snapshot each inspected table once. Shallow values include child identities;
-- those child tables have their own snapshots. Warm checks allocate no strings
-- or tables, but still observe additions, removals and in-place scalar edits.
local function track(snapshot, value, auxiliary)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	if snapshot.seen[value] then return true end
	snapshot.seen[value] = true
	local expected, count = {}, 0
	for key, child in pairs(value) do
		if key ~= auxiliary then
			expected[key] = child
			count = count + 1
		end
	end
	local index = #snapshot.tables
	snapshot.tables[index + 1], snapshot.tables[index + 2] = value, expected
	snapshot.tables[index + 3], snapshot.tables[index + 4] = count, auxiliary or false
	return true
end

local function unchanged(snapshot, query)
	if snapshot.native ~= query.query or snapshot.info ~= query.info
		or snapshot.patterns ~= query.info.patterns or snapshot.processed ~= query._processed_patterns
		or snapshot.captures ~= query.captures then return false end
	local tables = snapshot.tables
	for index = 1, #tables, 4 do
		local value, expected, auxiliary = tables[index], tables[index + 1], tables[index + 3]
		if getmetatable(value) ~= nil then return false end
		local count = 0
		for key, child in pairs(value) do
			if auxiliary == false or key ~= auxiliary then
				if expected[key] ~= child then return false end
				count = count + 1
			end
		end
		if count ~= tables[index + 2] then return false end
	end
	for _, handler in ipairs(snapshot.handlers) do
		if handler.registry[handler.name] ~= handler.value then return false end
	end
	return true
end

local function safe_handler(checked, handler)
	local handler_info = info(handler)
	if not handler_info or handler_info.source ~= checked.source or handler_info.linedefined < 1 then return false end
	for _, registration in ipairs(checked.registration) do
		if handler_info.linedefined >= registration.linedefined
			and handler_info.linedefined <= registration.lastlinedefined then return false end
	end
	return true
end

-- Inspect the arguments that the current runtime actually executes. Mutable
-- public info and private processed lists must agree; unknown layouts fall back
-- to capturing. Ignore only the runtime's auxiliary any-of? string-set memo.
local function inspect(query, checked)
	if type(query.info) ~= "table" or getmetatable(query.info) ~= nil
		or type(query.query) ~= "userdata" then return nil end
	local snapshot = { native = query.query, info = query.info, patterns = query.info.patterns,
		processed = query._processed_patterns, captures = query.captures, tables = {}, seen = {}, handlers = {} }
	if not track(snapshot, snapshot.patterns) or not track(snapshot, snapshot.processed)
		or not track(snapshot, snapshot.captures) then return nil end
	local names = {}
	for id in pairs(snapshot.processed) do if snapshot.patterns[id] == nil then return nil end end
	for id, patterns in pairs(snapshot.patterns) do
		if type(id) ~= "number" or id < 1 or id % 1 ~= 0 then return nil end
		local processed = snapshot.processed[id]
		if not sequence(patterns) or not track(snapshot, patterns) or not track(snapshot, processed)
			or not sequence(processed.predicates) or not track(snapshot, processed.predicates)
			or not sequence(processed.directives) or not track(snapshot, processed.directives) then return nil end
		local predicates, directives = 0, 0
		for _, pattern in ipairs(patterns) do
			if not sequence(pattern, "string_set") or not track(snapshot, pattern, "string_set")
				or type(pattern[1]) ~= "string" then return nil end
			local name = pattern[1]
			if name:sub(-1) == "!" then
				directives = directives + 1
				if processed.directives[directives] ~= pattern then return nil end
			else
				local should_match = name:sub(1, 4) ~= "not-"
				if not should_match then name = name:sub(5) end
				predicates = predicates + 1
				local actual = processed.predicates[predicates]
				if not sequence(actual) or #actual ~= 3 or actual[1] ~= name
					or actual[2] ~= should_match or actual[3] ~= pattern
					or not track(snapshot, actual) then return nil end
			end
			if not pure[name] then return nil end
			if not names[name] then
				local handlers = name:sub(-1) == "!" and checked.directives or checked.predicates
				local handler = handlers[name]
				if not safe_handler(checked, handler) then return nil end
				snapshot.handlers[#snapshot.handlers + 1] = { registry = handlers, name = name, value = handler }
				names[name] = true
			end
			for _, argument in ipairs(pattern) do
				local kind = type(argument)
				if kind ~= "number" and kind ~= "string" then return nil end
			end
		end
		if #processed.predicates ~= predicates or #processed.directives ~= directives then return nil end
	end
	for index, name in pairs(snapshot.captures) do
		if type(index) ~= "number" or type(name) ~= "string" then return nil end
	end
	snapshot.seen = nil
	next_signature = next_signature + 1
	-- Native query userdata stringify as the same literal '<query>'. Weak IDs
	-- and the direct reference check above distinguish real replacements.
	snapshot.token = "query:" .. identity(query) .. ":" .. identity(query.query) .. ":" .. next_signature
	return snapshot
end

local function plan(query)
	local api = vim.treesitter and vim.treesitter.query
	if not api or type(query) ~= "table" then return nil end
	local cached = plans[query]
	if cached and cached.match == query._match_predicates and cached.apply == query._apply_directives
		and cached.iter == query.iter_captures and cached.add_predicate == api.add_predicate
		and cached.add_directive == api.add_directive then return cached end
	local match, apply, iter = info(query._match_predicates), info(query._apply_directives), info(query.iter_captures)
	local add_predicate, add_directive = info(api.add_predicate), info(api.add_directive)
	if not match or not apply or not iter or not add_predicate or not add_directive
		or not runtime_source(match.source) or apply.source ~= match.source or iter.source ~= match.source
		or add_predicate.source ~= match.source or add_directive.source ~= match.source then return nil end
	local predicates = registry(query._match_predicates, "predicate_handlers")
	local directives = registry(query._apply_directives, "directive_handlers")
	if not predicates or not directives then return nil end
	cached = { predicates = predicates, directives = directives, source = match.source,
		match = query._match_predicates, apply = query._apply_directives, iter = query.iter_captures,
		add_predicate = api.add_predicate, add_directive = api.add_directive,
		-- Legacy all=false adapters are defined INSIDE these registration
		-- functions and share the runtime source despite wrapping user code.
		registration = { add_predicate, add_directive } }
	plans[query] = cached
	return cached
end

local function signature(query)
	local checked = plan(query)
	if not checked then return nil end
	local snapshot = checked.snapshot
	if snapshot and unchanged(snapshot, query) then return snapshot.token end
	snapshot = inspect(query, checked)
	if not snapshot then return nil end
	checked.snapshot = snapshot
	return snapshot.token
end

function M.signature(query)
	-- Introspection is optional. Malformed extension metadata or an unfamiliar
	-- runtime must never turn a best-effort highlight into a rendering error.
	local ok, value = pcall(signature, query)
	return ok and value or nil
end

-- Only for one synchronous Markdown traversal after a full signature check.
-- Its owner discards the context at callback/parser boundaries and between
-- renders. This is deliberately not a replacement for ordinary full checks.
local function quick_signature(query, token)
	local checked, api = plans[query], vim.treesitter and vim.treesitter.query
	local snapshot = checked and checked.snapshot
	if not snapshot or snapshot.token ~= token or not api
		or checked.match ~= query._match_predicates or checked.apply ~= query._apply_directives
		or checked.iter ~= query.iter_captures or checked.add_predicate ~= api.add_predicate
		or checked.add_directive ~= api.add_directive or snapshot.native ~= query.query
		or snapshot.info ~= query.info or snapshot.patterns ~= query.info.patterns
		or snapshot.processed ~= query._processed_patterns or snapshot.captures ~= query.captures then return nil end
	for _, handler in ipairs(snapshot.handlers) do
		if handler.registry[handler.name] ~= handler.value then return nil end
	end
	return token
end

function M.quick_signature(query, token)
	local ok, value = pcall(quick_signature, query, token)
	return ok and value or nil
end

return M
