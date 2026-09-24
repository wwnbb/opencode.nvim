-- Completed native question tools carry durable answers independently of forms.
local M = {}

function M.render_tool(part)
	if part.tool ~= "question" then return nil end
	local state = part.state or {}
	local questions = (state.input or {}).questions
	local answers = (state.metadata or {}).answers
	if state.status ~= "completed" or type(questions) ~= "table" or type(answers) ~= "table" then return nil end
	local lines, highlights = require("opencode.ui.question_widget").get_answered_lines(part.id, { questions = questions }, answers)
	return { lines = lines, highlights = highlights }
end

return M
