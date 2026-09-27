-- Shared owner for the floating windows used by palette commands and dialogs.
-- A popup has a content window and may also have a backing frame and an input.
local M = {}

local NuiPopup = require("nui.popup")
local float_context = require("opencode.ui.float_context")

local Popup = {}
Popup.__index = Popup

local next_id = 0

local function screen_size()
	return math.max(1, vim.o.columns), math.max(1, vim.o.lines - vim.o.cmdheight)
end

local function border_insets(border)
	if type(border) == "table" then border = border.style end
	if border == "none" or border == nil then return 0, 0 end
	return 2, 2
end

local function container_size(relative)
	local width, height = screen_size()
	local winid
	if relative == "win" then winid = vim.api.nvim_get_current_win() end
	if type(relative) == "table" and relative.type == "win" then winid = relative.winid end
	if winid and vim.api.nvim_win_is_valid(winid) then
		width = math.min(width, vim.api.nvim_win_get_width(winid))
		height = math.min(height, vim.api.nvim_win_get_height(winid))
	end
	return width, height
end

local function dimension(value, fallback)
	if type(value) == "number" then return math.floor(value) end
	if type(value) == "string" then
		local number = tonumber(value:match("^([%d.]+)%%$"))
		if number then return math.floor(fallback * number / 100) end
		return tonumber(value) or fallback
	end
	return fallback
end

local function geometry(spec, relative, component)
	local container_width, container_height = container_size(relative)
	local border_width, border_height = border_insets(spec.border)
	local border_left, border_top = 0, 0
	-- Nui renders a border with text or padding in its own window. Its
	-- position is offset from the content window by half the border size.
	local border = component and component.border
	if border and border._ and border._.type == "complex" then
		local delta = border._.size_delta
		border_width, border_height = delta.width, delta.height
		border_left = math.floor(delta.width / 2 + 0.5)
		border_top = math.floor(delta.height / 2 + 0.5)
	end
	local requested_size = spec.size or {}
	local max_width = math.max(1, container_width - border_width)
	local max_height = math.max(1, container_height - border_height)
	local width = math.max(1, math.min(dimension(requested_size.width, max_width), max_width))
	local height = math.max(1, math.min(dimension(requested_size.height, max_height), max_height))
	local requested_position = spec.position or {}
	local row = dimension(requested_position.row,
		math.floor((container_height - height - border_height) / 2) + border_top)
	local col = dimension(requested_position.col,
		math.floor((container_width - width - border_width) / 2) + border_left)
	row = math.max(border_top, math.min(row, container_height - height - border_height + border_top))
	col = math.max(border_left, math.min(col, container_width - width - border_width + border_left))
	return { relative = relative, position = { row = row, col = col }, size = { width = width, height = height } }
end

local function component_options(spec, relative)
	local options = vim.deepcopy(spec)
	options.kind = nil
	options.prompt = nil
	options.default_value = nil
	options.disable_cursor_position_patch = nil
	options.on_change = nil
	options.on_submit = nil
	options.on_close = nil
	local layout = geometry(spec, relative)
	options.relative = layout.relative
	options.position = layout.position
	options.size = layout.size
	return options
end

local function make_component(spec, relative, input)
	local options = component_options(spec, relative)
	-- Nui opens windows with noautocmd=true. Set focus after all layers are
	-- mounted so the previous window receives its normal BufLeave handlers.
	options.enter = false
	if input and spec.kind ~= "popup" then
		-- A prompt buffer provides the same editable input surface as NuiInput.
		-- NuiInput schedules a BufWinEnter focus callback which can run after an
		-- immediately dismissed dialog and try to focus a deleted window.
		options.buf_options = options.buf_options or {}
		options.buf_options.buftype = "prompt"
	end
	return NuiPopup(options)
end

local function visible(component)
	return component and component.winid and vim.api.nvim_win_is_valid(component.winid)
end

local function normalise_mark(mark)
	local row = mark.row or mark.line or mark[1] or 0
	local col = mark.col or mark.col_start or mark[2] or 0
	local options = vim.deepcopy(mark.opts or {})
	for _, key in ipairs({ "end_col", "end_row", "hl_group", "line_hl_group", "priority", "virt_text",
		"virt_text_pos", "hl_mode", "right_gravity", "end_right_gravity", "sign_text", "sign_hl_group" }) do
		if mark[key] ~= nil and options[key] == nil then options[key] = mark[key] end
	end
	options.end_col = options.end_col or mark.col_end or mark[3]
	options.hl_group = options.hl_group or mark.group or mark.hl or mark[4]
	return tonumber(row), tonumber(col), options
end

local function layer(self, target)
	if type(target) == "table" then target = target.target end
	target = target or "content"
	if target == "content" and not self.content and self.input then target = "input" end
	assert(target == "frame" or target == "content" or target == "input", "invalid popup target: " .. tostring(target))
	local component = self[target]
	assert(component, "popup has no " .. target .. " layer")
	return component, target
end

local function update_aliases(self)
	self.bufnr = self.content and self.content.bufnr or (self.input and self.input.bufnr or nil)
	self.winid = self.content and self.content.winid or (self.input and self.input.winid or nil)
	self.input_bufnr = self.input and self.input.bufnr or nil
	self.input_winid = self.input and self.input.winid or nil
	local primary = self.content or self.input
	self.win_config = primary and primary.win_config or nil
	self.border = primary and primary.border or nil
	self.ns_id = primary and primary.ns_id or nil
end

local function root_spec(opts)
	if opts.frame then return "frame", vim.deepcopy(opts.frame) end
	return "content", vim.deepcopy(opts.content or opts)
end

local function child_relative(self, name)
	local spec = self.specs[name]
	if self.frame and name ~= "frame" and not spec.relative then
		return { type = "win", winid = self.frame.winid }
	end
	return spec.relative or "editor"
end

local function apply_layout(self, name)
	local component = self[name]
	if not component then return end
	local spec = self.specs[name]
	local layout = geometry(spec, child_relative(self, name), component)
	component:update_layout(layout)
end

local function belongs_to_popup(self, winid)
	return (visible(self.frame) and self.frame.winid == winid)
		or (visible(self.content) and self.content.winid == winid)
		or (visible(self.input) and self.input.winid == winid)
end

local function install_events(self)
	self.augroup = vim.api.nvim_create_augroup("OpenCodePopup_" .. self.id, { clear = true })
	vim.api.nvim_create_autocmd("VimResized", {
		group = self.augroup,
		callback = function()
			if self.closed then return end
			if self.on_resize then
				self.on_resize(self)
			else
				self:resize({})
			end
		end,
	})
	for _, name in ipairs({ "input", "content", "frame" }) do
		local component = self[name]
		if visible(component) then
			vim.api.nvim_create_autocmd("WinClosed", {
				group = self.augroup,
				pattern = tostring(component.winid),
				callback = function()
					if not self.closed then
						self:close({ restore_focus = self.focus_restore == "chat", force_focus = true })
					end
				end,
			})
			if self.close_on_leave then
				vim.api.nvim_create_autocmd("BufLeave", {
					group = self.augroup,
					buffer = component.bufnr,
					callback = function()
						vim.schedule(function()
							if not self.closed and not belongs_to_popup(self, vim.api.nvim_get_current_win()) then
								self:close({ restore_focus = self.focus_restore == "chat", force_focus = true })
							end
						end)
					end,
				})
			end
		end
	end
end

function Popup:mount()
	if self.closed or self.mounted then return self end
	local focus_target
	for _, name in ipairs({ "frame", "content", "input" }) do
		local component = self[name]
		if component then
			apply_layout(self, name)
			component:mount()
			local spec = self.specs[name]
			if spec.enter == true or (name == "input" and spec.kind ~= "popup" and spec.enter ~= false) then
				focus_target = component.winid
			end
			if name == "input" and self.specs.input.kind ~= "popup" then
				local prompt = self.specs.input.prompt or ""
				vim.fn.prompt_setprompt(component.bufnr, prompt)
				vim.api.nvim_buf_set_lines(component.bufnr, 0, -1, false,
					{ prompt .. (self.specs.input.default_value or "") })
			end
		end
	end
	self.mounted = true
	update_aliases(self)
	install_events(self)
	if focus_target and vim.api.nvim_win_is_valid(focus_target) then
		vim.api.nvim_set_current_win(focus_target)
	end
	return self
end

-- Passing nil for lines changes only popup-owned marks. This keeps an editable
-- input's text and cursor in place when its placeholder highlight changes.
function Popup:render(lines, marks, target)
	local component, name = layer(self, target)
	local bufnr = component.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return self end
	local namespace = self.namespaces[name]
	if lines ~= nil then
		local was_modifiable, was_readonly = vim.bo[bufnr].modifiable, vim.bo[bufnr].readonly
		vim.bo[bufnr].readonly = false
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = was_modifiable
		vim.bo[bufnr].readonly = was_readonly
	end
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	for _, mark in ipairs(marks or {}) do
		local row, col, options = normalise_mark(mark)
		if row and col and row >= 0 and row < vim.api.nvim_buf_line_count(bufnr) then
			local text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
			col = math.max(0, math.min(col, #text))
			if options.end_col then options.end_col = math.max(col, math.min(options.end_col, #text)) end
			vim.api.nvim_buf_set_extmark(bufnr, namespace, row, col, options)
		end
	end
	return self
end

function Popup:resize(layout)
	if self.closed then return self end
	layout = layout or {}
	if layout.frame or layout.content or layout.input then
		for _, name in ipairs({ "frame", "content", "input" }) do
			if layout[name] and self.specs[name] then
				self.specs[name] = vim.tbl_deep_extend("force", self.specs[name], layout[name])
			end
		end
	else
		local name = self.frame and "frame" or (self.content and "content" or "input")
		self.specs[name] = vim.tbl_deep_extend("force", self.specs[name], layout)
	end
	for _, name in ipairs({ "frame", "content", "input" }) do
		if self[name] then apply_layout(self, name) end
	end
	update_aliases(self)
	return self
end

-- NuiPopup compatibility for callers of float.create_centered_popup().
function Popup:update_layout(layout)
	return self:resize(layout)
end

function Popup:map(mode, key, handler, opts, target)
	local component = layer(self, target)
	return component:map(mode, key, handler, opts)
end

function Popup:on(event, callback, target)
	local component = layer(self, target)
	local options
	if type(target) == "table" then
		options = vim.deepcopy(target)
		options.target = nil
	end
	return component:on(event, callback, options)
end

function Popup:off(event, target)
	local component = layer(self, target)
	return component:off(event)
end

function Popup:close(options)
	if self.closed then return self end
	self.closed = true
	local restore = options ~= false
	if type(options) == "table" and options.restore_focus ~= nil then restore = options.restore_focus end
	local force_focus = type(options) == "table" and options.force_focus
	local was_focused = belongs_to_popup(self, vim.api.nvim_get_current_win())
	if was_focused and self.input and vim.fn.mode() == "i" then pcall(vim.cmd, "stopinsert") end
	if self.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
		self.augroup = nil
	end
	for _, name in ipairs({ "input", "content", "frame" }) do
		local component = self[name]
		if component then
			local winid, bufnr = component.winid, component.bufnr
			local border = component.border
			local border_winid = border and border.winid
			local border_bufnr = border and border.bufnr
			pcall(function() component:unmount() end)
			-- Nui's unmount is a no-op before mount. A partially mounted dialog
			-- still owns every buffer and window it allocated, including a
			-- separate buffer for a border with a title or padding.
			if border_winid and vim.api.nvim_win_is_valid(border_winid) then
				pcall(vim.api.nvim_win_close, border_winid, true)
			end
			if border_bufnr and vim.api.nvim_buf_is_valid(border_bufnr) then
				pcall(vim.api.nvim_buf_delete, border_bufnr, { force = true })
			end
			if winid and vim.api.nvim_win_is_valid(winid) then pcall(vim.api.nvim_win_close, winid, true) end
			if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
				pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
			end
			if border then border.winid, border.bufnr = nil, nil end
			component.winid, component.bufnr = nil, nil
		end
	end
	self.mounted = false
	update_aliases(self)
	if restore and (was_focused or force_focus) then
		local restored = false
		if self.focus_restore == "chat" then restored = float_context.focus_chat_if_visible() end
		if not restored and (self.focus_restore == "previous" or self.focus_restore == "chat")
			and self.previous_win and vim.api.nvim_win_is_valid(self.previous_win) then
			pcall(vim.api.nvim_set_current_win, self.previous_win)
		end
	end
	if self.on_close then self.on_close(self) end
	return self
end

function Popup:unmount()
	return self:close()
end

function M.new(opts)
	opts = opts or {}
	next_id = next_id + 1
	local self = setmetatable({
		id = next_id,
		closed = false,
		mounted = false,
		previous_win = vim.api.nvim_get_current_win(),
		focus_restore = opts.focus_restore or (opts.refocus_chat and "chat") or false,
		close_on_leave = opts.close_on_leave == true,
		on_resize = opts.on_resize,
		on_close = opts.on_close,
		specs = {},
		namespaces = {},
	}, Popup)
	local root_name, root = root_spec(opts)
	if not root.size then
		root.size = { width = root.width or 60, height = root.height or 20 }
	end
	if opts.input_only then
		self.specs.input = vim.deepcopy(opts.input or opts)
		self.specs.input.size = self.specs.input.size or root.size
	elseif root_name == "frame" then
		self.specs.frame = root
		self.specs.content = vim.deepcopy(opts.content or {})
	else
		self.specs.content = root
	end
	if opts.input and not opts.input_only then self.specs.input = vim.deepcopy(opts.input) end
	for _, name in ipairs({ "frame", "content", "input" }) do
		local spec = self.specs[name]
		if spec then
			if not spec.size then
				spec.size = { width = (root.size.width or 60) - (name == "frame" and 0 or 2), height = name == "input" and 1 or (root.size.height or 20) - 2 }
			end
			if name == "input" then spec.size.height = 1 end
			local relative = spec.relative or "editor"
			self[name] = make_component(spec, relative, name == "input")
			self.namespaces[name] = vim.api.nvim_create_namespace("opencode_popup_" .. self.id .. "_" .. name)
		end
	end
	update_aliases(self)
	return self
end

return M
