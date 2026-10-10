return function()
	local input = require("opencode.ui.input")
	for index = 1, 20 do
		local name, value = debug.getupvalue(input.get_winids, index)
		if name == "state" then return value end
	end
	error("Input UI state unavailable")
end
