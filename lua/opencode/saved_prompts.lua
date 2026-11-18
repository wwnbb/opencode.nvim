-- A global library of reusable prompts; inserting one keeps it in the library.
return require("opencode.prompt_store").new({
	config_key = "saved_prompts_file",
	default_name = "opencode_saved_prompts.json",
	label = "saved prompts",
	missing = "Saved prompt is no longer available",
	scope = function() return "global" end,
})
