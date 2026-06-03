-- opencode.nvim - Prompt palette commands

local M = {}

local actions = require("opencode.actions")
local client = require("opencode.client")
local state = require("opencode.state")
function M.register(palette)
	palette.register({
		id = "action.skills",
		title = "Run Skills",
		description = "Select and execute available skills",
		category = "prompt",
		suggested = true,
		action = function()
			local session = state.get_session()
			if not session.id then
				vim.notify("No active session", vim.log.levels.WARN)
				return
			end

			if not state.is_connected() then
				vim.notify("Not connected to OpenCode server", vim.log.levels.WARN)
				return
			end

			local sync = require("opencode.sync")
			local float = require("opencode.ui.float")

			local function resolve_command(names)
				local candidates = {}
				for _, name in ipairs(names) do
					candidates[name] = true
				end

				local commands = sync.get_commands() or {}
				for key, cmd in pairs(commands) do
					if candidates[key] then
						return key
					end
					if type(cmd) == "table" and candidates[cmd.name] then
						return cmd.name
					end
				end
				return nil
			end

			local function add_skill_name(names, seen, value)
				local name = vim.trim(tostring(value or ""))
				name = name:gsub("^%[", ""):gsub("%]$", "")
				name = name:gsub("^['\"]", ""):gsub("['\"]$", "")
				if name == "" or seen[name] then
					return
				end

				seen[name] = true
				table.insert(names, name)
			end

			local function add_skill_names(names, seen, value)
				if type(value) ~= "string" then
					add_skill_name(names, seen, value)
					return
				end

				local text = vim.trim(value)
				if text == "" then
					return
				end

				local pattern = text:find(",", 1, true) and "[^,]+" or "%S+"
				for part in text:gmatch(pattern) do
					add_skill_name(names, seen, part)
				end
			end

			local function normalize_skill_names(value)
				local names = {}
				local seen = {}
				if type(value) == "table" then
					for _, item in ipairs(value) do
						if type(item) == "table" then
							add_skill_names(names, seen, item.value or item.label or item.name)
						else
							add_skill_names(names, seen, item)
						end
					end
				else
					add_skill_names(names, seen, value)
				end
				return names
			end

	local function request_skills_via_tool(names)
		local joined = table.concat(names, ", ")
		actions.send("load_skill [" .. joined .. "]")
		vim.notify("Requested skills via tool: " .. joined, vim.log.levels.INFO)
	end

			local function load_skills(selected)
				local names = normalize_skill_names(selected)
				if #names == 0 then
					vim.notify("No skills selected", vim.log.levels.WARN)
					return
				end

				local command_name = resolve_command({ "load_skills", "loadskills" })
				if not command_name then
					request_skills_via_tool(names)
					return
				end

				local joined = table.concat(names, ", ")
				client.execute_command(session.id, command_name, joined, {}, function(err)
					vim.schedule(function()
						if err then
							local err_text = tostring(err.message or err.error or err)
							local lower = err_text:lower()
							if lower:find("command") and (lower:find("not found") or lower:find("unknown")) then
								request_skills_via_tool(names)
								return
							end
							vim.notify("Failed to run load_skills: " .. err_text, vim.log.levels.ERROR)
							return
						end
						vim.notify("Loading skills: " .. joined, vim.log.levels.INFO)
					end)
				end)
			end

			local function show_skill_picker(skills)
				local normalized = {}
				if type(skills) == "table" then
					for _, skill in pairs(skills) do
						if type(skill) == "table" and skill.name then
							table.insert(normalized, skill)
						end
					end
				end

				if #normalized == 0 then
					vim.notify("No skills available", vim.log.levels.INFO)
					return
				end

				local items = {}
				for _, skill in ipairs(normalized) do
					table.insert(items, {
						label = skill.name,
						value = skill.name,
						description = skill.description or skill.location or "",
						skill = skill,
					})
				end

				if #items == 0 then
					vim.notify("No skills available", vim.log.levels.INFO)
					return
				end

				float.create_searchable_menu(items, function(selected_items)
					if type(selected_items) ~= "table" or #selected_items == 0 then
						vim.notify("Invalid skill selection", vim.log.levels.WARN)
						return
					end

					load_skills(selected_items)
				end, { title = " Select Skills ", width = 60, multi_select = true, confirm_label = "load" })
			end

			local function show_local_skill_picker()
				local skills = sync.get_skills()
				if type(skills) == "table" and #skills > 0 then
					show_skill_picker(skills)
					return
				end

				client.list_skills(function(err, fetched_skills)
					vim.schedule(function()
						if err then
							vim.notify("Failed to load skills: " .. tostring(err.message or err), vim.log.levels.ERROR)
							return
						end

						local list = type(fetched_skills) == "table" and fetched_skills or {}
						sync.handle_skills(list)
						show_skill_picker(list)
					end)
				end)
			end

			show_local_skill_picker()
		end,
	})
end

return M
