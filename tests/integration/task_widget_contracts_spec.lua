local chat_surface = require("tests.helpers.chat_surface")
local chat_state_mod = require("opencode.ui.chat.state")
local chat_state = chat_state_mod.state
local chat_tasks = require("opencode.ui.chat.tasks")
local sync = require("opencode.sync")
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
	local original_load
	before_each(function() original_load = actions_mod.load_session_messages end)
	after_each(function() actions_mod.load_session_messages = original_load end)

	it("keeps parallel children distinct and never guesses missing metadata", function()
		local tasks = {}
		local descriptions = {
			"Map repo architecture",
			"Explore UI widgets",
			"Trace client events",
			"Inspect state model",
			"Review commands API",
		}

		chat_state.task_child_cache = {}
		chat_state.task_child_loading = {}
		chat_state.tasks = {}
		chat_state.bufnr = nil
		sync.clear_all()
		sync.handle_message_updated({
			id = "parallel_parent_msg",
			sessionID = "parallel_parent",
			role = "assistant",
			time = { created = 1 },
		})

		for i, desc in ipairs(descriptions) do
			local task_part = {
				id = "parallel_task_" .. i,
				messageID = "parallel_parent_msg",
				sessionID = "parallel_parent",
				type = "tool",
				tool = "task",
				state = {
					status = "running",
					input = {
						subagent_type = "grep_slave",
						description = desc,
					},
					metadata = i ~= 3 and { sessionID = "parallel_child_" .. i } or {},
				},
			}
			tasks[i] = task_part
			sync.handle_part_updated(task_part)
			chat_state.tasks[task_part.id] = {
				start_line = i,
				end_line = i,
				tool_part = task_part,
			}

			sync.handle_message_updated({
				id = "parallel_child_msg_" .. i,
				sessionID = "parallel_child_" .. i,
				role = "assistant",
				time = { created = 2000 + i * 1000 },
			})
			sync.handle_part_updated({
				id = "parallel_child_tool_" .. i,
				messageID = "parallel_child_msg_" .. i,
				sessionID = "parallel_child_" .. i,
				type = "tool",
				tool = "read",
				state = {
					status = "running",
					input = { filePath = "/tmp/parallel_" .. i .. ".lua" },
				},
			})
		end

		local before_metadata
		chat_tasks.resolve_task_child_session_id(tasks[3], function(err, id)
			assert(not err)
			before_metadata = id or false
		end)
		assert(before_metadata == false, "task should not guess a child from matching title or timing")
		tasks[3].state.metadata = { sessionId = "parallel_child_3" }
		sync.handle_part_updated(tasks[3])

		local seen_children = {}
		for i, task_part in ipairs(tasks) do
			local child_id
			chat_tasks.resolve_task_child_session_id(task_part, function(err, id)
				assert(not err)
				child_id = id
			end)
			assert(child_id == "parallel_child_" .. i, "parallel task mapped to the wrong child: " .. tostring(child_id))
			assert(not seen_children[child_id], "parallel child was reused across tasks: " .. tostring(child_id))
			seen_children[child_id] = true

			local rendered = chat_tasks.render_task_tool(task_part, false)
			assert(
				rendered.lines[2] and rendered.lines[2]:find("Read /tmp/parallel_" .. i .. ".lua", 1, true),
				"parallel task did not render its own child tool summary"
			)
		end
	end)

	it("loads a metadata child once and clears its loading marker asynchronously", function()
		local calls = 0

		chat_state.task_child_cache = {}
		chat_state.task_child_loading = {}
		chat_state.tasks = {}
		actions_mod.load_session_messages = function(session_id, opts, callback)
			calls = calls + 1
			assert(session_id == "child_autoload", "autoload should use metadata child session id")
			assert(opts and opts.limit == 100, "autoload should request the default message limit")
			callback(nil, {})
		end

		chat_tasks.ensure_task_child_loaded({
			id = "task_autoload",
			tool = "task",
			state = {
				status = "running",
				metadata = { sessionId = "child_autoload" },
			},
		})
		assert(calls == 1, "autoload should issue one child-session load")
		assert(chat_state.task_child_loading.task_autoload == true, "autoload should mark the task as loading")
		assert(vim.wait(200, function()
			return chat_state.task_child_loading.task_autoload == nil
		end, 10), "autoload cleanup was not scheduled")
		assert(chat_state.task_child_cache.task_autoload == true, "autoload success should cache the child session")
	end)

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

		local tool_panel = require("opencode.ui.chat.tool_panel")
		chat_state.task_anim_frame = 5
		assert(chat_tasks.get_task_anim_frame() == "⠼", "task animation is missing middle braille frames")
		chat_state.task_anim_frame = 10
		assert(chat_tasks.get_task_anim_frame() == "⠏", "task animation is missing final braille frame")
		chat_state.task_anim_frame = 6
		assert(tool_panel.anim_frame({ "|", "/", "-", "\\" }) == "/", "regular tool animation should wrap shared frame index")
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
