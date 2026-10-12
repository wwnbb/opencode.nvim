-- Static architecture guardrails for opencode.nvim.
-- Run with: ./tests/run.sh checks

describe("opencode architecture guardrails", function()
	it("enforces module dependencies and layer boundaries", function()
local function read_file(path)
	local file = assert(io.open(path, "r"))
	local content = file:read("*all")
	file:close()
	return content
end

local function module_name(path)
	local name = path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/", ".")
	return name:gsub("%.init$", "")
end

local files = vim.fn.glob("lua/opencode/**/*.lua", false, true)
table.insert(files, "plugin/opencode.lua")
local lines_by_path = {}

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
	local lines = vim.split(read_file(path), "\n", { plain = true })
	lines_by_path[path] = lines
	local command_module_list = false
	for line_no, line in ipairs(lines) do
		-- register_defaults requires these literal names through one shared loop.
		if source == "opencode.ui.palette" then
			if line:match("^local default_command_modules%s*=%s*{") then
				command_module_list = true
			elseif command_module_list and line:match("^}") then
				command_module_list = false
			elseif command_module_list then
				for req in line:gmatch("[\"']([^\"']+)[\"']") do add_require(source, req, path, line_no) end
			end
		elseif source == "opencode.events" then
			-- setup loads module fields through pcall(require, spec.module).
			for req in line:gmatch("module%s*=%s*[\"']([^\"']+)[\"']") do add_require(source, req, path, line_no) end
		end
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

local ui_forbidden_requires = {
	["opencode.client"] = true,
	["opencode.lifecycle"] = true,
	["opencode.session"] = true,
}

for _, path in ipairs(files) do
	for line_no, line in ipairs(lines_by_path[path]) do
		if store_modules[path] then
			local requires_events = line:match("require%s*%(?%s*[\"']opencode%.events[\"']")
			local requires_ui = line:match("require%s*%(?%s*[\"']opencode%.ui")
			if requires_events or requires_ui then
				table.insert(layering_violations, string.format("%s:%d store must not require events or UI", path, line_no))
			end
		end
		if path ~= "lua/opencode/ui/chat/render_coordinator.lua" then
			if line:match("emit%s*%(%s*[\"']chat_render[\"']") then
				table.insert(layering_violations, string.format("%s:%d chat_render must go through render_coordinator", path, line_no))
			end
		end
		if path:match("^lua/opencode/ui/") then
			for req in line:gmatch("require%s*%(?%s*[\"']([^\"']+)[\"']") do
				if ui_forbidden_requires[req] then
					table.insert(
						layering_violations,
						string.format("%s:%d UI modules must call opencode.actions instead of requiring %s", path, line_no, req)
					)
				end
			end
			for req in line:gmatch("pcall%s*%(%s*require%s*,%s*[\"']([^\"']+)[\"']") do
				if ui_forbidden_requires[req] then
					table.insert(
						layering_violations,
						string.format("%s:%d UI modules must call opencode.actions instead of requiring %s", path, line_no, req)
					)
				end
			end
			if line:match("%f[%w_]sync%.handle_") then
				table.insert(
					layering_violations,
					string.format("%s:%d UI modules must not ingest sync data directly", path, line_no)
				)
			end
			if line:match("%f[%w_]state%.set_[%w_]+%s*%(") then
				table.insert(
					layering_violations,
					string.format("%s:%d UI modules must not mutate app state directly", path, line_no)
				)
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
	error("Architecture checks failed", 0)
end

print("Architecture checks passed")
	end)
end)
