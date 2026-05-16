-- Static architecture guardrails for opencode.nvim.
-- Run with: nvim --headless --clean --cmd "set rtp+=." -l scripts/check-architecture.lua

local function read_file(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*all")
	file:close()
	return content
end

local function scandir(dir, out)
	out = out or {}
	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return out
	end
	while true do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		local path = dir .. "/" .. name
		if kind == "directory" then
			scandir(path, out)
		elseif kind == "file" and path:match("%.lua$") then
			table.insert(out, path)
		end
	end
	return out
end

local function module_name(path)
	local name = path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/", ".")
	return name:gsub("%.init$", "")
end

local files = scandir("lua/opencode")
table.insert(files, "plugin/opencode.lua")

local modules = {}
local file_by_module = {}
for _, path in ipairs(files) do
	if path:match("^lua/") then
		local mod = module_name(path)
		modules[mod] = true
		file_by_module[mod] = path
	end
end

local missing = {}
local layering_violations = {}
local adjacency = {}
for mod, _ in pairs(modules) do
	adjacency[mod] = {}
end

local function add_require(source, req, path, line_no)
	if not req:match("^opencode") then
		return
	end
	if not modules[req] then
		table.insert(missing, string.format("%s:%d missing internal require %s", path, line_no, req))
		return
	end
	if source and source ~= req then
		adjacency[source][req] = true
	end
end

for _, path in ipairs(files) do
	local source = path:match("^lua/") and module_name(path) or nil
	local content = read_file(path)
	local line_no = 0
	for line in (content .. "\n"):gmatch("(.-)\n") do
		line_no = line_no + 1
		for req in line:gmatch("require%s*%(?%s*[\"']([^\"']+)[\"']") do
			add_require(source, req, path, line_no)
		end
		for req in line:gmatch("pcall%s*%(%s*require%s*,%s*[\"']([^\"']+)[\"']") do
			add_require(source, req, path, line_no)
		end
	end
end

local store_modules = {
	["lua/opencode/state.lua"] = true,
	["lua/opencode/sync.lua"] = true,
	["lua/opencode/local.lua"] = true,
	["lua/opencode/permission/state.lua"] = true,
	["lua/opencode/question/state.lua"] = true,
	["lua/opencode/edit/state.lua"] = true,
}

for _, path in ipairs(files) do
	local content = read_file(path)
	if store_modules[path] then
		for line_no, line in ipairs(vim.split(content, "\n", { plain = true })) do
			local requires_events = line:match("require%s*%(?%s*[\"']opencode%.events[\"']")
			local requires_ui = line:match("require%s*%(?%s*[\"']opencode%.ui")
			if requires_events or requires_ui then
				table.insert(layering_violations, string.format("%s:%d store must not require events or UI", path, line_no))
			end
		end
	end

	if path ~= "lua/opencode/ui/chat/render_coordinator.lua" then
		for line_no, line in ipairs(vim.split(content, "\n", { plain = true })) do
			if line:match("emit%s*%(%s*[\"']chat_render[\"']") then
				table.insert(layering_violations, string.format("%s:%d chat_render must go through render_coordinator", path, line_no))
			end
		end
	end
end

local roots = {
	["opencode"] = true,
	["opencode.commands"] = true,
	["opencode.ui.log_viewer"] = true,
}
local reachable = {}
local stack = {}
for root, _ in pairs(roots) do
	table.insert(stack, root)
end
while #stack > 0 do
	local current = table.remove(stack)
	if modules[current] and not reachable[current] then
		reachable[current] = true
		for dep, _ in pairs(adjacency[current]) do
			table.insert(stack, dep)
		end
	end
end

local unreachable = {}
for mod, _ in pairs(modules) do
	if not reachable[mod] then
		table.insert(unreachable, string.format("%s (%s)", mod, file_by_module[mod]))
	end
end
table.sort(missing)
table.sort(layering_violations)
table.sort(unreachable)

local failed = false
if #missing > 0 then
	failed = true
	print("Missing internal requires:")
	for _, item in ipairs(missing) do
		print("  " .. item)
	end
end

if #layering_violations > 0 then
	failed = true
	print("Layering violations:")
	for _, item in ipairs(layering_violations) do
		print("  " .. item)
	end
end

if #unreachable > 0 then
	failed = true
	print("Unreachable Lua modules:")
	for _, item in ipairs(unreachable) do
		print("  " .. item)
	end
end

if failed then
	os.exit(1)
end

print("Architecture checks passed")
