local state = require("opencode.state")
local json = require("opencode.util.json_file")

describe("runtime display preferences", function()
	local root, original_cwd, path, config, settings, previous_module
	local function item(id, directory)
		for _, entry in ipairs(settings.list(directory)) do if entry.id == id then return entry end end
	end
	local function configure()
		state.set_config(settings.setup(config))
	end
	local function cwd(value)
		vim.fn.chdir(value)
		vim.api.nvim_exec_autocmds("DirChanged", { pattern = "global" })
	end
	before_each(function()
		state.reset()
		original_cwd = vim.fn.getcwd()
		root = vim.fn.tempname(); vim.fn.mkdir(root .. "/one", "p"); vim.fn.mkdir(root .. "/two", "p")
		root = (vim.uv or vim.loop).fs_realpath(root)
		path = root .. "/settings.json"
		config = vim.deepcopy(require("opencode.config").defaults)
		config.settings = { file = path }
		config.server.port = 8123
		previous_module = package.loaded["opencode.settings"]
		package.loaded["opencode.settings"] = nil
		settings = require("opencode.settings")
		cwd(root .. "/one"); configure()
	end)
	after_each(function()
		vim.api.nvim_del_augroup_by_name("OpenCodeSettings")
		vim.fn.chdir(original_cwd)
		vim.fn.delete(root, "rf")
		package.loaded["opencode.settings"] = previous_module
		state.reset()
	end)

	it("persists global choices, overlays directory values and reapplies them on DirChanged", function()
		assert.is_true(settings.apply("markdown", "source", "global"))
		assert.is_true(settings.apply("markdown", "rendered", "cwd"))
		assert.equals("rendered", state.get_config().session.markdown)
		assert.equals("cwd", item("markdown").scope)
		cwd(root .. "/two")
		assert.equals("source", state.get_config().session.markdown)
		assert.equals("global", item("markdown").scope)
		cwd(root .. "/one")
		assert.equals("rendered", state.get_config().session.markdown)
		local saved = json.read(path)
		assert.equals(2, saved.version)
		assert.equals("source", saved.settings.global.markdown)
		assert.equals("rendered", saved.settings.directories[root .. "/one"].markdown)
	end)

	it("keeps one owner across setup and writes without clobbering either scope or unknown fields", function()
		assert.is_true(settings.apply("thinking", "show", "global"))
		configure()
		assert.is_true(settings.apply("verbosity", "high", "cwd"))
		local data = json.read(path)
		assert.equals("show", data.settings.global.thinking)
		assert.equals("high", data.settings.directories[root .. "/one"].verbosity)
		package.loaded["opencode.settings"] = nil
		settings = require("opencode.settings"); configure()
		assert.equals("show", state.get_config().session.thinking)
		assert.equals("high", state.get_config().session.verbosity)
	end)

	it("lists another directory without changing current runtime settings or directory", function()
		assert.is_true(settings.apply("markdown", "source", "global"))
		assert.is_true(settings.apply("markdown", "rendered", "cwd"))
		assert.is_true(settings.apply("thinking", "show", "cwd", root .. "/two"))
		local current = state.get_config()
		current.session.verbosity = "high"
		state.set_config(current)
		assert.equals("source", item("markdown", root .. "/two").value)
		assert.equals("global", item("markdown", root .. "/two").scope)
		assert.equals("show", item("thinking", root .. "/two").value)
		assert.equals("cwd", item("thinking", root .. "/two").scope)
		assert.equals("medium", item("verbosity", root .. "/two").value)
		assert.equals("rendered", item("markdown").value)
		assert.equals("high", item("verbosity").value)
		assert.same(current, state.get_config())
		assert.equals(root .. "/one", vim.fn.getcwd())
	end)

	it("removes a directory override to inherit global without disturbing server state or session", function()
		state.set_session("ses_current", "Current"); state.set_connection("connected")
		assert.is_true(settings.apply("diff_view", "unified", "global"))
		assert.is_true(settings.apply("diff_view", "split", "cwd"))
		assert.is_true(settings.apply("diff_view", nil, "cwd"))
		assert.equals("unified", state.get_config().chat.diff_view)
		assert.equals(8123, state.get_config().server.port)
		assert.equals("ses_current", state.get_session().id)
		assert.equals("connected", state.get_connection())
	end)

	it("validates values and never applies a preference when saving fails", function()
		local before = state.get_config()
		assert.is_false(settings.apply("server.port", "unified", "global"))
		assert.is_false(settings.apply("verbosity", "unknown", "global"))
		assert.is_false(settings.apply("verbosity", "high", "project"))
		local stub = require("luassert.stub")(json, "write", function() return false end)
		local ok = settings.apply("verbosity", "high", "global")
		stub:revert()
		assert.is_false(ok)
		assert.same(before, state.get_config())
	end)

	it("persists independent editor profiles and line limits with directory precedence", function()
		local completion_model = { providerID = "provider", modelID = "fast" }
		local explain_model = { providerID = "provider", modelID = "deep" }
		assert.is_true(settings.apply("completion_model", completion_model, "global"))
		assert.is_true(settings.apply("completion_variant", "low", "global"))
		assert.is_true(settings.apply("completion_max_lines", 7, "global"))
		assert.is_true(settings.apply("completion_max_lines", 3, "cwd"))
		assert.is_true(settings.apply("explanation_model", explain_model, "cwd"))
		assert.is_true(settings.apply("explanation_variant", "high", "cwd"))
		package.loaded["opencode.settings"] = nil
		settings = require("opencode.settings"); configure()
		assert.same(completion_model, state.get_config().completion.model)
		assert.equals("low", state.get_config().completion.variant)
		assert.equals(3, state.get_config().completion.max_lines)
		assert.same(explain_model, state.get_config().explanation.model)
		assert.equals("high", state.get_config().explanation.variant)
		assert.equals("global", item("completion_model").scope)
		assert.equals("cwd", item("explanation_variant").scope)
		cwd(root .. "/two")
		assert.equals(7, state.get_config().completion.max_lines)
		assert.is_nil(state.get_config().explanation.model)
		assert.is_nil(state.get_config().explanation.variant)
		assert.is_true(settings.apply("completion_max_lines", nil, "global"))
		assert.equals(12, state.get_config().completion.max_lines)
	end)

	it("resets model-specific reasoning and restores configured options on inheritance", function()
		for _, feature in ipairs({ "completion", "explanation" }) do
			config[feature].model = { providerID = "provider", modelID = "original" }
			config[feature].options = { body = { reasoning_effort = "none" } }
		end
		configure()
		for _, feature in ipairs({ "completion", "explanation" }) do
			assert.is_true(item(feature .. "_variant").custom_options)
			assert.is_true(settings.apply(feature .. "_variant", false, "global"))
			assert.is_nil(state.get_config()[feature].variant)
			assert.is_nil(state.get_config()[feature].options)
			assert.is_false(json.read(path).settings.global[feature .. "_variant"])
			assert.is_true(settings.apply(feature .. "_variant", "low", "global"))
			assert.is_true(settings.apply(feature .. "_model", { providerID = "other", modelID = "new" }, "cwd"))
			assert.is_nil(state.get_config()[feature].variant)
			assert.is_nil(state.get_config()[feature].options)
			assert.is_true(settings.apply(feature .. "_model", nil, "cwd"))
			assert.equals("low", state.get_config()[feature].variant)
			assert.is_true(settings.apply(feature .. "_variant", nil, "global"))
			assert.same(config[feature].options, state.get_config()[feature].options)
			assert.same(config[feature].model, state.get_config()[feature].model)
		end
	end)

	it("rejects malformed editor settings and preserves profiles when a model save fails", function()
		for _, value in ipairs({ 0, -1, 1.5, math.huge, "12", false }) do
			assert.is_false(settings.apply("completion_max_lines", value, "global"))
		end
		for _, value in ipairs({ "model", {}, { providerID = "p" }, { providerID = " ", modelID = "m" } }) do
			assert.is_false(settings.apply("completion_model", value, "global"))
		end
		for _, value in ipairs({ "", " ", true, {} }) do
			assert.is_false(settings.apply("explanation_variant", value, "global"))
		end
		assert.is_true(settings.apply("completion_variant", "high", "global"))
		local before, saved = state.get_config(), json.read(path)
		local stub = require("luassert.stub")(json, "write", function() return false end)
		local ok = settings.apply("completion_model", { providerID = "p", modelID = "m" }, "global")
		stub:revert()
		assert.is_false(ok)
		assert.same(before, state.get_config())
		assert.same(saved, json.read(path))
	end)

	it("resets inherited directory reasoning when changing a global model but preserves independent profiles", function()
		local first, second = { providerID = "p", modelID = "first" }, { providerID = "p", modelID = "second" }
		assert.is_true(settings.apply("completion_model", first, "global"))
		assert.is_true(settings.apply("completion_variant", "first-only", "cwd", root .. "/one"))
		assert.is_true(settings.apply("completion_model", first, "cwd", root .. "/two"))
		assert.is_true(settings.apply("completion_variant", "first-only", "cwd", root .. "/two"))
		assert.is_true(settings.apply("completion_model", second, "global"))
		assert.same(second, state.get_config().completion.model)
		assert.is_nil(state.get_config().completion.variant)
		cwd(root .. "/two")
		assert.same(first, state.get_config().completion.model)
		assert.equals("first-only", state.get_config().completion.variant)
	end)

	it("does not save a directory model's reasoning onto a different global model", function()
		assert.is_true(settings.apply("completion_model", { providerID = "p", modelID = "global" }, "global"))
		assert.is_true(settings.apply("completion_model", { providerID = "p", modelID = "local" }, "cwd"))
		assert.is_false(settings.apply("completion_variant", "local-only", "global"))
		assert.is_true(settings.apply("completion_variant", "local-only", "cwd"))
		assert.equals("local-only", state.get_config().completion.variant)
		cwd(root .. "/two")
		assert.is_nil(state.get_config().completion.variant)
	end)

	it("preserves unsupported preference files rather than replacing them", function()
		json.write(path, { version = 7, untouched = "preserve" })
		package.loaded["opencode.settings"] = nil
		settings = require("opencode.settings"); configure()
		assert.is_false(settings.apply("thinking", "show", "global"))
		assert.same({ version = 7, untouched = "preserve" }, json.read(path))
	end)

	it("ignores invalid stored values while preserving them and unrelated fields on save", function()
		json.write(path, { version = 2, other = "keep", settings = { global = { verbosity = "invalid", future = "keep" } } })
		package.loaded["opencode.settings"] = nil
		settings = require("opencode.settings"); configure()
		assert.equals("medium", state.get_config().session.verbosity)
		assert.is_true(settings.apply("thinking", "show", "cwd"))
		local data = json.read(path)
		assert.equals("keep", data.other); assert.equals("keep", data.settings.global.future)
	end)

	it("routes a registered /settings choice through value and scope menus to the action boundary", function()
		local menus, call = {}, nil
		local menu_stub = require("luassert.stub")(require("opencode.ui.menu"), "open", function(opts) menus[#menus + 1] = opts end)
		local action_stub = require("luassert.stub")(require("opencode.actions"), "apply_setting", function(...) call = { ... }; return true end)
		local commands = {}
		require("opencode.ui.palette.settings").register({ register = function(record) commands[record.id] = record end })
		assert.equals("settings", commands["action.settings"].slash.name)
		commands["action.settings"].run({})
		assert.is_true(menus[1].searchable)
		assert.equals("Thinking: hide", menus[1].items[1].label)
		menus[1].on_select(menus[1].items[1]); menus[2].on_select(menus[2].items[2])
		cwd(root .. "/two")
		menus[3].on_select(menus[3].items[1])
		menu_stub:revert(); action_stub:revert()
		assert.same({ "thinking", "show", "cwd", root .. "/one" }, call)
	end)
end)
