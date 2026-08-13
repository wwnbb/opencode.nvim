-- Unit checks for transient provider disconnect visibility state.
-- Run with: ./tests/run.sh tests/unit/pending_disconnect_spec.lua

describe("opencode pending provider disconnects", function()
	local provider_state
	local original_state_module
	local actions
	local original_remove_provider_models

	before_each(function()
		provider_state = require("opencode.provider.state")
		provider_state.set_identity_getter(nil)
		provider_state.clear_all()
		original_state_module = package.loaded["opencode.state"]
		actions = nil
		original_remove_provider_models = nil
	end)

	after_each(function()
		provider_state.set_identity_getter(nil)
		provider_state.clear_all()
		if actions and original_remove_provider_models then
			actions.remove_provider_models = original_remove_provider_models
		end
		package.loaded["opencode.state"] = original_state_module
	end)

	it("keeps a mark pending at the same host and port", function()
		provider_state.set_identity_getter(function()
			return "localhost:5000"
		end)

		provider_state.mark("provider-a")
		assert(provider_state.is_pending("provider-a"))
	end)

	it("uses the real state getter and ignores pid changes", function()
		local server = { host = "localhost", port = 5000, pid = 111 }
		package.loaded["opencode.state"] = {
			get_server_info = function()
				return server
			end,
		}
		provider_state.set_identity_getter(nil)

		provider_state.mark("provider-a")
		server.pid = 222
		assert(provider_state.is_pending("provider-a"))
		server.pid = nil
		assert(provider_state.is_pending("provider-a"))
		server.port = 6000
		assert(not provider_state.is_pending("provider-a"))
	end)

	it("returns nil for an unknown endpoint and keeps nil-stamp marks pending", function()
		package.loaded["opencode.state"] = {
			get_server_info = function()
				return { host = nil, port = nil, pid = 111 }
			end,
		}
		provider_state.set_identity_getter(nil)

		provider_state.mark("provider-a")
		assert(provider_state.is_pending("provider-a"))
	end)

	it("clears a mark when a provider is remembered", function()
		provider_state.set_identity_getter(function()
			return "localhost:5000"
		end)
		provider_state.mark("provider-a")

		provider_state.remember("provider-a")
		assert(not provider_state.is_pending("provider-a"))
	end)

	it("prunes pending providers and retains providers from another endpoint", function()
		local endpoint = "localhost:5000"
		provider_state.set_identity_getter(function()
			return endpoint
		end)
		provider_state.mark("provider-a")

		local connected = { ["provider-a"] = true, ["provider-b"] = true }
		assert(provider_state.prune_connected(connected) == connected)
		assert(connected["provider-a"] == nil)
		assert(connected["provider-b"])

		endpoint = "localhost:6000"
		local new_connected = { ["provider-a"] = true }
		provider_state.prune_connected(new_connected)
		assert(new_connected["provider-a"])
	end)

	it("scopes marks independently by their endpoint stamps", function()
		local endpoint = "localhost:5000"
		provider_state.set_identity_getter(function()
			return endpoint
		end)
		provider_state.mark("provider-x")

		endpoint = "localhost:6000"
		provider_state.mark("provider-y")
		assert(not provider_state.is_pending("provider-x"))
		assert(provider_state.is_pending("provider-y"))
	end)

	it("handles nil provider ids and nil connected sets", function()
		provider_state.mark(nil)
		assert(not provider_state.is_pending(nil))
		assert(provider_state.prune_connected(nil) == nil)
	end)

	it("does not retain marks across module reload", function()
		provider_state.set_identity_getter(function()
			return "localhost:5000"
		end)
		provider_state.mark("provider-a")

		local original_provider_module = package.loaded["opencode.provider.state"]
		package.loaded["opencode.provider.state"] = nil
		local reloaded = require("opencode.provider.state")
		assert(not reloaded.is_pending("provider-a"))
		reloaded.set_identity_getter(nil)
		reloaded.clear_all()
		package.loaded["opencode.provider.state"] = original_provider_module
	end)

	it("is not cleared by transient cleanup", function()
		provider_state.set_identity_getter(function()
			return "localhost:5000"
		end)
		provider_state.mark("provider-a")

		require("opencode.cleanup").clear_transient({ reset_state = false, clear_chat = false })
		assert(provider_state.is_pending("provider-a"))
	end)

	it("exposes action wrappers for mark, remember, and clear", function()
		actions = require("opencode.actions")
		original_remove_provider_models = actions.remove_provider_models
		local removed_provider
		actions.remove_provider_models = function(provider_id)
			removed_provider = provider_id
		end
		provider_state.set_identity_getter(function()
			return "localhost:5000"
		end)

		actions.forget_provider("provider-a")
		assert(removed_provider == "provider-a")
		assert(provider_state.is_pending("provider-a"))
		actions.remember_provider("provider-a")
		assert(not provider_state.is_pending("provider-a"))
		provider_state.mark("provider-a")
		actions.clear_pending_disconnects()
		assert(not provider_state.is_pending("provider-a"))
	end)
end)
