-- opencode.nvim - Logger module
-- Separate log storage and management for debug messages

local M = {}

-- Log storage
local logs = {}
local max_logs = 1000

-- Log levels
M.levels = {
  DEBUG = "DEBUG",
  INFO = "INFO",
  WARN = "WARN",
  ERROR = "ERROR",
}

-- Get current timestamp string
local function timestamp()
  return os.date("%H:%M:%S")
end

-- Add a log entry
---@param level string Log level (DEBUG, INFO, WARN, ERROR)
---@param message string Log message
---@param data? table Optional data to include
function M.add(level, message, data)
  local entry = {
    level = level,
    message = message,
    data = data,
    timestamp = timestamp(),
    time_raw = os.time(),
  }

  table.insert(logs, 1, entry)

  -- Trim to max size
  if #logs > max_logs then
    table.remove(logs)
  end

  -- Notify log viewer of new entry if visible
  local viewer_ok, viewer = pcall(require, "opencode.ui.log_viewer")
  if viewer_ok and viewer.is_visible then
    vim.schedule(function()
      if viewer.is_visible() then
        viewer.render_entry(entry)
      end
    end)
  end
end

-- Convenience methods
function M.debug(message, data)
  M.add(M.levels.DEBUG, message, data)
end

function M.info(message, data)
  M.add(M.levels.INFO, message, data)
end

function M.warn(message, data)
  M.add(M.levels.WARN, message, data)
end

function M.error(message, data)
  M.add(M.levels.ERROR, message, data)
end

-- Get all logs
---@param limit? number Maximum number of logs to return
---@param level_filter? string Filter by level
---@return table Array of log entries
function M.get_logs(limit, level_filter)
  limit = limit or max_logs
  local result = {}

  for _, entry in ipairs(logs) do
    if not level_filter or entry.level == level_filter then
      table.insert(result, entry)
      if #result >= limit then
        break
      end
    end
  end

  return result
end

-- Clear all logs
function M.clear()
  logs = {}
end

-- Get log count
function M.count()
  return #logs
end

-- Get count by level
function M.count_by_level(level)
  local count = 0
  for _, entry in ipairs(logs) do
    if entry.level == level then
      count = count + 1
    end
  end
  return count
end

return M
