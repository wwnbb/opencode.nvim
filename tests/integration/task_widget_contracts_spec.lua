local chat_surface = require("tests.helpers.chat_surface")
local chat_state_mod = require("opencode.ui.chat.state")
local chat_state = chat_state_mod.state
local chat_tasks = require("opencode.ui.chat.tasks")
local chat_highlights = require("opencode.ui.chat.highlights")
local actions_mod = require("opencode.actions")

describe("task widget contracts", function()
	local bufnr, winid, surface
	before_each(function()
		surface = chat_surface.setup()
		bufnr, winid = surface.bufnr, surface.winid
	end)
	after_each(function()
		chat_surface.restore(surface)
	end)
	local original_load, original_rerender
	before_each(function() original_load, original_rerender = actions_mod.load_session_messages, chat_tasks.rerender_task end)
	after_each(function() actions_mod.load_session_messages, chat_tasks.rerender_task = original_load, original_rerender end)
	local function child_task(status)
		return { id = "child-task", type = "tool", tool = "task", state = {
			status = status or "running", metadata = { sessionID = "child" },
		} }
	end

	for _, failed in ipairs({ false }) do
		it("ignores a queued child-load success after the chat resets", function()
			local replies, renders = {}, 0
			actions_mod.load_session_messages = function(_, _, callback) replies[#replies + 1] = callback end
			chat_tasks.rerender_task = function() renders = renders + 1 end
			local part = child_task()
			chat_state.tasks[part.id] = { tool_part = part }
			chat_tasks.ensure_task_child_loaded(part)
			replies[1](failed and { message = "old failure" } or nil, {})
			require("opencode.ui.chat.render_state").reset_chat_surface({ reset_expansions = true })
			chat_state.tasks[part.id] = { tool_part = part }
			chat_tasks.ensure_task_child_loaded(part)
			assert.equals(2, #replies)
			vim.wait(20, function() return false end, 10)
			assert.equals("child", chat_state.task_child_loading[part.id])
			assert.is_nil(chat_state.task_child_cache[part.id])
			assert.equals(0, renders)
			replies[2](nil, {})
			assert.is_true(vim.wait(100, function() return chat_state.task_child_cache[part.id] == "child" end, 10))
			assert.is_nil(chat_state.task_child_loading[part.id])
			assert.equals(1, renders)
		end)
	end

	it("shares a pending child load with expansion and retries its failure", function()
		local replies = {}
		actions_mod.load_session_messages = function(session_id, opts, callback)
			assert.equals("child", session_id)
			assert.equals(100, opts.limit)
			replies[#replies + 1] = callback
		end
		chat_tasks.rerender_task = function() end
		local part = child_task()
		chat_state.tasks[part.id] = { tool_part = part }
		chat_tasks.ensure_task_child_loaded(part)
		chat_tasks.handle_task_toggle(part.id)
		assert.equals(1, #replies)
		replies[1]({ message = "retry me" })
		assert.is_true(vim.wait(100, function() return chat_state.task_child_loading[part.id] == nil end, 10))
		assert.is_nil(chat_state.expanded_tasks[part.id])
		chat_tasks.handle_task_toggle(part.id)
		assert.equals(2, #replies)
		replies[2](nil, {})
		assert.equals("child", chat_state.task_child_loading[part.id])
		assert.is_true(vim.wait(100, function() return chat_state.task_child_cache[part.id] == "child" end, 10))
		assert.is_nil(chat_state.task_child_loading[part.id])
		assert.is_true(chat_state.expanded_tasks[part.id])
	end)

	it("loads a completed task on explicit expansion", function()
		local callback
		actions_mod.load_session_messages = function(_, _, done) callback = done end
		chat_tasks.rerender_task = function() end
		local part = child_task("completed")
		chat_state.tasks[part.id] = { tool_part = part }
		chat_tasks.handle_task_toggle(part.id)
		assert.is_function(callback)
		callback(nil, {})
		assert.is_true(vim.wait(100, function() return chat_state.task_child_cache[part.id] == "child" end, 10))
		assert.is_true(chat_state.expanded_tasks[part.id])
	end)

	for _, failed in ipairs({ true }) do
		it("ignores a replaced child's late failure", function()
			local replies, loaded, renders = {}, {}, 0
			actions_mod.load_session_messages = function(id, _, callback)
				loaded[#loaded + 1], replies[#replies + 1] = id, callback
			end
			chat_tasks.rerender_task = function() renders = renders + 1 end
			local part = child_task()
			chat_state.tasks[part.id] = { tool_part = part }
			chat_tasks.ensure_task_child_loaded(part)
			part.state.metadata.sessionID = "replacement"
			chat_state.expanded_tasks[part.id] = true
			chat_tasks.ensure_task_child_loaded(part)
			assert.same({ "child", "replacement" }, loaded)
			require("tests.helpers.schedule").with(function(flush)
				replies[1](failed and { message = "old error" } or nil)
				flush()
				assert.equals("replacement", chat_state.task_child_loading[part.id])
				assert.is_nil(chat_state.task_child_cache[part.id])
				assert.is_true(chat_state.expanded_tasks[part.id])
				assert.equals(0, renders)
				replies[2](nil)
				flush()
				assert.equals("replacement", chat_state.task_child_cache[part.id])
				assert.equals(1, renders)
			end)
			part.state.metadata.sessionID = "third"
			chat_tasks.ensure_task_child_loaded(part)
			assert.equals("third", loaded[3])
		end)
	end

	it("animates through overlay extmarks without mutating text or highlights", function()
		local task_part = {
			id = "task_anim_overlay",
			tool = "task",
			state = {
				status = "running",
				input = {
					subagent_type = "webfetcher_slave",
					description = "Research vim.diff docs",
				},
				metadata = {
					summary = {
						{
							id = "1",
							tool = "webfetch",
							state = {
								status = "running",
								title = "Webfetch https://raw.githubusercontent.com/neovim/neovim/...",
								input = {},
							},
						},
					},
				},
			},
		}

		chat_state.bufnr = bufnr
		chat_state.winid = winid
		chat_state.visible = true
		chat_state.tasks = {}
		chat_state.tools = {}
		chat_state.task_anim_frame = 1

		local rendered_task = chat_tasks.render_task_tool(task_part, false)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, rendered_task.lines)
		chat_highlights.apply_extmark_highlights(bufnr, chat_state_mod.chat_hl_ns, rendered_task.highlights, 0)
		chat_state.tasks[task_part.id] = {
			start_line = 0,
			end_line = #rendered_task.lines - 1,
			tool_part = task_part,
			highlights = rendered_task.highlights,
		}

		local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local before_highlights =
			vim.inspect(vim.api.nvim_buf_get_extmarks(bufnr, chat_state_mod.chat_hl_ns, 0, -1, { details = true }))
		chat_state.task_anim_frame = 2
		assert(chat_tasks.update_animation_frames_in_place() == true, "task animation overlay did not update")
		assert(
			vim.deep_equal(before_lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
			"task animation should not mutate buffer text"
		)
		assert(
			before_highlights
				== vim.inspect(vim.api.nvim_buf_get_extmarks(bufnr, chat_state_mod.chat_hl_ns, 0, -1, { details = true })),
			"task animation should not move task highlight extmarks"
		)
		assert(
			#vim.api.nvim_buf_get_extmarks(bufnr, chat_state_mod.chat_anim_ns, 0, -1, { details = true }) > 0,
			"task animation overlay extmark was not applied"
		)
		chat_tasks.clear_animation_extmarks(bufnr)
	end)
end)
