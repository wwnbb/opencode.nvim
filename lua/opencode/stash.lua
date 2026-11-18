-- Persist unsent prompts per working directory; restoring one removes it.
return require("opencode.prompt_store").new({
	config_key = "stash_file",
	default_name = "opencode_stash.json",
	label = "prompt stash",
	missing = "Stashed prompt is no longer available",
	scope = function() return require("opencode.util.path").absolute(require("opencode.util.cwd").get()) end,
})
