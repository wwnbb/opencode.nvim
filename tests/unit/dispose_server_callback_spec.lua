-- Unit checks for dispose_server callback err handling.
-- Run with: ./tests/run.sh tests/unit/dispose_server_callback_spec.lua

describe("opencode dispose_server callback", function()
    local original_notify, original_schedule

    before_each(function()
        original_notify = vim.notify
        original_schedule = vim.schedule
        vim.schedule = function(fn) fn() end  -- синхронный режим
        vim.notify = function() end

        package.preload["opencode.client"] = function()
            return {
                dispose = function(callback) callback({ message = "boom" }) end,  -- эмулировать err
            }
        end

    end)

    after_each(function()
        vim.notify = original_notify
        vim.schedule = original_schedule
        package.preload["opencode.client"] = nil
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
