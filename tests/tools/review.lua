-- Exercise the real permission decoding and review path from the Bun tool tests.
vim.opt.runtimepath:append(assert(vim.env.OPENCODE_TEST_ROOT))
local payload = vim.json.decode(table.concat(vim.fn.readfile(assert(vim.env.OPENCODE_TEST_REVIEW)), "\n"))
local request = require("opencode.events.handlers.permission_flow.request").decode(payload.request)
assert(request and request.kind == "edit")
require("opencode.artifact.changes").setup({ auto_backup = false })
local edits = require("opencode.edit.state")
edits.add_edit(request.id, request.session_id, request.files, { review_mode = request.review_mode })
for index, action in ipairs(payload.actions) do
	local ok, err = edits[action .. "_file"](request.id, index)
	assert(ok, err)
end
assert(edits.are_all_resolved(request.id))
vim.cmd("qa!")
