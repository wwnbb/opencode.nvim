-- Unit checks for dispose_server callback err handling.
-- Run with: ./tests/run.sh tests/unit/dispose_server_callback_spec.lua

describe("opencode dispose_server callback", function()
    local notifications
    local original_notify, original_schedule

    before_each(function()
        notifications = {}
        original_notify = vim.notify
        original_schedule = vim.schedule
        vim.schedule = function(fn) fn() end  -- синхронный режим
        vim.notify = function(message, level)
            table.insert(notifications, { message = tostring(message), level = level })
        end

        package.preload["opencode.client"] = function()
            return {
                dispose = function(callback) callback({ message = "boom" }) end,  -- эмулировать err
                disconnect_events = function() end,
            }
        end
        package.preload["opencode.cleanup"] = function()
            return { clear_transient = function() end }
        end
        package.preload["opencode.state"] = function()
            return { set_connection = function() end }
        end
    end)

    after_each(function()
        vim.notify = original_notify
        vim.schedule = original_schedule
        package.preload["opencode.client"] = nil
        package.preload["opencode.cleanup"] = nil
        package.preload["opencode.state"] = nil
    end)

    it("passes err to callback (callback can observe err)", function()
        local actions = require("opencode.actions")
        local captured
        actions.dispose_server(function(err)
            captured = err
        end)
        assert(captured ~= nil, "callback must receive err when dispose fails")
        assert(captured.message == "boom", "err.message should propagate")
    end)
end)
