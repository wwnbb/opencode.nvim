-- Browser smoke inputs, generated with the same HTML writer as /diagrams.
local directory = assert(vim.env.OPENCODE_DIAGRAM_PREVIEW_DIR, "OPENCODE_DIAGRAM_PREVIEW_DIR is required")
vim.fn.mkdir(directory, "p")
local diagrams = require("opencode.ui.diagrams")
for name, item in pairs({
	mermaid = { kind = "mermaid", source = "graph LR\n A[Start] --> B[Done]" },
	math = { kind = "math", source = "\\frac{1}{2} + x^2" },
	invalid = { kind = "math", source = '</script><script>globalThis.untrustedExecuted=true</script>\\unknowncommand' },
}) do
	vim.fn.writefile(vim.split(assert(diagrams.html(item)), "\n", { plain = true }), directory .. "/" .. name .. ".html")
end
