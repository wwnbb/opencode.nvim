local uv = vim.uv or vim.loop
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local jsonc = require("opencode.util.jsonc")
local config = vim.fn.fnamemodify(assert(arg[1], "Configuration directory is required"), ":p"):gsub("/+$", "")
local source = root .. "/opencode_nvim/dist/opencode-nvim"
local target = config .. "/plugins/opencode-nvim"

local function exists(path) return uv.fs_lstat(path) ~= nil end
local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return text
end

local function write(path, text)
	local fd = assert(uv.fs_open(path, "wx", 420))
	local written, err = uv.fs_write(fd, text, 0)
	local closed, close_err = uv.fs_close(fd)
	assert(written == #text, err or "Incomplete write: " .. path)
	assert(closed, close_err)
end

local function copy(from, to)
	local stat = assert(uv.fs_lstat(from))
	if stat.type == "file" then
		assert(uv.fs_copyfile(from, to))
	elseif stat.type == "directory" then
		if not exists(to) then assert(uv.fs_mkdir(to, 493)) end
		local scan = assert(uv.fs_scandir(from))
		while true do
			local name = uv.fs_scandir_next(scan)
			if not name then break end
			assert(name ~= "node_modules" and name ~= "package-lock.json", "Unexpected dependency files in prepared server plugin")
			copy(from .. "/" .. name, to .. "/" .. name)
		end
	else
		error("Unsupported prepared plugin file: " .. from)
	end
end

local function unsupported(detail)
	error("Unsupported OpenCode configuration (" .. detail .. "). Remove or update the reported entry before installing; existing files were not changed.")
end

local function install()
	for _, path in ipairs({
		"tool/lib/context.ts", "tool/lib/diff.ts", "tool/lib/file_state.ts", "tool/lib/text.ts",
		"tool/neovim_apply_patch.ts", "tool/neovim_apply_patch.txt", "tool/neovim_edit.ts", "tool/neovim_edit.txt",
		"tool/rg.ts", "tool/rg.txt", "commands/load_skills.md",
	}) do
		if exists(config .. "/" .. path) then unsupported(path) end
	end
	if exists(target) then
		local ok, pkg = pcall(function() return vim.json.decode(read(target .. "/package.json")) end)
		assert(ok and type(pkg) == "table" and pkg.name == "opencode-nvim-server", "Refusing to replace an unowned directory: " .. target)
		for _, name in ipairs({ "neovim_apply_patch.ts", "neovim_apply_patch.txt" }) do
			if exists(target .. "/tools/" .. name) then unsupported("plugins/opencode-nvim/tools/" .. name) end
		end
	end

	local json_file, jsonc_file = config .. "/opencode.json", config .. "/opencode.jsonc"
	assert(not (exists(json_file) and exists(jsonc_file)), "Both opencode.json and opencode.jsonc exist; consolidate them before installing the server plugin")
	local config_file = exists(json_file) and json_file or jsonc_file
	local previous = exists(config_file) and read(config_file) or nil
	local text = previous or read(root .. "/opencode_nvim/opencode.jsonc")
	local ok, value = pcall(jsonc.decode, text)
	assert(ok and type(value) == "table" and not vim.islist(value), "Invalid JSONC: " .. config_file .. "; existing configuration was not changed")
	for _, name in ipairs({ "plugins", "permissions" }) do
		assert(value[name] == nil or (type(value[name]) == "table" and vim.islist(value[name])), name .. " must be an array")
	end
	if value.permission ~= nil then unsupported("permission") end
	if value.theme == "opencode" then unsupported("theme: opencode") end
	if value["$schema"] == "https://opencode.ai/config.json" then unsupported("old $schema") end
	for _, entry in ipairs(value.plugins or {}) do
		if entry == target .. "/index.ts" or entry == "./plugins/opencode-nvim/index.ts" then unsupported("plugin entry ending in index.ts") end
	end
	local function check_rules(rules, scope)
		if type(rules) ~= "table" or not vim.islist(rules) then return end
		for _, rule in ipairs(rules) do
			if type(rule) == "table" and rule.action == "neovim_apply_patch" then unsupported(scope .. ": neovim_apply_patch") end
		end
	end
	check_rules(value.permissions, "permissions")
	if type(value.agents) == "table" then
		for name, agent in pairs(value.agents) do
			if type(agent) == "table" then
				if agent.permission ~= nil then unsupported("agents." .. name .. ".permission") end
				check_rules(agent.permissions, "agents." .. name .. ".permissions")
			end
		end
	end

	local pkg = vim.json.decode(read(source .. "/package.json"))
	assert(pkg.name == "opencode-nvim-server" and pkg.exports == "./index.js" and not pkg.dependencies,
		"Prepared server plugin is missing or invalid; restore the distributed opencode_nvim/dist directory")
	assert(uv.fs_stat(source .. "/index.js"), "Prepared server plugin index.js is missing")
	-- Validate everything before creating a profile; OpenCode discovers plugins here automatically.
	vim.fn.mkdir(config, "p")
	local stage = assert(uv.fs_mkdtemp(config .. "/.opencode-nvim-install-XXXXXX"))
	local backup = config .. "/opencode-nvim-backups/" .. os.date("!%Y-%m-%dT%H-%M-%S") .. "-" .. vim.fn.fnamemodify(stage, ":t")
	local temporary = stage .. ".jsonc"
	local replaced, backed_up = false, false
	local installed, err = pcall(function()
		copy(source, stage)
		write(stage .. "/.opencode-nvim-install.json", vim.json.encode({ version = pkg.version, configFile = config_file, backup = backup }) .. "\n")
		if previous == nil then write(temporary, text) end
		vim.fn.mkdir(backup, "p")
		vim.fn.mkdir(config .. "/plugins", "p")
		if exists(target) then
			assert(uv.fs_rename(target, backup .. "/opencode-nvim"))
			backed_up = true
		end
		assert(uv.fs_rename(stage, target))
		replaced = true
		-- Exclusive creation preserves a config written during installation.
		if previous == nil then assert(uv.fs_copyfile(temporary, config_file, { excl = true })) end
	end)
	vim.fn.delete(stage, "rf")
	vim.fn.delete(temporary)
	if not installed then
		if replaced then vim.fn.delete(target, "rf") end
		if backed_up then
			local restored, restore_err = uv.fs_rename(backup .. "/opencode-nvim", target)
			if not restored then err = tostring(err) .. "\nCould not restore prior plugin: " .. tostring(restore_err) .. "; preserved in " .. backup end
		end
		error(err)
	end
	print("opencode.nvim: v2 server plugin installed in " .. target .. "\nPreserved previous files in " .. backup)
end

local ok, err = pcall(install)
if not ok then
	vim.api.nvim_err_writeln(tostring(err))
	vim.cmd("cquit 1")
end
