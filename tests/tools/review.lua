-- Exercise native v2 file review decisions from the Bun tool tests.
vim.opt.runtimepath:append(assert(vim.env.OPENCODE_TEST_ROOT))
local payload = vim.json.decode(table.concat(vim.fn.readfile(assert(vim.env.OPENCODE_TEST_REVIEW)), "\n"))
local request = payload.request
assert(request and request.id and request.sessionID and type(request.metadata) == "table")
assert(type(request.metadata.files) == "table")
require("opencode.artifact.changes").setup({ auto_backup = false })
local state = require("opencode.state")
state.set_config({ server = { shared_filesystem = true } })
state.set_connection("connected")
local edits = require("opencode.edit.state")
edits.add_edit(request.id, request.sessionID, request.metadata.files, {
	transport = "review_rpc",
	review_id = request.id,
	revision = 1,
	native_review = { status = "pending", protocolVersion = 2 },
})
for index, action in ipairs(payload.actions) do
	local ok, err = edits[action .. "_file"](request.id, index)
	assert(ok, err)
end
assert(edits.are_all_resolved(request.id))
vim.cmd("qa!")
